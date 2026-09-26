import Foundation

@main
struct UpdateChecks {
    static func main() throws {
        assert(isNewerVersion("v2.13.0", than: "2.12.0"))
        assert(isNewerVersion("2.12.1", than: "2.12"))
        assert(isNewerVersion("3.0", than: "2.99.99"))
        assert(!isNewerVersion("v2.12.0", than: "2.12.0"))
        assert(!isNewerVersion("2.12", than: "2.12.0"))
        assert(!isNewerVersion("2.11.9", than: "2.12.0"))
        assert(!isNewerVersion("v2.12.0-beta", than: "2.12.0"))
        assert(!isNewerVersion("latest", than: "2.12.0"))

        let payload = """
        {"tag_name":"v2.13.0","html_url":"https://github.com/ensomnia16/PathSync/releases/tag/v2.13.0",
         "draft":false,"prerelease":false,
         "body":"## 路径同步 2.13.0\\n\\n- 加入检查更新\\n- 重新设计界面\\n\\nSHA-256: abc",
         "assets":[
           {"name":"PathSync-v2.13.0-macOS-x86_64.zip","browser_download_url":"https://github.com/ensomnia16/PathSync/releases/download/v2.13.0/PathSync-v2.13.0-macOS-x86_64.zip"},
           {"name":"PathSync-v2.13.0-macOS-arm64.zip","browser_download_url":"https://github.com/ensomnia16/PathSync/releases/download/v2.13.0/PathSync-v2.13.0-macOS-arm64.zip"}]}
        """
        let release = try parseLatestRelease(Data(payload.utf8), architecture: "arm64")
        assert(release.version == "2.13.0")
        assert(release.downloadURL?.lastPathComponent == "PathSync-v2.13.0-macOS-arm64.zip")
        assert(release.notes == ["加入检查更新", "重新设计界面"])

        let foreign = payload.replacingOccurrences(of: "https://github.com/ensomnia16/PathSync/releases/tag",
                                                   with: "https://example.com/releases/tag")
        assert((try? parseLatestRelease(Data(foreign.utf8), architecture: "arm64")) == nil)

        let prerelease = payload.replacingOccurrences(of: "\"prerelease\":false", with: "\"prerelease\":true")
        assert((try? parseLatestRelease(Data(prerelease.utf8), architecture: "arm64")) == nil)
        print("update checks passed")
    }
}
