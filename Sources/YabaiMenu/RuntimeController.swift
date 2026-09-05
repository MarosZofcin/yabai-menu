import Foundation
import JavaScriptCore

struct RuntimePackage: Codable {
    struct MenuEntry: Codable {
        let title: String
        let action: String
        let section: String
    }
    let api: Int
    let version: String
    let settings: [String: Double]
    let menu: [MenuEntry]
    let script: String
}

// This class is the host/runtime boundary. Runtime code receives only JSON;
// no Foundation/ObjC objects or executable-launching callbacks are exported.
final class RuntimeController: @unchecked Sendable {
    static let shared = RuntimeController()
    // API 2 adds the generic system-event/allowlisted-operation bridge. API 1
    // runtimes remain valid on this host; API 2 runtimes are rejected by old hosts.
    static let api = 2
    static let maximumBytes = 1_000_000
    private let lock = NSLock()
    private var current: RuntimePackage?
    private var previous: RuntimePackage?
    private let root: URL

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Yabai Menu/Runtime", isDirectory: true)
    }

    static func versionParts(_ value: String) -> [Int]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              parts.allSatisfy({ $0.count <= 6 }) else { return nil }
        return parts.compactMap { Int($0) }
    }

    static func newer(_ candidate: String, than current: String) -> Bool {
        guard let a = versionParts(candidate), let b = versionParts(current) else { return false }
        return b.lexicographicallyPrecedes(a)
    }

    static func decode(_ data: Data) throws -> RuntimePackage {
        guard data.count <= maximumBytes else { throw AppError.message("Runtime package is too large.") }
        let package = try JSONDecoder().decode(RuntimePackage.self, from: data)
        guard package.api >= 1, package.api <= api, versionParts(package.version) != nil,
              !package.script.isEmpty, package.menu.count <= 50 else {
            throw AppError.message("Runtime requires a different host API or contains invalid metadata.")
        }
        let allowed = Set(["testBSPHighlight", "balanceCurrentSpace", "editYabairc", "openRepository",
            "reloadYabai", "stopYabai", "startYabai", "syncNow"])
        guard package.menu.allSatisfy({ allowed.contains($0.action) &&
            ["tools", "files", "running", "stopped", "sync"].contains($0.section) && !$0.title.isEmpty && $0.title.count <= 100 }) else {
            throw AppError.message("Runtime requested an unsupported menu action.")
        }
        let limits: [String: ClosedRange<Double>] = ["statusInterval": 1...60,
            "syncInterval": 60...86400, "updateInterval": 300...86400, "wakeDelay": 5...120]
        guard package.settings.count == limits.count, limits.allSatisfy({ key, range in
            guard let value = package.settings[key] else { return false }
            return value.isFinite && range.contains(value)
        }) else { throw AppError.message("Runtime timer settings are outside host safety limits.") }
        return package
    }

    func load() throws {
        lock.lock()
        defer { lock.unlock() }
        if current != nil { return }
        // Test overrides are honored only in explicit self-test mode, never by
        // the launched application or its login service.
        if CommandLine.arguments.contains("--self-test"),
           let i = CommandLine.arguments.firstIndex(of: "--runtime-file"),
           CommandLine.arguments.indices.contains(i + 1) {
            current = try Self.decode(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[i + 1])))
            return
        }
        guard let fallback = Bundle.main.url(forResource: "bootstrap-runtime", withExtension: "json") else {
            throw AppError.message("The bootstrap runtime is missing. Reinstall the application archive.")
        }
        let bundled = try Self.decode(Data(contentsOf: fallback))
        current = bundled
        // Tests are reproducible and never load/change the user's runtime.
        if CommandLine.arguments.contains("--self-test") { return }
        previous = (try? Data(contentsOf: root.appendingPathComponent("previous.json"))).flatMap { try? Self.decode($0) } ?? bundled
        if let data = try? Data(contentsOf: root.appendingPathComponent("active.json")),
           let active = try? Self.decode(data), !Self.newer(bundled.version, than: active.version) {
            // A health check is isolated and bounded. A broken package cannot
            // prevent access to the menu and its manual recovery controls.
            if (try? Self.evaluate(package: active, method: "selfTest", input: [:])) != nil {
                current = active
            }
        }
    }

    func package() throws -> RuntimePackage {
        try load()
        lock.lock()
        defer { lock.unlock() }
        return current!
    }

    func interval(_ name: String, fallback: Double) -> Double {
        (try? package().settings[name]) ?? fallback
    }

    func call(_ method: String, input: Any) throws -> Any {
        try Self.evaluate(package: package(), method: method, input: input)
    }

    // Installation writes only these application-owned data files, never .app
    // or dotfiles. Each worker invocation pins a complete package snapshot.
    func install(_ data: Data) throws -> String {
        let candidate = try Self.decode(data)
        let old = try package()
        guard Self.newer(candidate.version, than: old.version) else { return old.version }
        _ = try Self.evaluate(package: candidate, method: "selfTest", input: [:])
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let candidateURL = staging.appendingPathComponent("candidate.json")
        try data.write(to: candidateURL, options: .atomic)
        guard let executable = Bundle.main.executableURL else { throw AppError.message("Missing host executable.") }
        // Test existing BSP fixtures and isolated Git repositories against the
        // candidate before activation. No live yabai or user files are touched.
        let check = ProcessRunner.run(executable,
            arguments: ["--self-test", "--runtime-file", candidateURL.path], timeout: 90)
        guard check.succeeded else { throw AppError.message("Runtime regression tests failed: \(check.usefulError)") }
        lock.lock()
        defer { lock.unlock() }
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(old).write(to: root.appendingPathComponent("previous.json"), options: .atomic)
        try data.write(to: root.appendingPathComponent("active.json"), options: .atomic)
        previous = old
        current = candidate
        return candidate.version
    }

    func rollback() throws {
        _ = try package()
        lock.lock()
        defer { lock.unlock() }
        guard let previous else { throw AppError.message("No previous runtime is available.") }
        try JSONEncoder().encode(previous).write(to: root.appendingPathComponent("active.json"), options: .atomic)
        current = previous
    }

    static func evaluate(package: RuntimePackage, method: String, input: Any) throws -> Any {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("YabaiRuntime-" + UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: dir) }
        let url = dir.appendingPathComponent("request.json")
        let request: [String: Any] = ["script": package.script, "method": method, "input": input]
        let data = try JSONSerialization.data(withJSONObject: request)
        guard data.count <= maximumBytes else { throw AppError.message("Runtime request exceeds size limit.") }
        try data.write(to: url, options: .atomic)
        guard let executable = Bundle.main.executableURL else { throw AppError.message("Missing host executable.") }
        let result = ProcessRunner.run(executable, arguments: ["--runtime-evaluate", url.path], timeout: 4)
        guard result.succeeded, result.standardOutput.utf8.count <= maximumBytes,
              let output = result.standardOutput.data(using: .utf8),
              let envelope = try JSONSerialization.jsonObject(with: output) as? [String: Any] else {
            throw AppError.message("Runtime worker failed or exceeded its time limit: \(result.usefulError)")
        }
        if let error = envelope["error"] as? String { throw AppError.message(error) }
        guard let value = envelope["value"] else { throw AppError.message("Runtime returned no value.") }
        return value
    }

    static func runWorker(path: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.count <= maximumBytes,
              let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let script = request["script"] as? String,
              let method = request["method"] as? String,
              let context = JSContext() else { throw AppError.message("Invalid worker request.") }
        var failure: String?
        context.exceptionHandler = { _, exception in failure = exception?.toString() ?? "JavaScript error" }
        context.evaluateScript(script)
        let value = context.objectForKeyedSubscript("dispatch")?.call(withArguments: [method, request["input"] ?? [:]])
        let envelope: [String: Any]
        if let failure { envelope = ["error": failure.replacingOccurrences(of: "Error: ", with: "")] }
        else { envelope = ["value": value?.toObject() ?? NSNull()] }
        let output = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        guard output.count <= maximumBytes else { throw AppError.message("Runtime result exceeds size limit.") }
        FileHandle.standardOutput.write(output)
    }
}
