import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct AppRelease: Equatable {
    let version: String
    let pageURL: URL
    let downloadURL: URL?
    let notes: [String]
}

enum UpdateStatus: Equatable {
    case idle, checking, upToDate, failed
    case available(AppRelease)
}

private let latestReleaseAPI = URL(string: "https://api.github.com/repos/ensomnia16/PathSync/releases/latest")!

func versionComponents(_ text: String) -> [Int] {
    var value = text.trimmingCharacters(in: .whitespaces)
    if value.hasPrefix("v") || value.hasPrefix("V") { value.removeFirst() }
    let core = value.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? ""
    return core.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
}

func isNewerVersion(_ candidate: String, than current: String) -> Bool {
    let new = versionComponents(candidate), old = versionComponents(current)
    guard !new.isEmpty else { return false }
    for index in 0..<max(new.count, old.count) {
        let lhs = index < new.count ? new[index] : 0
        let rhs = index < old.count ? old[index] : 0
        if lhs != rhs { return lhs > rhs }
    }
    return false
}

private func isGitHubURL(_ url: URL) -> Bool {
    guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
    return host == "github.com" || host.hasSuffix(".github.com")
}

private struct ReleasePayload: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
    }
    let tag_name: String
    let html_url: URL
    let body: String?
    let draft: Bool?
    let prerelease: Bool?
    let assets: [Asset]
}

func parseLatestRelease(_ data: Data, architecture: String) throws -> AppRelease {
    let payload = try JSONDecoder().decode(ReleasePayload.self, from: data)
    guard payload.draft != true, payload.prerelease != true, isGitHubURL(payload.html_url),
          !versionComponents(payload.tag_name).isEmpty else {
        throw NSError(domain: "com.ensom.ResearchSync.update", code: 2)
    }
    let archives = payload.assets.filter {
        $0.name.lowercased().hasSuffix(".zip") && $0.name.lowercased().contains("macos")
            && isGitHubURL($0.browser_download_url)
    }
    let asset = archives.first { $0.name.lowercased().contains(architecture.lowercased()) }
        ?? (archives.count == 1 ? archives.first : nil)
    let notes = (payload.body ?? "").components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { $0.hasPrefix("- ") }
        .map { String($0.dropFirst(2)) }
    var version = payload.tag_name
    if version.hasPrefix("v") || version.hasPrefix("V") { version.removeFirst() }
    return AppRelease(version: version, pageURL: payload.html_url,
                      downloadURL: asset?.browser_download_url, notes: Array(notes.prefix(8)))
}

func currentArchitecture() -> String {
    #if arch(arm64)
    return "arm64"
    #else
    return "x86_64"
    #endif
}

func fetchLatestRelease(completion: @escaping (Result<AppRelease, Error>) -> Void) {
    var request = URLRequest(url: latestReleaseAPI, cachePolicy: .reloadIgnoringLocalCacheData,
                             timeoutInterval: 20)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("PathSync", forHTTPHeaderField: "User-Agent")
    URLSession.shared.dataTask(with: request) { data, response, error in
        if let error { completion(.failure(error)); return }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200, let data else {
            completion(.failure(NSError(domain: "com.ensom.ResearchSync.update", code: status)))
            return
        }
        completion(Result { try parseLatestRelease(data, architecture: currentArchitecture()) })
    }.resume()
}
