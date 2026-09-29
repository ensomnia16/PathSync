import Foundation

@main
struct CloudConfigChecks {
    static func main() throws {
        let originalRoot = "/Users/alice/Library/CloudStorage/OneDrive-Personal"
        let otherRoot = "/Users/bob/Library/CloudStorage/OneDrive-Personal"
        let pairID = UUID()
        var source = SyncConfig()
        source.oneDriveRoot = originalRoot
        source.localRoot = "/Users/alice/Documents"
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
        assert(profile.pairs[0].syncCodexFiles == true)
        assert(profile.pairs[0].syncClaudeFiles == true)
        assert(profile.pairs[0].syncTemporaryFiles == false)
        assert(profile.pairs[0].localRelativePath == "科研")
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
        target.localRoot = "/Users/bob/Documents"
        target.pairs = [SyncPair(id: pairID, name: "旧名称",
                                 localPath: "/Users/bob/Documents/Research",
                                 cloudPath: otherRoot + "/文档/科研",
                                 scheduledDirection: "download", enabled: true)]
        let imported = try importing(profile, into: target)
        assert(imported.pairs[0].name == "科研")
        assert(!imported.pairs[0].syncTemporaryFiles)
        assert(imported.pairs[0].localPath == target.pairs[0].localPath)
        assert(imported.pairs[0].cloudPath == otherRoot + "/文档/科研")
        assert(!imported.pairs[0].enabled) // Direction changed; review before re-enabling.
        assert(imported.pairs[1].localPath.isEmpty && !imported.pairs[1].enabled)
        assert(imported.pairs[2].id == newPairID)
        assert(imported.pairs[2].cloudPath == otherRoot + "/文档/论文")
        assert(imported.pairs[2].localPath == "/Users/bob/Documents/论文" && !imported.pairs[2].enabled)
        assert(imported.cloudImportAnchors[alice.uuidString.lowercased()]?.revisionID == profile.revisionID)

        var localEdit = imported
        localEdit.conflictPolicy = "newest"
        let preview = try CloudImportPreview(profile: profile, current: localEdit)
        assert(preview.localEditsConflict)
        assert(!preview.bothChanged)
        assert(preview.ruleChanges.contains("conflict"))
        var withExtra = imported
        withExtra.pairs.append(SyncPair(name: "只在本机", localPath: "/tmp/only-here"))
        let noFalseConflict = try CloudImportPreview(profile: profile, current: withExtra)
        assert(!noFalseConflict.localEditsConflict)
        var remoteEdit = source
        remoteEdit.backupRetentionDays = 30
        let newerProfile = CloudConfiguration(config: remoteEdit, deviceID: alice, deviceName: "Alice Mac")
        let divergent = try CloudImportPreview(profile: newerProfile, current: localEdit)
        assert(divergent.bothChanged)

        var placeholder = source
        placeholder.pairs.append(SyncPair())
        let encodedPlaceholder = try JSONEncoder().encode(placeholder)
        let decodedPlaceholder = try JSONDecoder().decode(SyncConfig.self, from: encodedPlaceholder)
        assert(decodedPlaceholder.pairs.count == source.pairs.count)
        assert(CloudConfiguration(config: placeholder, deviceID: UUID(), deviceName: "X").pairs.count == source.pairs.count)

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

        var malicious = tampered
        var badLocal = malicious["pairs"] as! [[String: Any]]
        badLocal[0]["oneDriveRelativePath"] = "文档/科研"
        badLocal[0]["localRelativePath"] = "../escape"
        malicious["pairs"] = badLocal
        let badLocalProfile = try JSONDecoder().decode(CloudConfiguration.self,
            from: JSONSerialization.data(withJSONObject: malicious))
        assert((try? badLocalProfile.validate()) == nil)
        var oldShape = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        oldShape.removeValue(forKey: "importedRevisions")
        var oldPairs = oldShape["pairs"] as! [[String: Any]]
        for index in oldPairs.indices {
            oldPairs[index].removeValue(forKey: "localRelativePath")
            oldPairs[index].removeValue(forKey: "syncCodexFiles")
            oldPairs[index].removeValue(forKey: "syncClaudeFiles")
            oldPairs[index].removeValue(forKey: "syncTemporaryFiles")
        }
        oldShape["pairs"] = oldPairs
        let oldProfile = try JSONDecoder().decode(CloudConfiguration.self,
            from: JSONSerialization.data(withJSONObject: oldShape))
        try oldProfile.validate()
        assert(!oldProfile.includesPairFilters)
        assert(oldProfile.sharedDigest == oldProfile.digest(includeFilters: false))
        let legacyPair = try JSONDecoder().decode(SyncPair.self,
            from: Data("""
            {"id":"\(UUID().uuidString)","name":"legacy","localPath":"/tmp/a","cloudPath":"/tmp/b","scheduledDirection":"merge","enabled":false}
            """.utf8))
        assert(legacyPair.syncCodexFiles && legacyPair.syncClaudeFiles && legacyPair.syncTemporaryFiles)
        var legacyWithPlaceholder = oldShape
        var legacyPairs = legacyWithPlaceholder["pairs"] as! [[String: Any]]
        legacyPairs.append(["id": UUID().uuidString, "name": "新路径", "scheduledDirection": "merge"])
        legacyWithPlaceholder["pairs"] = legacyPairs
        let legacyProfile = try JSONDecoder().decode(CloudConfiguration.self,
            from: JSONSerialization.data(withJSONObject: legacyWithPlaceholder))
        let withoutPlaceholder = try importing(legacyProfile, into: target)
        assert(legacyProfile.effectivePairs.count == profile.pairs.count)
        assert(withoutPlaceholder.pairs.count == profile.pairs.count)
        assert(withoutPlaceholder.pairs[2].localPath == "/Users/bob/Documents/论文")

        let legacyCity = CloudConfigPair(id: UUID(), name: "CityU Meeting",
                                         scheduledDirection: "merge",
                                         oneDriveRelativePath: "文档/研三/CityU Meeting",
                                         localRelativePath: nil)
        assert(importedLocalRelativePath(legacyCity) == "研三/CityU Meeting")
        let nonDocuments = CloudConfigPair(id: UUID(), name: "Images",
                                           scheduledDirection: "merge",
                                           oneDriveRelativePath: "Pictures/Images",
                                           localRelativePath: nil)
        assert(importedLocalRelativePath(nonDocuments) == "Pictures/Images")

        let newLocalRoot = temporary.appendingPathComponent("Documents", isDirectory: true)
        let newCloudRoot = temporary.appendingPathComponent("OneDrive-Personal", isDirectory: true)
        try FileManager.default.createDirectory(at: newLocalRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newCloudRoot, withIntermediateDirectories: true)
        var freshTarget = SyncConfig()
        freshTarget.localRoot = newLocalRoot.path
        freshTarget.oneDriveRoot = newCloudRoot.path
        let legacyPreview = try CloudImportPreview(profile: legacyProfile, current: freshTarget)
        assert(legacyPreview.proposed.pairs[0].localPath == newLocalRoot.appendingPathComponent("科研").path)
        assert(legacyPreview.proposed.pairs[2].localPath == newLocalRoot.appendingPathComponent("论文").path)
        assert(legacyPreview.localFoldersToCreate.count == 2)
        assert(legacyPreview.proposed.pairs.allSatisfy { !$0.enabled })
        try createImportedLocalFolders(legacyPreview)
        assert(FileManager.default.fileExists(atPath: newLocalRoot.appendingPathComponent("科研").path))
        assert(FileManager.default.fileExists(atPath: newLocalRoot.appendingPathComponent("论文").path))

        let symlinkRoot = temporary.appendingPathComponent("UnsafeDocuments", isDirectory: true)
        try FileManager.default.createDirectory(at: symlinkRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlinkRoot.appendingPathComponent("研三"),
                                                     withDestinationURL: newCloudRoot)
        var nestedSource = source
        nestedSource.pairs = [SyncPair(name: "CityU Meeting",
                                       localPath: "/Users/alice/Documents/研三/CityU Meeting",
                                       cloudPath: originalRoot + "/文档/研三/CityU Meeting")]
        let nestedProfile = CloudConfiguration(config: nestedSource, deviceID: alice, deviceName: "Alice Mac")
        freshTarget.localRoot = symlinkRoot.path
        let unsafePreview = try CloudImportPreview(profile: nestedProfile, current: freshTarget)
        assert((try? createImportedLocalFolders(unsafePreview)) == nil)

        let folderA = temporary.appendingPathComponent("A", isDirectory: true)
        let folderChild = folderA.appendingPathComponent("child", isDirectory: true)
        let folderB = temporary.appendingPathComponent("B", isDirectory: true)
        let folderC = temporary.appendingPathComponent("C", isDirectory: true)
        for folder in [folderA, folderChild, folderB, folderC] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let first = SyncPair(name: "first", localPath: folderA.path, cloudPath: folderB.path, enabled: true)
        let second = SyncPair(name: "second", localPath: folderChild.path, cloudPath: folderC.path, enabled: true)
        assert((try? validatedPairSet([first, second])) == nil)
        var disabledSecond = second
        disabledSecond.enabled = false
        try validatedPairSet([first, disabledSecond])
        assert((try? validatedPairSet([first, disabledSecond], including: disabledSecond.id)) == nil)

        let configURL = temporary.appendingPathComponent("config.json")
        try saveConfig(source, at: configURL.path)
        var newer = source
        newer.dailyHour = 20
        try saveConfig(newer, at: configURL.path)
        let snapshots = configSnapshots(at: configURL.path)
        assert(snapshots.count == 1)
        let restoredSnapshot = try loadConfig(snapshots[0].url.path)
        assert(restoredSnapshot.dailyHour == 23)

        let texA = folderA.appendingPathComponent("main.tex")
        let texB = folderB.appendingPathComponent("main.tex")
        try "\\section{Intro}\nOld line\n".write(to: texA, atomically: true, encoding: .utf8)
        try "\\section{Intro}\nNew line\n".write(to: texB, atomically: true, encoding: .utf8)
        let diff = makeLatexDiff(left: texA, right: texB, leftTitle: "local", rightTitle: "cloud", language: "en")
        assert(diff.error == nil && diff.summary.contains("Intro"))
        assert(diff.unifiedDiff.contains("+New line"))
        assert(safeHistoryFile(root: folderA.path, relative: "../B/main.tex") == nil)
        let symlink = folderA.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: folderB)
        assert(safeHistoryFile(root: folderA.path, relative: "escape/main.tex") == nil)
        if ProcessInfo.processInfo.environment["PATHSYNC_TEST_CODEX_AI"] == "1" {
            let summary = try summarizeLatexDiffWithCodex(diff, language: "zh-Hans")
            assert(!summary.isEmpty)
        }

        print("cloud configuration checks passed")
    }
}
