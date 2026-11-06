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
        case rootUnavailable, invalidDocument, oversized, unresolvedVersion, staleEdit(String), missingPolicy, writeVerification

        var errorDescription: String? {
            switch self {
            case .rootUnavailable: return "OneDrive 规则目录不可用，已暂停读取同步规则。"
            case .invalidDocument: return "OneDrive 排除规则文件格式无效，已暂停使用。"
            case .oversized: return "OneDrive 排除规则过大，无法安全读取或传递。"
            case .unresolvedVersion: return "OneDrive 排除规则存在冲突副本，请在 Finder 中核对后重试。"
            case .staleEdit(let scope): return "OneDrive 上的「\(scope)」规则已更新，请重新打开设置后再编辑。"
            case .missingPolicy: return "OneDrive 上先前已启用的排除规则缺失，已暂停同步以保留现有文件。"
            case .writeVerification: return "OneDrive 排除规则写入后校验失败，请重新打开设置核对当前版本。"
            }
        }
    }

    private struct Entry: Codable, Equatable {
        var excludeRules: String
        let syncCodexFiles: Bool
        let syncClaudeFiles: Bool
        let syncTemporaryFiles: Bool

        init(_ pair: SyncPair) {
            excludeRules = pair.excludeRules
            syncCodexFiles = pair.syncCodexFiles
            syncClaudeFiles = pair.syncClaudeFiles
            syncTemporaryFiles = pair.syncTemporaryFiles
        }

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

    /// Only a missing file permits legacy fallback. Symlinks, non-regular files,
    /// read failures and malformed data all fail closed.
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
            // A file observed above is not a first-use fallback if it becomes
            // inaccessible before open.
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

    private static func checkManaged(_ config: SyncConfig, pairs: [BoundPair],
                                     document: Document?) throws {
        if !config.oneDriveRulesManagedPaths.isEmpty && document == nil {
            throw Failure.missingPolicy
        }
        for pair in pairs where config.oneDriveRulesManagedPaths.contains(pair.key) {
            guard document?.pairs[pair.key] != nil else { throw Failure.missingPolicy }
        }
    }

    private static func resolved(_ config: SyncConfig, pairs: [BoundPair],
                                 document: Document?) -> (config: SyncConfig, managed: Set<UUID>) {
        guard let document else { return (config, []) }
        var config = config
        var managed = Set<UUID>()
        for pair in pairs {
            guard let entry = document.pairs[pair.key] else { continue }
            entry.apply(to: &config.pairs[pair.index])
            config.oneDriveRulesManagedPaths.insert(pair.key)
            managed.insert(config.pairs[pair.index].id)
        }
        if !managed.isEmpty { config.excludeLatexIntermediates = document.excludeLatexIntermediates }
        return (config, managed)
    }

    static func read(_ config: SyncConfig) throws -> (config: SyncConfig, managed: Set<UUID>) {
        if !config.oneDriveRulesManagedPaths.isEmpty && !isOneDriveRoot(config.oneDriveRoot) {
            throw Failure.rootUnavailable
        }
        let pairs = boundPairs(config)
        guard !pairs.isEmpty else { return (config, []) }
        let url = try sharedURL(config)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinatorError: NSError?
        var result: Result<Document?, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinatorError) { location in
            result = Result { try load(at: location) }
        }
        if let coordinatorError { throw coordinatorError }
        guard let result else { throw Failure.rootUnavailable }
        let document = try result.get()
        try checkManaged(config, pairs: pairs, document: document)
        return resolved(config, pairs: pairs, document: document)
    }

    private static func bootstrap(_ pair: SyncPair) throws -> Entry? {
        let roots = [pair.localPath, pair.cloudPath].map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        }
        guard !pair.localPath.isEmpty, !pair.cloudPath.isEmpty,
              try roots.allSatisfy(directoryExists) else { return nil }
        var sources = [pair.excludeRules]
        for root in roots {
            guard let data = try boundedData(at: root.appendingPathComponent(".pathsyncignore")) else {
                continue
            }
            guard var text = String(data: data, encoding: .utf8) else { throw Failure.invalidDocument }
            if text.first == "\u{FEFF}" { text.removeFirst() }
            sources.append(text)
        }
        var seen = Set<String>()
        let lines = sources.flatMap { $0.components(separatedBy: .newlines) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        var entry = Entry(pair)
        entry.excludeRules = lines.joined(separator: "\n")
        return entry
    }

    static func update(_ config: SyncConfig, replacing previous: SyncConfig? = nil,
                       migrate: Bool = true) throws -> (config: SyncConfig, managed: Set<UUID>) {
        if !config.oneDriveRulesManagedPaths.isEmpty && !isOneDriveRoot(config.oneDriveRoot) {
            throw Failure.rootUnavailable
        }
        let pairs = boundPairs(config)
        guard !pairs.isEmpty else { return (config, []) }
        let url = try sharedURL(config)
        let previous = previous.flatMap { saved in
            URL(fileURLWithPath: saved.oneDriveRoot).standardizedFileURL.path ==
                URL(fileURLWithPath: config.oneDriveRoot).standardizedFileURL.path ? saved : nil
        }
        var previousEntries = [String: Entry]()
        if let previous {
            for bound in boundPairs(previous) {
                previousEntries[bound.key] = Entry(previous.pairs[bound.index])
            }
        }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinatorError: NSError?
        var result: Result<Document?, Error>?
        coordinator.coordinate(writingItemAt: url, options: [], error: &coordinatorError) { location in
            result = Result {
                let existing = try load(at: location)
                try checkManaged(config, pairs: pairs, document: existing)
                if let previous { try checkManaged(previous, pairs: pairs, document: existing) }
                var document = existing ?? Document(excludeLatexIntermediates: config.excludeLatexIntermediates)
                for bound in pairs {
                    let pair = config.pairs[bound.index]
                    if let current = document.pairs[bound.key] {
                        let desired = Entry(pair)
                        guard let original = previousEntries[bound.key], original != desired else { continue }
                        guard current == original || current == desired else { throw Failure.staleEdit(pair.name) }
                        document.pairs[bound.key] = desired
                    } else if migrate {
                        document.pairs[bound.key] = try bootstrap(pair)
                    }
                }
                if pairs.contains(where: { document.pairs[$0.key] != nil }), let previous,
                   config.excludeLatexIntermediates != previous.excludeLatexIntermediates {
                    let desired = config.excludeLatexIntermediates
                    let current = document.excludeLatexIntermediates
                    guard current == previous.excludeLatexIntermediates || current == desired else {
                        throw Failure.staleEdit("LaTeX 中间文件")
                    }
                    document.excludeLatexIntermediates = desired
                }
                guard !document.pairs.isEmpty else { return existing }
                guard document != existing else { return existing }
                try document.validate()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(document)
                guard data.count <= maximumBytes else { throw Failure.oversized }
                try data.write(to: location, options: .atomic)
                guard try boundedData(at: location) == data else { throw Failure.writeVerification }
                return document
            }
        }
        if let coordinatorError { throw coordinatorError }
        guard let result else { throw Failure.rootUnavailable }
        return resolved(config, pairs: pairs, document: try result.get())
    }
}
