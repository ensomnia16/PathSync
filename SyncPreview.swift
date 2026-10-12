import Foundation

/// One action that sync_merge.py --dry-run --plan-json would take.
struct SyncPlanItem: Decodable, Equatable {
    let action: String
    let name: String
    let side: String?
    let size: Int64?
    let detail: String?
    let reason: String?
    let copy: String?
    let kind: String?
}

struct SyncPlan: Decodable, Equatable {
    let direction: String
    let items: [SyncPlanItem]
    let counts: [String: Int]
}

struct PairPreview: Identifiable {
    let pairID: UUID
    let pairName: String
    let direction: String
    let plan: SyncPlan?
    let error: String?
    var id: UUID { pairID }

    func items(_ action: String) -> [SyncPlanItem] {
        plan?.items.filter { $0.action == action } ?? []
    }

    /// Actions that change a file on either side once the sync is confirmed.
    var changeCount: Int {
        plan?.items.filter { ["upload", "download", "delete", "keep_both", "newest"].contains($0.action) }.count ?? 0
    }

    var attentionCount: Int {
        plan?.items.filter { ["conflict", "failed"].contains($0.action) }.count ?? 0
    }

    var isEmpty: Bool { plan != nil && plan?.items.isEmpty == true }
}

struct SyncPreview: Identifiable {
    let id = UUID()
    /// nil previews every enabled folder pair.
    let scope: UUID?
    let createdAt: Date
    let pairs: [PairPreview]

    var changeCount: Int { pairs.reduce(0) { $0 + $1.changeCount } }
    var hasErrors: Bool { pairs.contains { $0.error != nil } }
}

private let planPrefix = "PLAN_JSON\t"

func parseSyncPlan(_ output: String) -> SyncPlan? {
    for line in output.split(separator: "\n") where line.hasPrefix(planPrefix) {
        return try? JSONDecoder().decode(SyncPlan.self, from: Data(line.dropFirst(planPrefix.count).utf8))
    }
    return nil
}

/// The plan line is for the app; the log and history keep the readable lines.
func strippingSyncPlan(_ output: String) -> String {
    guard output.contains(planPrefix) else { return output }
    return output.components(separatedBy: "\n").filter { !$0.hasPrefix(planPrefix) }.joined(separator: "\n")
}
