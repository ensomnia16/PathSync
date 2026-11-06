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
        let otherLocal = temporary.appendingPathComponent("second")
        for folder in [cloud, local, otherLocal] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try "local/\n".write(to: local.appendingPathComponent(".pathsyncignore"), atomically: true, encoding: .utf8)
        try "cloud/\n".write(to: cloud.appendingPathComponent(".pathsyncignore"), atomically: true, encoding: .utf8)
        var first = SyncConfig()
        first.pairs = [SyncPair(name: "Research", localPath: local.path, cloudPath: cloud.path,
                                enabled: true, excludeRules: "app/")]
        first.inferOneDriveRootIfNeeded()
        assert(first.oneDriveRoot == root.path)
        let migrated = try OneDriveRules.update(first)
        let combined = migrated.config.pairs[0].excludeRules
        assert(Set(combined.split(separator: "\n")) == ["app/", "local/", "cloud/"])

        var second = first
        second.pairs[0] = SyncPair(name: "Other Mac", localPath: otherLocal.path,
                                   cloudPath: cloud.path, excludeRules: "stale/")
        let received = try OneDriveRules.update(second)
        assert(received.managed == [second.pairs[0].id])
        assert(received.config.pairs[0].excludeRules == combined)

        var edited = migrated.config
        edited.pairs[0].excludeRules = "new/"
        let updated = try OneDriveRules.update(edited, replacing: migrated.config)
        let remoteRules = try OneDriveRules.read(received.config)
        assert(remoteRules.config.pairs[0].excludeRules == "new/")
        try fm.removeItem(at: root.appendingPathComponent(OneDriveRules.filename))
        do {
            _ = try OneDriveRules.read(updated.config)
            preconditionFailure("Previously managed rules must not silently fall back")
        } catch {
            // A missing shared policy stops sync before project file operations.
        }

        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as! [String: Any]
        old["cloudConfigEnabled"] = true
        old["cloudImportAnchors"] = ["old": ["unused": "legacy"]]
        let decoded = try JSONDecoder().decode(SyncConfig.self, from: JSONSerialization.data(withJSONObject: old))
        let current = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as! [String: Any]
        assert(current["cloudConfigEnabled"] == nil && current["cloudImportAnchors"] == nil)
        assert(decoded.pairs == first.pairs)
    }
}
