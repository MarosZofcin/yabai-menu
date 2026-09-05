import CryptoKit
import Foundation

enum AutomaticUpdateResult {
    case upToDate
    case runtimeInstalled(version: String)
}

final class AutomaticUpdateController {
    private struct Release: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }
    private struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
        let size: Int
        let digest: String?
    }

    // No updater path writes to the installed .app. Publisher trust is the
    // fixed GitHub repository over HTTPS, not an Apple signing identity.
    func checkAndInstall(completion: @escaping (Result<AutomaticUpdateResult, Error>) -> Void) {
        let url = URL(string: "https://api.github.com/repos/MarosZofcin/yabai-menu/releases?per_page=100")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Yabai-Menu-Runtime/1", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            do {
                if let error { throw error }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data, data.count < 4_000_000 else { throw AppError.message("Could not read GitHub releases.") }
                let releases = try JSONDecoder().decode([Release].self, from: data)
                let current = try RuntimeController.shared.package()
                let candidates: [(String, Asset)] = releases.filter { !$0.draft && !$0.prerelease }.compactMap { release in
                    let version: String
                    if release.tag_name.hasPrefix("runtime-v") { version = String(release.tag_name.dropFirst(9)) }
                    else if release.tag_name.hasPrefix("v") { version = String(release.tag_name.dropFirst()) }
                    else { return nil }
                    guard RuntimeController.versionParts(version) != nil,
                          RuntimeController.newer(version, than: current.version),
                          let asset = release.assets.first(where: { $0.name == "Yabai-Menu-Runtime-\(version).json" }),
                          Self.trustedURL(asset.browser_download_url, tag: release.tag_name, filename: asset.name)
                    else { return nil }
                    return (version, asset)
                }
                guard let (version, asset) = candidates.sorted(by: {
                    RuntimeController.newer($0.0, than: $1.0)
                }).first else { completion(.success(.upToDate)); return }
                guard asset.size > 0, asset.size <= RuntimeController.maximumBytes,
                      let digest = asset.digest,
                      digest.range(of: "^sha256:[a-fA-F0-9]{64}$", options: .regularExpression) != nil else {
                    throw AppError.message("The runtime asset has no valid GitHub SHA-256 digest or size.")
                }
                var download = URLRequest(url: asset.browser_download_url)
                download.timeoutInterval = 60
                download.cachePolicy = .reloadIgnoringLocalCacheData
                URLSession.shared.downloadTask(with: download) { file, response, error in
                    do {
                        if let error { throw error }
                        guard let http = response as? HTTPURLResponse, http.statusCode == 200, let file else {
                            throw AppError.message("Runtime download failed.")
                        }
                        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
                        guard size?.intValue == asset.size else { throw AppError.message("Runtime size mismatch.") }
                        let payload = try Data(contentsOf: file)
                        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
                        guard "sha256:" + hash == digest.lowercased() else { throw AppError.message("Runtime checksum mismatch.") }
                        let package = try RuntimeController.decode(payload)
                        guard package.version == version else { throw AppError.message("Runtime version mismatch.") }
                        let installed = try RuntimeController.shared.install(payload)
                        completion(.success(.runtimeInstalled(version: installed)))
                    } catch { completion(.failure(error)) }
                }.resume()
            } catch { completion(.failure(error)) }
        }.resume()
    }

    static func trustedURL(_ url: URL, tag: String, filename: String) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.user == nil && url.password == nil &&
        url.port == nil && url.query == nil && url.fragment == nil &&
        url.path == "/MarosZofcin/yabai-menu/releases/download/\(tag)/\(filename)"
    }
}
