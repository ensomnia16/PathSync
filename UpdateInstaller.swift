import AppKit
import CryptoKit
import Foundation

private let updatePublicKey = "sYnxDTG6wFBywW7SOt/ffX/BR1rmcAA/0W60BMd/K7o="
private let updateDomain = "com.ensom.ResearchSync.update-install"

enum UpdateInstallPhase: Equatable {
    case idle, downloading, verifying, replacing
    case failed(String)
}

private func updateError(_ message: String) -> NSError {
    NSError(domain: updateDomain, code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

func verifyUpdateArchive(_ archive: URL, signatureText: Data) throws {
    let values = try archive.resourceValues(forKeys: [.fileSizeKey])
    guard let size = values.fileSize, size > 0, size <= 100_000_000,
          let text = String(data: signatureText, encoding: .utf8),
          let signature = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let publicData = Data(base64Encoded: updatePublicKey) else {
        throw updateError("安装包或签名格式无效。")
    }
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicData)
    let contents = try Data(contentsOf: archive, options: .mappedIfSafe)
    guard publicKey.isValidSignature(signature, for: contents) else {
        throw updateError("安装包签名校验失败，未安装更新。")
    }
}

private func runUpdateTool(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw updateError("更新包验证或解压失败（\(process.terminationStatus)）。")
    }
}

func prepareUpdate(_ release: AppRelease, installedBundle: URL,
                   status: @escaping (UpdateInstallPhase) -> Void,
                   completion: @escaping (Result<(helper: URL, staged: URL), Error>) -> Void) {
    guard let archiveURL = release.downloadURL, let signatureURL = release.signatureURL else {
        completion(.failure(updateError("该版本没有签名安装包，请打开发布页面下载。")))
        return
    }
    let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ResearchSync/update-stage/" + UUID().uuidString,
                                isDirectory: true)
    let request = URLRequest(url: archiveURL, cachePolicy: .reloadIgnoringLocalCacheData,
                             timeoutInterval: 120)
    URLSession.shared.downloadTask(with: request) { temporaryURL, response, error in
        guard error == nil, let temporaryURL,
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            completion(.failure(error ?? updateError("无法下载安装包。")))
            return
        }
        let archive = root.appendingPathComponent("update.zip")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: temporaryURL, to: archive)
        } catch {
            completion(.failure(error))
            return
        }
        var signatureRequest = URLRequest(url: signatureURL,
                                          cachePolicy: .reloadIgnoringLocalCacheData,
                                          timeoutInterval: 30)
        signatureRequest.setValue("PathSync", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: signatureRequest) { signature, response, error in
            guard error == nil, let signature, signature.count < 1_024,
                  (response as? HTTPURLResponse)?.statusCode == 200 else {
                completion(.failure(error ?? updateError("无法下载更新签名。")))
                return
            }
            status(.verifying)
            do {
                let fm = FileManager.default
                try verifyUpdateArchive(archive, signatureText: signature)
                let unpacked = root.appendingPathComponent("unpacked", isDirectory: true)
                try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
                try runUpdateTool("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
                let staged = unpacked.appendingPathComponent("路径同步.app", isDirectory: true)
                guard let bundle = Bundle(url: staged),
                      bundle.bundleIdentifier == "com.ensom.ResearchSync",
                      bundle.infoDictionary?["CFBundleShortVersionString"] as? String == release.version,
                      let executable = bundle.executableURL,
                      fm.isWritableFile(atPath: installedBundle.deletingLastPathComponent().path),
                      let packagedHelper = Bundle.main.resourceURL?
                        .appendingPathComponent("UpdateApply") else {
                    throw updateError("安装包应用信息不匹配，或当前应用目录不可写。")
                }
                try runUpdateTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path])
                try runUpdateTool("/usr/bin/lipo", ["-verify_arch", currentArchitecture(), executable.path])
                let helper = root.appendingPathComponent("UpdateApply")
                try fm.copyItem(at: packagedHelper, to: helper)
                completion(.success((helper: helper, staged: staged)))
            } catch {
                try? FileManager.default.removeItem(at: root)
                completion(.failure(error))
            }
        }.resume()
    }.resume()
}
