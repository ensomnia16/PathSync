import Foundation

private let cloudOnlyErrorDomain = "com.ensom.PathSync.CloudOnlyStorage"

private func cloudOnlyError(_ message: String, code: Int = 1) -> NSError {
    NSError(domain: cloudOnlyErrorDomain, code: code,
            userInfo: [NSLocalizedDescriptionKey: message])
}

/// A literal path below one pair's root, never an exclusion pattern. Preserve
/// whitespace in real names; only canonical Unicode and a single trailing slash
/// are normalized. Filesystem containment and symlinks are checked by the runner.
func normalizeCloudOnlyPath(_ text: String) throws -> String {
    var path = text.precomposedStringWithCanonicalMapping
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
          !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0 == "\u{2028}" || $0 == "\u{2029}" }),
          !path.contains("//"), !path.contains(where: { "*?[]{}".contains($0) }) else {
        throw cloudOnlyError("仅云端路径必须是具体的相对子路径，不能是根目录、绝对路径或通配规则。")
    }
    if path.hasSuffix("/") { path.removeLast() }
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !path.isEmpty, path.utf8.count <= 4_096,
          components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
        throw cloudOnlyError("仅云端路径不能包含空分段、. 或 ..，也不能超过 4096 字节。")
    }
    return path
}

/// Duplicate spellings are harmless, but nested selections obscure which option
/// owns a subtree when it is later restored to local storage.
func validatedCloudOnlyPaths(_ paths: [String]) throws -> [String] {
    let normalized = try Array(Set(paths.map(normalizeCloudOnlyPath))).sorted()
    let selected = Set(normalized)
    for path in normalized {
        let components = path.split(separator: "/")
        guard components.count > 1 else { continue }
        for length in 1..<components.count {
            let ancestor = components.prefix(length).joined(separator: "/")
            guard !selected.contains(ancestor) else {
                throw cloudOnlyError("仅云端路径「\(ancestor)」已包含「\(path)」，请只保留其中一项。")
            }
        }
    }
    return normalized
}

func cloudOnlyArguments(_ pair: SyncPair) throws -> [String] {
    try validatedCloudOnlyPaths(pair.cloudOnlyPaths).map { "--cloud-only=" + $0 }
}

func cloudOnlyTransitionPaths(from old: [String], to new: [String]) throws -> [String] {
    let old = try validatedCloudOnlyPaths(old)
    let new = try validatedCloudOnlyPaths(new)
    guard old != new else { return [] }
    let union = Set(old + new)
    return union.filter { path in
        !union.contains { ancestor in ancestor != path && path.hasPrefix(ancestor + "/") }
    }.sorted()
}

/// The caller owns the global lock. Retire metadata before committing a local
/// policy transition, including an unpin before the first scheduled sync.
func retireCloudOnlyBaselines(_ pair: SyncPair, paths: [String]) throws {
    let paths = try validatedCloudOnlyPaths(paths)
    guard !paths.isEmpty, FileManager.default.fileExists(atPath: mergeStatePath(pair)),
          try !mergeStateIsStale(pair) else { return }
    guard let resources = Bundle.main.resourceURL else {
        throw cloudOnlyError("应用资源目录不可用，无法安全保存仅云端设置。")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-B", resources.appendingPathComponent("sync_merge.py").path,
                         URL(fileURLWithPath: pair.localPath).standardizedFileURL.resolvingSymlinksInPath().path,
                         URL(fileURLWithPath: pair.cloudPath).standardizedFileURL.resolvingSymlinksInPath().path,
                         mergeStatePath(pair), "--retire-cloud-only", "--shared-excludes"]
        + paths.map { "--cloud-only=" + $0 }
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let message = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        throw cloudOnlyError("无法安全保存仅云端设置；旧设置仍保留。\n" + message)
    }
}

/// Runs only the runner's dedicated release operation. The caller dispatches
/// this synchronous function off the main thread and has already explained that
/// the target-folder copy, rather than server upload completion, is verified.
/// It never invokes OneDrive cache eviction or an ordinary sync.
func releaseCloudOnlyWorkingCopy(_ pair: SyncPair, relativePath: String,
                                configuration: SyncConfig,
                                progress: ((String) -> Void)? = nil) throws -> String {
    try withSyncLock {
        let selectedPath = try normalizeCloudOnlyPath(relativePath)
        let selectedPaths = try validatedCloudOnlyPaths(pair.cloudOnlyPaths)
        guard selectedPaths.contains(selectedPath) else {
            throw cloudOnlyError("请先将「\(selectedPath)」保存为这台 Mac 的仅云端路径，再释放本地工作副本。")
        }

        // Root policy must be reread under the same lock as the release. Cached
        // exclusions are never passed to the subprocess.
        let effective = try OneDriveRules.read(configuration, requiring: [pair.id]).config
        guard let resolved = effective.pairs.first(where: { $0.id == pair.id }) else {
            throw cloudOnlyError("找不到要释放空间的路径组。")
        }
        guard try validatedCloudOnlyPaths(resolved.cloudOnlyPaths) == selectedPaths else {
            throw cloudOnlyError("仅云端设置已改变，请保存设置并刷新后重试。")
        }
        let (local, cloud) = try validatedPaths(pair)
        let (configuredLocal, configuredCloud) = try validatedPaths(resolved)
        guard local == configuredLocal, cloud == configuredCloud else {
            throw cloudOnlyError("同步目录已改变，请保存设置并刷新后重试。")
        }
        guard let resources = Bundle.main.resourceURL else {
            throw cloudOnlyError("应用资源目录不可用，无法释放本地工作副本。")
        }
        let helper = resources.appendingPathComponent("sync_merge.py")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: helper.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw cloudOnlyError("应用缺少 sync_merge.py，请重新安装后重试。")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-B", helper.path, local, cloud, mergeStatePath(resolved),
                             "--release-local=" + selectedPath]
            + (try cloudOnlyArguments(resolved))
            + syncFilterArguments(resolved, excludeLatex: effective.excludeLatexIntermediates)
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()

        // One shared pipe drains stdout and stderr while the process runs, so a
        // full stderr buffer cannot deadlock a lengthy verification. Buffer raw
        // bytes until a complete line to handle split UTF-8 characters correctly.
        var pending = Data()
        var messages: [String] = []
        var releasedSummary: String?
        func accept(_ bytes: Data) {
            var line = String(decoding: bytes, as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            if line.hasPrefix("PROGRESS\t") {
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                let detail = fields.count >= 4 && fields[1] == "RELEASE_VERIFY"
                    ? String(format: uiText("cloudOnlyVerifiedFiles", language: configuration.language), fields[2], fields[3])
                    : fields.dropFirst().joined(separator: " · ")
                progress?(detail)
            } else {
                messages.append(line)
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                if fields.first == "RELEASED_LOCAL", fields.count >= 3,
                   let count = fields.first(where: { $0.hasPrefix("files=") }) {
                    releasedSummary = String(format: uiText("cloudOnlyReleaseSummary", language: configuration.language),
                                             fields[1], String(count.dropFirst("files=".count)))
                }
            }
        }
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                accept(Data(pending[..<newline]))
                pending.removeSubrange(...newline)
            }
        }
        if !pending.isEmpty { accept(pending) }
        process.waitUntilExit()
        let summary = messages.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let status = process.terminationReason == .uncaughtSignal
                ? "被信号 \(process.terminationStatus) 中止" : "退出码 \(process.terminationStatus)"
            let detail = summary.isEmpty ? status : "\(status)：\n\(summary)"
            throw cloudOnlyError("「\(pair.name)」释放空间未完成，\(detail)",
                                 code: Int(process.terminationStatus))
        }
        return releasedSummary ?? (summary.isEmpty ? "本地工作副本释放操作已完成。" : summary)
    }
}
