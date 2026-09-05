import AppKit
import CryptoKit
import Foundation

enum AutomaticUpdateResult {
    case upToDate
    case installationStarted(version: String)
}

enum AutomaticUpdateError: LocalizedError {
    case invalidResponse
    case releaseMetadata(String)
    case missingArchive(String)
    case untrustedDownload
    case missingDigest
    case sizeMismatch
    case checksumMismatch
    case extractionFailed(String)
    case invalidApplication(String)
    case unwritableInstallation
    case installerFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "GitHub returned an invalid update response."
        case .releaseMetadata(let detail):
            return "Invalid GitHub release metadata: \(detail)"
        case .missingArchive(let name):
            return "The release does not contain \(name)."
        case .untrustedDownload:
            return "The update archive is not hosted by the expected GitHub repository."
        case .missingDigest:
            return "GitHub did not provide a SHA-256 digest for the update."
        case .sizeMismatch:
            return "The downloaded update has an unexpected size."
        case .checksumMismatch:
            return "The downloaded update failed SHA-256 verification."
        case .extractionFailed(let detail):
            return "Could not extract the update: \(detail)"
        case .invalidApplication(let detail):
            return "The downloaded application is invalid: \(detail)"
        case .unwritableInstallation:
            return "Yabai Menu cannot replace the current application. Move it to /Applications and make sure you can write to that folder."
        case .installerFailed(let detail):
            return "Could not start the updater: \(detail)"
        }
    }
}

final class AutomaticUpdateController {
    private struct Release: Decodable {
        let tagName: String
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    private struct Asset: Decodable {
        let name: String
        let downloadURL: URL
        let size: Int
        let digest: String?

        enum CodingKeys: String, CodingKey {
            case name
            case downloadURL = "browser_download_url"
            case size
            case digest
        }
    }

    private let session: URLSession
    private let fileManager: FileManager
    private let releaseURL = URL(string: "https://api.github.com/repos/MarosZofcin/yabai-menu/releases/latest")!
    private let expectedBundleIdentifier = "sk.maroszofcin.YabaiMenu"

    init(session: URLSession = .shared, fileManager: FileManager = .default) {
        self.session = session
        self.fileManager = fileManager
    }

    func checkAndInstall(
        completion: @escaping (Result<AutomaticUpdateResult, Error>) -> Void
    ) {
        var request = URLRequest(url: releaseURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Yabai-Menu-Updater", forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let data else {
                completion(.failure(AutomaticUpdateError.invalidResponse))
                return
            }

            do {
                let release = try JSONDecoder().decode(Release.self, from: data)
                let version = Self.normalizedVersion(release.tagName)
                guard !version.isEmpty else {
                    throw AutomaticUpdateError.releaseMetadata("empty version")
                }
                let currentVersion = Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String ?? "0"

                guard Self.isVersion(version, newerThan: currentVersion) else {
                    completion(.success(.upToDate))
                    return
                }

                let archiveName = "Yabai-Menu-\(version).zip"
                guard let asset = release.assets.first(where: { $0.name == archiveName }) else {
                    throw AutomaticUpdateError.missingArchive(archiveName)
                }
                try self.validateDownloadURL(asset.downloadURL, version: version, archiveName: archiveName)
                try self.downloadAndInstall(asset: asset, version: version, completion: completion)
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    static func normalizedVersion(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        candidate.compare(current, options: [.numeric, .caseInsensitive]) == .orderedDescending
    }

    private func validateDownloadURL(_ url: URL, version: String, archiveName: String) throws {
        let expectedPath = "/MarosZofcin/yabai-menu/releases/download/v\(version)/\(archiveName)"
        guard url.scheme == "https",
              url.host?.lowercased() == "github.com",
              url.path == expectedPath else {
            throw AutomaticUpdateError.untrustedDownload
        }
    }

    private func downloadAndInstall(
        asset: Asset,
        version: String,
        completion: @escaping (Result<AutomaticUpdateResult, Error>) -> Void
    ) throws {
        guard let digest = asset.digest,
              digest.lowercased().hasPrefix("sha256:") else {
            throw AutomaticUpdateError.missingDigest
        }
        let expectedDigest = String(digest.dropFirst("sha256:".count)).lowercased()

        var request = URLRequest(url: asset.downloadURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 120
        request.setValue("Yabai-Menu-Updater", forHTTPHeaderField: "User-Agent")

        session.downloadTask(with: request) { [weak self] temporaryURL, response, error in
            guard let self else { return }
            if let error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let temporaryURL else {
                completion(.failure(AutomaticUpdateError.invalidResponse))
                return
            }

            var updateRoot: URL?
            do {
                let root = self.fileManager.temporaryDirectory
                    .appendingPathComponent("YabaiMenuUpdate-\(UUID().uuidString)", isDirectory: true)
                updateRoot = root
                try self.fileManager.createDirectory(at: root, withIntermediateDirectories: true)

                let archiveURL = root.appendingPathComponent("update.zip")
                try self.fileManager.copyItem(at: temporaryURL, to: archiveURL)
                let attributes = try self.fileManager.attributesOfItem(atPath: archiveURL.path)
                let downloadedSize = (attributes[.size] as? NSNumber)?.intValue
                guard downloadedSize == asset.size else {
                    throw AutomaticUpdateError.sizeMismatch
                }

                let archiveData = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
                let actualDigest = SHA256.hash(data: archiveData)
                    .map { String(format: "%02x", $0) }
                    .joined()
                guard actualDigest == expectedDigest else {
                    throw AutomaticUpdateError.checksumMismatch
                }

                let extractResult = ProcessRunner.run(
                    URL(fileURLWithPath: "/usr/bin/ditto"),
                    arguments: ["-x", "-k", archiveURL.path, root.path]
                )
                guard extractResult.succeeded else {
                    throw AutomaticUpdateError.extractionFailed(extractResult.usefulError)
                }

                let replacementURL = root.appendingPathComponent("Yabai Menu.app", isDirectory: true)
                try self.validateApplication(at: replacementURL, expectedVersion: version)
                try self.startInstaller(replacementURL: replacementURL, updateRoot: root)
                completion(.success(.installationStarted(version: version)))
            } catch {
                if let updateRoot {
                    try? self.fileManager.removeItem(at: updateRoot)
                }
                completion(.failure(error))
            }
        }.resume()
    }

    private func validateApplication(at appURL: URL, expectedVersion: String) throws {
        guard let bundle = Bundle(url: appURL),
              bundle.bundleIdentifier == expectedBundleIdentifier else {
            throw AutomaticUpdateError.invalidApplication("unexpected bundle identifier")
        }
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard version == expectedVersion else {
            throw AutomaticUpdateError.invalidApplication("unexpected version")
        }

        let executableURL = appURL.appendingPathComponent("Contents/MacOS/YabaiMenu")
        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw AutomaticUpdateError.invalidApplication("main executable is missing")
        }

        let signature = ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--verify", "--deep", "--strict", appURL.path]
        )
        guard signature.succeeded else {
            throw AutomaticUpdateError.invalidApplication(signature.usefulError)
        }

        let selfTest = ProcessRunner.run(executableURL, arguments: ["--self-test"])
        guard selfTest.succeeded else {
            throw AutomaticUpdateError.invalidApplication("self-test failed: \(selfTest.usefulError)")
        }
    }

    private func startInstaller(replacementURL: URL, updateRoot: URL) throws {
        let currentURL = Bundle.main.bundleURL.standardizedFileURL
        let parentURL = currentURL.deletingLastPathComponent()
        guard currentURL.pathExtension == "app",
              Bundle.main.bundleIdentifier == expectedBundleIdentifier,
              fileManager.isWritableFile(atPath: parentURL.path) else {
            throw AutomaticUpdateError.unwritableInstallation
        }

        let helperURL = updateRoot.appendingPathComponent("install-update.sh")
        let script = """
        #!/bin/sh
        set -u

        current="$1"
        replacement="$2"
        application_pid="$3"
        update_root="$4"
        expected_identifier="$5"
        backup="$(dirname "$current")/.Yabai-Menu-update-backup-$$"

        while /bin/kill -0 "$application_pid" 2>/dev/null; do
            /bin/sleep 0.2
        done

        if ! /bin/mv "$current" "$backup"; then
            /usr/bin/open "$current" >/dev/null 2>&1 || true
            /bin/rm -rf "$update_root"
            exit 1
        fi

        installed=false
        if /usr/bin/ditto "$replacement" "$current" &&
           /usr/bin/codesign --verify --deep --strict "$current" >/dev/null 2>&1 &&
           [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$current/Contents/Info.plist" 2>/dev/null)" = "$expected_identifier" ]; then
            installed=true
        fi

        if [ "$installed" = true ]; then
            /bin/rm -rf "$backup"
            /usr/bin/open "$current" >/dev/null 2>&1 || true
            /bin/rm -rf "$update_root"
            exit 0
        fi

        /bin/rm -rf "$current"
        /bin/mv "$backup" "$current"
        /usr/bin/open "$current" >/dev/null 2>&1 || true
        /bin/rm -rf "$update_root"
        exit 1
        """
        try script.write(to: helperURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helperURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            helperURL.path,
            currentURL.path,
            replacementURL.path,
            String(ProcessInfo.processInfo.processIdentifier),
            updateRoot.path,
            expectedBundleIdentifier
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw AutomaticUpdateError.installerFailed(error.localizedDescription)
        }
    }
}
