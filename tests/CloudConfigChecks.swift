import Foundation

@main
struct CloudConfigChecks {
    static func main() throws {
        let originalRoot = "/Users/alice/Library/CloudStorage/OneDrive-Personal"
        let otherRoot = "/Users/bob/Library/CloudStorage/OneDrive-Personal"
        let pairID = UUID()
        var source = SyncConfig()
        source.oneDriveRoot = originalRoot
        let newPairID = UUID()
        source.pairs = [
            SyncPair(id: pairID, name: "科研",
                     localPath: "/Users/alice/Documents/科研",
                     cloudPath: originalRoot + "/文档/科研",
                     scheduledDirection: "merge", enabled: true),
            SyncPair(name: "外部路径", localPath: "/tmp/work",
                     cloudPath: "/Volumes/External/Folder",
                     scheduledDirection: "upload", enabled: false),
            SyncPair(id: newPairID, name: "论文", localPath: "/Users/alice/Documents/论文",
                     cloudPath: originalRoot + "/文档/论文",
                     scheduledDirection: "merge", enabled: true)
        ]
        let alice = UUID()
        let profile = CloudConfiguration(config: source, deviceID: alice, deviceName: "Alice Mac")
        try profile.validate()
        assert(profile.pairs[0].oneDriveRelativePath == "文档/科研")
        assert(profile.pairs[1].oneDriveRelativePath == nil)
        assert(profile.pairs[2].oneDriveRelativePath == "文档/论文")
        assert(inferredOneDriveRoot(source.pairs[0].cloudPath) == originalRoot)
        assert(path(in: otherRoot, relative: "../escape") == nil)
        assert(path(in: otherRoot, relative: "文档/科研") == otherRoot + "/文档/科研")

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("pathsync-cloud-check-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = CloudConfigStore(root: temporary)
        try store.write(profile)
        let loaded = try store.readOthers(excluding: UUID())
        assert(loaded.count == 1 && loaded[0] == profile)
        let excludingOwn = try store.readOthers(excluding: alice)
        assert(excludingOwn.isEmpty)

        var target = SyncConfig()
        target.oneDriveRoot = otherRoot
        target.pairs = [SyncPair(id: pairID, name: "旧名称",
                                 localPath: "/Users/bob/Documents/Research",
                                 cloudPath: otherRoot + "/文档/科研",
                                 scheduledDirection: "download", enabled: true)]
        let imported = try importing(profile, into: target)
        assert(imported.pairs[0].name == "科研")
        assert(imported.pairs[0].localPath == target.pairs[0].localPath)
        assert(imported.pairs[0].cloudPath == otherRoot + "/文档/科研")
        assert(imported.pairs[0].enabled)
        assert(imported.pairs[1].localPath.isEmpty && !imported.pairs[1].enabled)
        assert(imported.pairs[2].id == newPairID)
        assert(imported.pairs[2].cloudPath == otherRoot + "/文档/论文")
        assert(imported.pairs[2].localPath.isEmpty && !imported.pairs[2].enabled)

        target.pairs[0].cloudPath = otherRoot + "/other"
        let rebound = try importing(profile, into: target)
        assert(!rebound.pairs[0].enabled)
        assert(rebound.pairs[0].cloudPath == otherRoot + "/文档/科研")

        let encoded = try JSONEncoder().encode(profile)
        var tampered = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        var pairs = tampered["pairs"] as! [[String: Any]]
        pairs[0]["oneDriveRelativePath"] = "../outside"
        tampered["pairs"] = pairs
        let badData = try JSONSerialization.data(withJSONObject: tampered)
        let bad = try JSONDecoder().decode(CloudConfiguration.self, from: badData)
        assert((try? bad.validate()) == nil)
        assert((try? store.write(bad)) == nil)

        print("cloud configuration checks passed")
    }
}
