import AppKit
import Foundation

/// What a pathsync:// link asks for. Shortcuts' "Open URL" action uses these:
///   pathsync://sync              sync every enabled folder pair
///   pathsync://sync?pair=<id>    sync one pair, by UUID or exact name
///   pathsync://open              open the main window
enum PathSyncURLAction: Equatable {
    case syncAll
    case syncPair(String)
    case open

    init?(_ url: URL) {
        guard url.scheme?.lowercased() == "pathsync" else { return nil }
        let command = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        let pair = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "pair" }?.value?
            .trimmingCharacters(in: .whitespaces)
        switch command {
        case "sync":
            if let pair, !pair.isEmpty { self = .syncPair(pair) } else { self = .syncAll }
        case "open":
            self = .open
        default:
            return nil
        }
    }
}

/// A pair named by its UUID, or else by its exact name when that name is unique.
func pairMatching(_ reference: String, in pairs: [SyncPair]) -> SyncPair? {
    if let id = UUID(uuidString: reference), let pair = pairs.first(where: { $0.id == id }) { return pair }
    let named = pairs.filter { $0.name == reference }
    return named.count == 1 ? named[0] : nil
}

/// Routes pathsync:// links to the running app's model.
enum URLCommandRouter {
    static weak var model: SyncModel?

    static func handle(_ url: URL) {
        guard let action = PathSyncURLAction(url), let model else { return }
        switch action {
        case .syncAll:
            model.syncNow(all: true)
        case .syncPair(let reference):
            guard let pair = pairMatching(reference, in: model.config.pairs) else {
                model.statusKey = "error"
                model.statusDetail = String(format: uiText("urlPairNotFound", language: model.config.language), reference)
                return
            }
            model.syncNow(pairID: pair.id)
        case .open:
            model.page = "overview"
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        }
    }
}

final class PathSyncAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(URLCommandRouter.handle)
    }
}
