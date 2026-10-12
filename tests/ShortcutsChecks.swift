import Foundation

@main
struct ShortcutsChecks {
    static func main() throws {
        func action(_ text: String) -> PathSyncURLAction? { PathSyncURLAction(URL(string: text)!) }
        assert(action("pathsync://sync") == .syncAll)
        assert(action("PathSync://SYNC/") == .syncAll)
        assert(action("pathsync://sync?pair=") == .syncAll)
        assert(action("pathsync://sync?pair=%E7%A0%94%E4%B8%89") == .syncPair("研三"))
        assert(action("pathsync://open") == .open)
        assert(action("pathsync://delete") == nil)
        assert(action("https://sync?pair=x") == nil)

        let first = SyncPair(name: "研三", localPath: "/a", cloudPath: "/b")
        let second = SyncPair(name: "论文", localPath: "/c", cloudPath: "/d")
        let duplicate = SyncPair(name: "论文", localPath: "/e", cloudPath: "/f")
        assert(pairMatching(first.id.uuidString, in: [first, second])?.id == first.id)
        assert(pairMatching(first.id.uuidString.lowercased(), in: [first, second])?.id == first.id)
        assert(pairMatching("研三", in: [first, second])?.id == first.id)
        assert(pairMatching("论文", in: [first, second, duplicate]) == nil, "an ambiguous name syncs nothing")
        assert(pairMatching("不存在", in: [first]) == nil)
        print("shortcuts checks passed")
    }
}
