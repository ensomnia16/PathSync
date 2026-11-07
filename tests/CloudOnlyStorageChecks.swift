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
        print("Cloud-only literal paths: traversal/globs rejected, NFC normalized, duplicates removed, nesting rejected; arguments remain separate values.")
    }
}
