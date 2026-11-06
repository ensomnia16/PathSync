import Darwin
import Foundation

private func relativePath(_ value: String, within root: String) -> String? {
    guard !value.isEmpty, !root.isEmpty else { return nil }
    let base = URL(fileURLWithPath: root).standardizedFileURL.path
    let full = URL(fileURLWithPath: value).standardizedFileURL.path
    guard full.hasPrefix(base + "/") else { return nil }
    let relative = String(full.dropFirst(base.count + 1))
    return isSafeRelativePath(relative) ? relative : nil
}


struct OneDriveRules {
    static let filename = "PathSync-Exclusions.json"
    private static let maximumBytes = 1_000_000

    private enum Failure: LocalizedError {
        case rootUnavailable, invalidDocument, oversized, unresolvedVersion, missingPolicy, missingPair(String)

        var errorDescription: String? {
            switch self {
            case .rootUnavailable: return "OneDrive 规则目录不可用，已暂停读取同步规则。"
            case .invalidDocument: return "OneDrive 排除规则文件格式无效，已暂停使用。"
            case .oversized: return "OneDrive 排除规则过大，无法安全读取或传递。"
            case .unresolvedVersion: return "OneDrive 排除规则存在冲突副本，请在 Finder 中核对后重试。"
            case .missingPolicy: return "OneDrive 根目录缺少 PathSync-Exclusions.json，已暂停同步；不会改用本地排除规则。"
            case .missingPair(let name): return "OneDrive 根目录配置中缺少「\(name)」的排除规则，或目标不在所选 OneDrive 根目录内，已暂停同步。"
            }
        }
    }

    private struct Entry: Codable, Equatable {
        var excludeRules: String
        let syncCodexFiles: Bool
        let syncClaudeFiles: Bool
        let syncTemporaryFiles: Bool

        func apply(to pair: inout SyncPair) {
            pair.excludeRules = excludeRules
            pair.syncCodexFiles = syncCodexFiles
            pair.syncClaudeFiles = syncClaudeFiles
            pair.syncTemporaryFiles = syncTemporaryFiles
        }
    }

    private struct Document: Codable, Equatable {
        var version = 1
        var excludeLatexIntermediates: Bool
        var pairs: [String: Entry] = [:]

        func validate() throws {
            guard version == 1, pairs.keys.allSatisfy(isSafeRelativePath) else {
                throw Failure.invalidDocument
            }
            for entry in pairs.values {
                guard !entry.excludeRules.contains("\0") else { throw Failure.invalidDocument }
                // The runner passes the rules as separate arguments. Leave room for
                // argument overhead, the environment and the rest of the invocation.
                let argumentBytes = entry.excludeRules.split(whereSeparator: \.isNewline)
                    .reduce(0) { $0 + $1.utf8.count + 11 }
                guard argumentBytes <= 750_000 else { throw Failure.oversized }
            }
        }
    }

    private struct BoundPair {
        let index: Int
        let key: String
    }

    static func configured(_ config: SyncConfig) -> Bool {
        !boundPairs(config).isEmpty
    }

    private static func isOneDriveRoot(_ value: String) -> Bool {
        !value.isEmpty && inferredOneDriveRoot(value) == URL(fileURLWithPath: value).standardizedFileURL.path
    }

    private static func boundPairs(_ config: SyncConfig) -> [BoundPair] {
        guard isOneDriveRoot(config.oneDriveRoot) else { return [] }
        return config.pairs.indices.compactMap { index in
            guard let key = relativePath(config.pairs[index].cloudPath, within: config.oneDriveRoot) else {
                return nil
            }
            return BoundPair(index: index, key: key.precomposedStringWithCanonicalMapping)
        }
    }

    private static func directoryExists(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            let code = errno
            if code == ENOENT { return false }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        return (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
    }

    private static func sharedURL(_ config: SyncConfig) throws -> URL {
        let root = URL(fileURLWithPath: config.oneDriveRoot, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard try directoryExists(root) else { throw Failure.rootUnavailable }
        return root.appendingPathComponent(filename, isDirectory: false)
    }

    /// Only regular, bounded root configuration files are accepted. A missing
    /// document is reported to the caller, never replaced from local rules.
    private static func boundedData(at url: URL) throws -> Data? {
        // Check File Provider metadata before opening. This limits content reads
        // (including any provider hydration) to small rule documents.
        var info = stat()
        if lstat(url.path, &info) != 0 {
            let code = errno
            if code == ENOENT { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw Failure.invalidDocument
        }
        guard info.st_size <= maximumBytes else { throw Failure.oversized }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            // A file observed above must not disappear or change type before open.
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        guard fstat(descriptor, &info) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw Failure.invalidDocument
        }
        guard info.st_size <= maximumBytes else { throw Failure.oversized }
        var data = Data()
        while let chunk = try file.read(upToCount: min(64 * 1024, maximumBytes + 1 - data.count)),
              !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximumBytes else { throw Failure.oversized }
        }
        return data
    }

    private static func checkVersions(at url: URL) throws {
        guard (NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []).isEmpty else {
            throw Failure.unresolvedVersion
        }
        // OneDrive can materialize a conflicted copy as another ordinary file.
        let prefix = url.deletingPathExtension().lastPathComponent.lowercased()
        let siblings = try FileManager.default.contentsOfDirectory(
            at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        if siblings.contains(where: { item in
            let name = item.lastPathComponent.lowercased()
            guard item.lastPathComponent != url.lastPathComponent,
                  item.pathExtension.lowercased() == "json" else { return false }
            return name == url.lastPathComponent.lowercased() ||
                ["-", " ", "(", "_"].contains(where: { name.hasPrefix(prefix + $0) })
        }) {
            throw Failure.unresolvedVersion
        }
    }

    private static func load(at url: URL) throws -> Document? {
        try checkVersions(at: url)
        guard let bytes = try boundedData(at: url) else { return nil }
        guard let document = try? JSONDecoder().decode(Document.self, from: bytes) else {
            throw Failure.invalidDocument
        }
        try document.validate()
        return document
    }

    static func configurationURL(_ config: SyncConfig) -> URL? {
        guard isOneDriveRoot(config.oneDriveRoot) else { return nil }
        return URL(fileURLWithPath: config.oneDriveRoot, isDirectory: true)
            .appendingPathComponent(filename)
    }

    /// Every preview and sync reads this one document. Local cached fields,
    /// .pathsyncignore files and previous configuration snapshots are not inputs.
    static func read(_ original: SyncConfig, requiring pairIDs: Set<UUID>? = nil) throws
        -> (config: SyncConfig, managed: Set<UUID>) {
        let required = pairIDs ?? Set(original.pairs.filter { $0.enabled }.map(\.id))
        guard required.isSubset(of: Set(original.pairs.map(\.id))) else { throw Failure.missingPolicy }
        var config = original
        config.oneDriveRulesManagedPaths = []
        config.excludeLatexIntermediates = true
        for index in config.pairs.indices {
            config.pairs[index].excludeRules = ""
            config.pairs[index].syncCodexFiles = true
            config.pairs[index].syncClaudeFiles = true
            config.pairs[index].syncTemporaryFiles = false
        }
        guard isOneDriveRoot(config.oneDriveRoot) else {
            if required.isEmpty { return (config, []) }
            throw Failure.rootUnavailable
        }
        let pairs = boundPairs(config)
        for pair in config.pairs where required.contains(pair.id) {
            guard pairs.contains(where: { config.pairs[$0.index].id == pair.id }) else {
                throw Failure.missingPair(pair.name)
            }
        }
        let url = try sharedURL(config)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinatorError: NSError?
        var result: Result<Document?, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinatorError) { location in
            result = Result { try load(at: location) }
        }
        if let coordinatorError { throw coordinatorError }
        guard let result else { throw Failure.rootUnavailable }
        guard let document = try result.get() else { throw Failure.missingPolicy }
        for pair in pairs where required.contains(config.pairs[pair.index].id) {
            guard document.pairs[pair.key] != nil else {
                throw Failure.missingPair(config.pairs[pair.index].name)
            }
        }
        var managed = Set<UUID>()
        for pair in pairs {
            guard let entry = document.pairs[pair.key] else { continue }
            entry.apply(to: &config.pairs[pair.index])
            config.oneDriveRulesManagedPaths.insert(pair.key)
            managed.insert(config.pairs[pair.index].id)
        }
        config.excludeLatexIntermediates = document.excludeLatexIntermediates
        return (config, managed)
    }
}
