import Foundation

@main
struct SyncProgressChecks {
    static func main() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = UUID(), second = UUID()
        var item = SyncPairProgress(id: first)
        func event(_ line: String) -> [Substring] { line.split(separator: "\t") }
        assert(item.consume(event("PROGRESS\tSCAN\tlocal\t12\t500")))
        assert(item.fraction == nil, "scanning has no known total")
        assert(item.consume(event("PROGRESS\tGRAPH\tPAGE\t2\t100")))
        assert(item.fraction == nil, "pages do not imply a percentage")
        assert(item.consume(event("PROGRESS\tPREFETCH\t0\t20")))
        assert(item.consume(event("PROGRESS\tPROCESS\t128\t256")))
        assert(item.fraction == 0.5)
        assert(item.consume(event("PROGRESS\tPREFETCH\t8\t20")))
        assert(item.fraction == 0.5 && item.downloadsRead == 8, "interleaved downloads must preserve file-check progress")
        assert(item.consume(event("PROGRESS\tWAIT\tfoo/bar.pdf\t20")))
        assert(item.fraction == 0.5 && item.waitSeconds == 20 && item.currentFile == "foo/bar.pdf")
        let before = item
        assert(!item.consume(event("PROGRESS\tPROCESS\t300\t256")))
        assert(!item.consume(event("PROGRESS\tPROCESS\t-1\t256")))
        assert(!item.consume(event("PROGRESS\tPREFETCH\tbad\t20")))
        assert(item == before)
        assert(item.consume(event("PROGRESS\tPROCESS\t0\t0")))
        assert(item.fraction == nil, "empty file lists must not divide by zero")
        assert(item.consume(event("PROGRESS\tFINALIZE\tpackages")))
        assert(item.fraction == nil, "file checks finishing is not sync success")
        let path = root.appendingPathComponent("progress.json").path
        let run = UUID().uuidString
        let store = SyncProgressStore(runID: run, pairIDs: [first, second], path: path)
        assert(SyncProgressSnapshot.read(runID: UUID().uuidString, at: path) == nil, "ignore earlier runs")
        assert(SyncProgressSnapshot.read(runID: run, at: path)?.finishedCount == 0)
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            var value = SyncPairProgress(id: index % 2 == 0 ? first : second)
            value.processed = index; value.total = 40; value.stage = .files
            store.update(value)
        }
        store.complete(first, state: .incomplete)
        store.complete(second, state: .completed)
        let snapshot = SyncProgressSnapshot.read(runID: run, at: path)!
        assert(snapshot.finishedCount == 2 && snapshot.pairs.count == 2)
        assert(snapshot.pairs[0].state == .incomplete && snapshot.pairs[1].fraction == 1)
        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        assert(permissions?.intValue == 0o600)
        // An old writer's cleanup must not delete a newer run's report.
        let next = SyncProgressStore(runID: UUID().uuidString, pairIDs: [first], path: path)
        store.finish()
        assert(FileManager.default.fileExists(atPath: path))
        next.finish()
        assert(!FileManager.default.fileExists(atPath: path))
        print("Stage counters, interleaved downloads, unknown totals, concurrent writers and run isolation passed.")
    }
}
