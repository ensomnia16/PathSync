import Foundation

@main
struct CloudOnlyStorageChecks {
    static func main() throws {
        func check(_ condition: Bool) { precondition(condition) }
        func rejects(_ path: String) {
            do {
                _ = try normalizeCloudOnlyPath(path)
                preconditionFailure("Unsafe cloud-only path accepted: \(path.debugDescription)")
            } catch { }
        }
        for path in ["", "/", "//", "/root", ".", "./", "..", "../result",
                     "results/./run", "results/../run", "results//run", "results//",
                     "results/*", "results/a?", "results/[ab]", "results/{a,b}", "a\0b",
                     "a\\b", "a\nb", "a\rb", "a\tb", "a\u{2028}b", "a\u{2029}b",
                     "a\u{200B}b", "a\u{202E}b"] {
            rejects(path)
        }
        rejects(String(repeating: "a", count: 4_097))
        check(try normalizeCloudOnlyPath("results/run/") == "results/run")
        check(try normalizeCloudOnlyPath(".env") == ".env")
        check(try normalizeCloudOnlyPath("..cache/result.tar") == "..cache/result.tar")
        check(try normalizeCloudOnlyPath(" work / exact name ") == " work / exact name ")
        let decomposed = "re\u{301}sults/cafe\u{301}"
        let normalized = try normalizeCloudOnlyPath(decomposed)
        precondition(Array(normalized.utf8) == Array("résults/café".utf8), "Normalize stored paths to NFC")

        check(try validatedCloudOnlyPaths([]).isEmpty)
        check(try validatedCloudOnlyPaths(["b/", "a", "b", "a/"]) == ["a", "b"])
        check(try validatedCloudOnlyPaths(["results", "results-old", "run/a", "run/b"])
                     == ["results", "results-old", "run/a", "run/b"])
        check(try validatedCloudOnlyPaths(["café", "cafe\u{301}/"]).count == 1)
        check(try cloudOnlyTransitionPaths(from: [], to: ["data/raw"]) == ["data/raw"])
        check(try cloudOnlyTransitionPaths(from: ["data/raw"], to: []) == ["data/raw"])
        check(try cloudOnlyTransitionPaths(from: ["data/raw"], to: ["data"]) == ["data"])
        check(try cloudOnlyTransitionPaths(from: ["data"], to: ["data/raw"]) == ["data"])
        check(try cloudOnlyTransitionPaths(from: ["data/"], to: ["data"]).isEmpty)
        for paths in [["results", "results/run"], ["results/run", "results"],
                      ["cafe\u{301}", "café/run"], ["a/b", "a/b/c/d"]] {
            do {
                _ = try validatedCloudOnlyPaths(paths)
                preconditionFailure("Overlapping cloud-only selections accepted: \(paths)")
            } catch { }
        }

        var pair = SyncPair()
        pair.cloudOnlyPaths = ["results/", "--literal", "with space", "results"]
        precondition(!pair.isUnusedDefaultPlaceholder, "A draft with residency choices is not an unused placeholder")
        let arguments = try cloudOnlyArguments(pair)
        precondition(arguments == ["--cloud-only=--literal", "--cloud-only=results", "--cloud-only=with space"])
        pair.cloudOnlyPaths = ["../unsafe"]
        do {
            _ = try cloudOnlyArguments(pair)
            preconditionFailure("Invalid cloud-only options reached the process arguments")
        } catch { }
        let manager = FileManager.default
        let root = manager.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        pair.localPath = root.appendingPathComponent("local").path
        pair.cloudPath = root.appendingPathComponent("cloud").path
        pair.cloudOnlyPaths = ["data"]
        let local = URL(fileURLWithPath: pair.localPath).appendingPathComponent("data")
        let cloud = URL(fileURLWithPath: pair.cloudPath).appendingPathComponent("data")
        try manager.createDirectory(at: cloud, withIntermediateDirectories: true)
        let state = root.appendingPathComponent("state.json").path
        let index = URL(fileURLWithPath: state + ".cloud-only-releases", isDirectory: true)
        try manager.createDirectory(at: index, withIntermediateDirectories: true)
        let pointer = index.appendingPathComponent("release.json")
        let receipt: [String: String] = ["status": "released", "relative": "data", "state": state,
                                       "target": local.path, "cloud": cloud.path]
        func status() -> CloudOnlyWorkingCopyStatus? {
            cloudOnlyWorkingCopyStatuses(pair, statePath: state)["data"]
        }
        check(status() == .missing)
        try JSONSerialization.data(withJSONObject: receipt).write(to: pointer)
        check(status() == .released)
        for key in ["status", "relative", "state", "target", "cloud"] {
            var invalid = receipt
            invalid[key] = "other"
            try JSONSerialization.data(withJSONObject: invalid).write(to: pointer)
            check(status() == .missing)
        }
        try JSONSerialization.data(withJSONObject: receipt).write(to: pointer)
        try manager.createDirectory(at: local, withIntermediateDirectories: true)
        check(status() == .present)
        try manager.removeItem(at: local)
        try manager.removeItem(at: cloud)
        check(status() == .missing)
        try manager.createSymbolicLink(at: cloud, withDestinationURL: root)
        check(status() == .missing)
        try manager.removeItem(at: cloud)
        try manager.createDirectory(at: cloud, withIntermediateDirectories: true)
        try manager.removeItem(at: pointer)
        let other = root.appendingPathComponent("external.json")
        try JSONSerialization.data(withJSONObject: receipt).write(to: other)
        try manager.createSymbolicLink(at: pointer, withDestinationURL: other)
        check(status() == .missing)
        print("Working-copy states: completed records match roots and policy; recreated files enable verification; missing or unproven copies never appear released.")
        print("Cloud-only literal paths: traversal/globs rejected, NFC normalized, duplicates removed, nesting rejected; arguments remain separate values.")
    }
}
