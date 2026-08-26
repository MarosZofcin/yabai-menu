import Foundation

struct YabaiController: Sendable {
    static let managedRulePrefix = "yabai-menu-float-"

    let executableURL: URL?

    init() {
        let candidates = [
            "/opt/homebrew/bin/yabai",
            "/usr/local/bin/yabai"
        ]
        executableURL = candidates
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func snapshot() -> YabaiSnapshot {
        guard let executableURL else {
            return YabaiSnapshot(isRunning: false, displays: [])
        }

        let displaysResult = ProcessRunner.run(executableURL, arguments: ["-m", "query", "--displays"])
        guard displaysResult.succeeded,
              let displayData = displaysResult.standardOutput.data(using: .utf8),
              let displayJSON = try? JSONSerialization.jsonObject(with: displayData) as? [[String: Any]] else {
            return YabaiSnapshot(isRunning: false, displays: [])
        }

        let spacesResult = ProcessRunner.run(executableURL, arguments: ["-m", "query", "--spaces"])
        let spaces: [[String: Any]]
        if spacesResult.succeeded,
           let spaceData = spacesResult.standardOutput.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: spaceData) as? [[String: Any]] {
            spaces = decoded
        } else {
            spaces = []
        }

        let displays = displayJSON.compactMap { display -> DisplayState? in
            guard let index = display["index"] as? Int else { return nil }
            let label = (display["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (label?.isEmpty == false) ? label! : "Display \(index)"
            let displaySpaces = spaces.filter { ($0["display"] as? Int) == index }
            let focused = displaySpaces.first { ($0["has-focus"] as? Bool) == true }
            let layouts = Set(displaySpaces.compactMap { $0["type"] as? String })
            let layout: String
            if let focusedLayout = focused?["type"] as? String {
                layout = focusedLayout.uppercased()
            } else if layouts.count == 1, let only = layouts.first {
                layout = only.uppercased()
            } else if layouts.count > 1 {
                layout = "MIXED"
            } else {
                layout = "UNKNOWN"
            }
            return DisplayState(index: index, name: name, layout: layout)
        }.sorted { $0.index < $1.index }

        return YabaiSnapshot(isRunning: true, displays: displays)
    }

    func start() throws {
        try requireSuccess(["--start-service"], action: "start yabai")
    }

    func stop() throws {
        try requireSuccess(["--stop-service"], action: "stop yabai")
    }

    func reload() throws {
        try requireSuccess(["--restart-service"], action: "reload yabai")
    }

    func applyBlacklist(_ apps: [FloatingApp], additionalLabelsToRemove: [String] = []) throws {
        guard snapshot().isRunning else {
            throw AppError.message("yabai is not running. Start it before applying floating apps.")
        }

        let labelsToRemove = Set(managedRuleLabels() + additionalLabelsToRemove)
        for label in labelsToRemove {
            _ = run(["-m", "rule", "--remove", label])
        }

        for app in apps {
            try requireSuccess(
                ["-m", "rule", "--add", "label=\(app.ruleLabel)", "app=\(app.appPattern)", "manage=off"],
                action: "add floating rule for \(app.name)"
            )
        }
        try requireSuccess(["-m", "rule", "--apply"], action: "apply floating rules")
    }

    func applyBlacklistWhenReady(_ apps: [FloatingApp]) throws {
        for attempt in 0..<12 {
            if snapshot().isRunning {
                try applyBlacklist(apps)
                return
            }
            if attempt < 11 {
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        throw AppError.message("yabai started, but its socket did not become ready in time.")
    }

    func tileOpenWindows(for app: FloatingApp) {
        let result = run(["-m", "query", "--windows"])
        guard result.succeeded,
              let data = result.standardOutput.data(using: .utf8),
              let windows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

        for window in windows {
            guard let name = window["app"] as? String,
                  name.caseInsensitiveCompare(app.name) == .orderedSame,
                  (window["is-floating"] as? Bool) == true,
                  let id = window["id"] as? Int else { continue }
            _ = run(["-m", "window", String(id), "--toggle", "float"])
        }
    }

    func bspBranchesAtMouse() throws -> BSPBranchSelection {
        guard let executableURL else {
            throw AppError.message("yabai was not found in /opt/homebrew/bin or /usr/local/bin.")
        }

        let targetResult = ProcessRunner.run(
            executableURL,
            arguments: ["-m", "query", "--windows", "--window", "mouse"]
        )
        guard targetResult.succeeded else {
            throw AppError.message("Could not identify the window below the pointer: \(targetResult.usefulError)")
        }
        let decoder = JSONDecoder()
        guard let targetData = targetResult.standardOutput.data(using: .utf8),
              let target = try? decoder.decode(BSPWindowSnapshot.self, from: targetData) else {
            throw AppError.message("Could not decode yabai's window information.")
        }
        guard !target.isFloating, !target.isMinimized, !target.isHidden else {
            throw BSPTreeError.targetNotTiled
        }

        let spaceResult = ProcessRunner.run(
            executableURL,
            arguments: ["-m", "query", "--spaces", "--space", String(target.space)]
        )
        guard spaceResult.succeeded,
              let spaceData = spaceResult.standardOutput.data(using: .utf8),
              let space = try? decoder.decode(BSPSpaceSnapshot.self, from: spaceData),
              space.type == "bsp" else {
            throw AppError.message("The clicked window is not on a BSP space.")
        }

        let displayResult = ProcessRunner.run(
            executableURL,
            arguments: ["-m", "query", "--displays", "--display", String(target.display)]
        )
        guard displayResult.succeeded,
              let displayData = displayResult.standardOutput.data(using: .utf8),
              let display = try? decoder.decode(BSPDisplaySnapshot.self, from: displayData) else {
            throw AppError.message("Could not identify the display containing the clicked window.")
        }
        guard display.index == target.display else {
            throw BSPTreeError.hierarchyCouldNotBeResolved
        }

        let windowsResult = ProcessRunner.run(
            executableURL,
            arguments: ["-m", "query", "--windows", "--space", String(target.space)]
        )
        guard windowsResult.succeeded else {
            throw AppError.message("Could not query the current BSP space: \(windowsResult.usefulError)")
        }
        guard let windowsData = windowsResult.standardOutput.data(using: .utf8),
              let windows = try? decoder.decode([BSPWindowSnapshot].self, from: windowsData) else {
            throw AppError.message("Could not decode yabai's BSP window list.")
        }
        guard let currentTarget = windows.first(where: { $0.id == target.id }),
              currentTarget.space == target.space,
              currentTarget.display == target.display else {
            // The clicked window changed Spaces or displays during the three
            // queries above. Do not draw an overlay using stale coordinates.
            throw BSPTreeError.hierarchyCouldNotBeResolved
        }

        let branches = try BSPTreeResolver().branches(for: target.id, in: windows)
        return BSPBranchSelection(
            windowID: target.id,
            space: target.space,
            display: display,
            branches: branches
        )
    }

    static func stableIdentifier(name: String, bundleIdentifier: String?) -> String {
        let value = bundleIdentifier ?? name.lowercased()
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    private func managedRuleLabels() -> [String] {
        let result = run(["-m", "query", "--rules"])
        guard result.succeeded,
              let data = result.standardOutput.data(using: .utf8),
              let rules = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rules.compactMap { $0["label"] as? String }
            .filter { $0.hasPrefix(Self.managedRulePrefix) }
    }

    private func run(_ arguments: [String]) -> CommandResult {
        guard let executableURL else {
            return CommandResult(status: -1, standardOutput: "", standardError: "yabai was not found in /opt/homebrew/bin or /usr/local/bin.")
        }
        return ProcessRunner.run(executableURL, arguments: arguments)
    }

    private func requireSuccess(_ arguments: [String], action: String) throws {
        let result = run(arguments)
        guard result.succeeded else {
            throw AppError.message("Could not \(action): \(result.usefulError)")
        }
    }
}

private struct BSPSpaceSnapshot: Decodable {
    let type: String
}
