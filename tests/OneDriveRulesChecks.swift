import Foundation

@main
struct OneDriveRulesChecks {
    static func main() throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("Library/CloudStorage/OneDrive-Fixture")
        let cloud = root.appendingPathComponent("Documents/Research")
        let local = temporary.appendingPathComponent("first")
        for folder in [cloud, local] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        // Neither local rule text nor malformed legacy files may become inputs.
        try Data([0xFF]).write(to: local.appendingPathComponent(".pathsyncignore"))
        try fm.createDirectory(at: cloud.appendingPathComponent(".pathsyncignore"), withIntermediateDirectories: true)
        var config = SyncConfig()
        config.pairs = [SyncPair(name: "Research", localPath: local.path, cloudPath: cloud.path,
                                  enabled: true, syncCodexFiles: false, excludeRules: "local-only/")]
        config.inferOneDriveRootIfNeeded()
        let policy = root.appendingPathComponent(OneDriveRules.filename)
        func rejects(_ candidate: SyncConfig, requiring ids: Set<UUID>? = nil) {
            do { _ = try OneDriveRules.read(candidate, requiring: ids); preconditionFailure("Missing/invalid central policy must stop this run") }
            catch { }
        }
        rejects(config)
        assert(!fm.fileExists(atPath: policy.path), "read must never bootstrap the central file")
        func writePolicy(_ rules: String) throws {
            let document: [String: Any] = ["version": 1, "excludeLatexIntermediates": false,
                "pairs": ["Documents/Research": ["excludeRules": rules, "syncCodexFiles": true,
                          "syncClaudeFiles": true, "syncTemporaryFiles": true]]]
            try JSONSerialization.data(withJSONObject: document).write(to: policy)
        }
        try writePolicy("central-only/\n# comment")
        let before = try Data(contentsOf: policy)
        let received = try OneDriveRules.read(config)
        assert(received.config.pairs[0].excludePatterns == ["central-only/"])
        assert(received.config.pairs[0].syncCodexFiles && received.config.pairs[0].syncClaudeFiles)
        assert(received.config.pairs[0].syncTemporaryFiles && !received.config.excludeLatexIntermediates)
        assert(received.managed == [config.pairs[0].id])
        let arguments = syncFilterArguments(received.config.pairs[0], excludeLatex: received.config.excludeLatexIntermediates)
        assert(arguments.contains("--shared-excludes") && !arguments.contains("--include-temp"))
        assert(!arguments.contains("--skip-claude") && !arguments.contains("--skip-codex"))
        assert(arguments.contains("--exclude=central-only/") && !arguments.contains("--exclude=local-only/"))
        let afterRead = try Data(contentsOf: policy)
        assert(afterRead == before, "loading/saving settings must not edit central rules")
        var stale = received.config
        stale.pairs[0].excludeRules = "stale-local/"
        try writePolicy("updated-central/")
        let updated = try OneDriveRules.read(stale)
        assert(updated.config.pairs[0].excludePatterns == ["updated-central/"])
        let bytes = try JSONEncoder().encode(stale)
        let saved = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        let pair = (saved["pairs"] as! [[String: Any]])[0]
        for field in ["excludeRules", "syncCodexFiles", "syncClaudeFiles", "syncTemporaryFiles"] {
            assert(pair[field] == nil, "local config must not persist a second policy")
        }
        assert(saved["excludeLatexIntermediates"] == nil)
        var legacy = saved
        var legacyPair = pair
        legacyPair["excludeRules"] = "legacy/"
        legacyPair["syncCodexFiles"] = false
        legacy["pairs"] = [legacyPair]
        let decoded = try JSONDecoder().decode(SyncConfig.self, from: JSONSerialization.data(withJSONObject: legacy))
        assert(decoded.pairs[0].excludeRules.isEmpty && decoded.pairs[0].syncCodexFiles)
        var missing = config
        missing.pairs[0].cloudPath = root.appendingPathComponent("Documents/Missing").path
        rejects(missing)
        missing.pairs[0].enabled = false
        let disabled = try OneDriveRules.read(missing)
        assert(disabled.managed.isEmpty)
        rejects(missing, requiring: [missing.pairs[0].id])
        var outside = config
        outside.pairs[0].cloudPath = temporary.appendingPathComponent("outside").path
        rejects(outside)
        var oldPolicy = try JSONSerialization.jsonObject(with: Data(contentsOf: policy)) as! [String: Any]
        oldPolicy["excludeLatexIntermediates"] = true
        try JSONSerialization.data(withJSONObject: oldPolicy).write(to: policy)
        rejects(config)
        let model = SyncModel(testConfig: received.config)
        let transient = NSError(domain: "RulesFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture rule conflict"])
        model.acceptRulesRefresh(.failure(transient))
        assert(model.statusKey == "error")
        model.acceptRulesRefresh(.success(received.config))
        assert(model.statusKey == "ready" && model.statusDetail == nil)
        model.statusKey = "error"
        model.statusDetail = "Unrelated sync error"
        model.acceptRulesRefresh(.success(received.config))
        assert(model.statusDetail == "Unrelated sync error")
        try Data("{}".utf8).write(to: policy)
        rejects(config)
        try Data(repeating: 0x20, count: 1_000_001).write(to: policy)
        rejects(config)
        try fm.removeItem(at: policy)
        try fm.createSymbolicLink(at: policy, withDestinationURL: local.appendingPathComponent(".pathsyncignore"))
        rejects(config)
        try fm.removeItem(at: policy)
        rejects(received.config)
        print("Central-only rules: no bootstrap/write-back, legacy fields ignored, live reread, missing/unsafe policy blocks sync.")
    }
}
