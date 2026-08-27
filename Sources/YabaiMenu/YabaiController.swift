import ApplicationServices
import Foundation

struct BSPWarpUndoRecord: Sendable {
    let sourceWindowID: Int
    let originalTargetWindowID: Int
    let originalDirection: BSPWarpDirection
    let space: Int
    let expectedClosestParentWindowIDs: Set<Int>
}

struct YabaiController: Sendable {
    static let managedRulePrefix = "yabai-menu-float-"

    let executableURL: URL?
    private let diagnostics: DiagnosticLogger?

    init(diagnostics: DiagnosticLogger? = nil) {
        self.diagnostics = diagnostics
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
        guard executableURL != nil else {
            throw AppError.message("yabai was not found in /opt/homebrew/bin or /usr/local/bin.")
        }

        let targetResult = run(["-m", "query", "--windows", "--window", "mouse"])
        guard targetResult.succeeded else {
            throw AppError.message("Could not identify the window below the pointer: \(targetResult.usefulError)")
        }
        let decoder = JSONDecoder()
        guard let targetData = targetResult.standardOutput.data(using: .utf8),
              let target = try? decoder.decode(BSPWindowSnapshot.self, from: targetData) else {
            throw AppError.message("Could not decode yabai's window information.")
        }
        guard target.hasAXReference,
              target.isVisible,
              !target.isFloating,
              !target.isMinimized,
              !target.isHidden else {
            throw BSPTreeError.targetNotTiled
        }

        let spaceResult = run(["-m", "query", "--spaces", "--space", String(target.space)])
        guard spaceResult.succeeded,
              let spaceData = spaceResult.standardOutput.data(using: .utf8),
              let space = try? decoder.decode(BSPSpaceSnapshot.self, from: spaceData),
              space.type == "bsp" else {
            throw AppError.message("The clicked window is not on a BSP space.")
        }

        let displayResult = run(["-m", "query", "--displays", "--display", String(target.display)])
        guard displayResult.succeeded,
              let displayData = displayResult.standardOutput.data(using: .utf8),
              let display = try? decoder.decode(BSPDisplaySnapshot.self, from: displayData) else {
            throw AppError.message("Could not identify the display containing the clicked window.")
        }
        guard display.index == target.display else {
            throw BSPTreeError.hierarchyCouldNotBeResolved
        }

        let windowsResult = run(["-m", "query", "--windows", "--space", String(target.space)])
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

        diagnostics?.log("bsp_resolution_input", [
            "target_window_id": target.id,
            "space": target.space,
            "display": target.display,
            "window_count": windows.count,
            "windows": windows.map(Self.diagnosticWindow)
        ])
        let branches: [BSPBranch]
        do {
            branches = try BSPTreeResolver().branches(for: target.id, in: windows)
        } catch {
            diagnostics?.log("bsp_resolution_failed", [
                "target_window_id": target.id,
                "error": error.localizedDescription
            ])
            throw error
        }
        diagnostics?.log("bsp_resolution_succeeded", [
            "target_window_id": target.id,
            "branches": branches.map { [
                "window_ids": $0.windowIDs.sorted(),
                "frame": Self.diagnosticFrame($0.frame)
            ] }
        ])
        return BSPBranchSelection(
            windowID: target.id,
            window: currentTarget,
            space: target.space,
            display: display,
            branches: branches
        )
    }

    func tiledWindowAtMouse() throws -> BSPWindowSnapshot {
        let result = run(["-m", "query", "--windows", "--window", "mouse"])
        guard result.succeeded else {
            throw AppError.message("Could not identify the tiled window below the pointer: \(result.usefulError)")
        }
        guard let data = result.standardOutput.data(using: .utf8),
              let window = try? JSONDecoder().decode(BSPWindowSnapshot.self, from: data),
              window.hasAXReference,
              window.isVisible,
              !window.isFloating,
              !window.isMinimized,
              !window.isHidden else {
            throw BSPTreeError.targetNotTiled
        }
        return window
    }

    func warp(
        source: BSPBranchSelection,
        target: BSPWindowSnapshot,
        direction: BSPWarpDirection
    ) throws -> BSPWarpUndoRecord? {
        guard source.windowID != target.id,
              source.space == target.space,
              source.window.display == target.display else {
            throw AppError.message("Source and target must be different tiled windows on the same Space and display.")
        }
        guard source.window.stackIndex == 0, target.stackIndex == 0 else {
            throw AppError.message("Drag-and-warp currently requires ordinary BSP leaves, not stacked windows.")
        }
        guard let closestParent = source.branches.first else {
            throw AppError.message("The source window no longer has a BSP parent.")
        }
        let originalSiblingWindowIDs = closestParent.windowIDs.subtracting([source.windowID])
        let originalTargetID = originalSiblingWindowIDs.count == 1 ? originalSiblingWindowIDs.first : nil
        let originalDirection = Self.originalDirection(for: source.window)
        diagnostics?.log("warp_requested", [
            "source_window_id": source.windowID,
            "target_window_id": target.id,
            "direction": direction.rawValue,
            "original_undo_target": originalTargetID as Any,
            "original_closest_parent_window_ids": closestParent.windowIDs,
            "exact_undo_available": originalTargetID != nil,
            "original_direction": originalDirection.rawValue,
            "space": source.space,
            "source_window": Self.diagnosticWindow(source.window),
            "target_window": Self.diagnosticWindow(target),
            "source_branch_path": source.branches.map { $0.windowIDs.sorted() }
        ])

        try requireSuccess(
            ["-m", "window", String(target.id), "--insert", direction.rawValue],
            action: "set the BSP insertion direction"
        )
        try requireSuccess(
            ["-m", "window", String(source.windowID), "--warp", String(target.id)],
            action: "warp the window"
        )
        Thread.sleep(forTimeInterval: 0.15)
        let post = try windows(onSpace: source.space)
        guard let moved = post.first(where: { $0.id == source.windowID }),
              moved.space == source.space,
              moved.display == source.window.display else {
            diagnostics?.log("warp_verification_failed", ["source_window_id": source.windowID])
            throw AppError.message("yabai accepted the warp, but the moved window could not be verified afterwards.")
        }
        let postBranches = try BSPTreeResolver().branches(for: source.windowID, in: post)
        let expectedNewParent = Set([source.windowID, target.id])
        guard postBranches.first?.windowIDs == expectedNewParent else {
            diagnostics?.log("warp_verification_failed", [
                "reason": "unexpected_closest_parent",
                "expected_window_ids": expectedNewParent,
                "actual_branch_path": postBranches.map { $0.windowIDs.sorted() },
                "post_windows": post.map(Self.diagnosticWindow)
            ])
            throw AppError.message("yabai moved the window, but the resulting BSP relationship did not match the selected drop target.")
        }
        diagnostics?.log("warp_verified", [
            "source_window_id": source.windowID,
            "post_window": Self.diagnosticWindow(moved),
            "post_branch_path": postBranches.map { $0.windowIDs.sorted() },
            "post_windows": post.map(Self.diagnosticWindow)
        ])
        guard let originalTargetID else {
            diagnostics?.log("warp_undo_unavailable", [
                "reason": "original_sibling_was_a_branch",
                "original_sibling_window_ids": originalSiblingWindowIDs
            ])
            return nil
        }
        return BSPWarpUndoRecord(
            sourceWindowID: source.windowID,
            originalTargetWindowID: originalTargetID,
            originalDirection: originalDirection,
            space: source.space,
            expectedClosestParentWindowIDs: closestParent.windowIDs
        )
    }

    func undoWarp(_ record: BSPWarpUndoRecord) throws {
        diagnostics?.log("undo_warp_requested", [
            "source_window_id": record.sourceWindowID,
            "target_window_id": record.originalTargetWindowID,
            "direction": record.originalDirection.rawValue,
            "space": record.space
        ])
        try requireSuccess(
            ["-m", "window", String(record.originalTargetWindowID), "--insert", record.originalDirection.rawValue],
            action: "restore the original insertion direction"
        )
        try requireSuccess(
            ["-m", "window", String(record.sourceWindowID), "--warp", String(record.originalTargetWindowID)],
            action: "undo the last warp"
        )
        Thread.sleep(forTimeInterval: 0.15)
        let post = try windows(onSpace: record.space)
        let postBranches = try BSPTreeResolver().branches(for: record.sourceWindowID, in: post)
        guard postBranches.first?.windowIDs == record.expectedClosestParentWindowIDs else {
            diagnostics?.log("undo_warp_verification_failed", [
                "expected_window_ids": record.expectedClosestParentWindowIDs,
                "actual_branch_path": postBranches.map { $0.windowIDs.sorted() },
                "post_windows": post.map(Self.diagnosticWindow)
            ])
            throw AppError.message("Undo changed the layout, but did not restore the recorded closest BSP parent.")
        }
        diagnostics?.log("undo_warp_verified", [
            "post_branch_path": postBranches.map { $0.windowIDs.sorted() },
            "post_windows": post.map(Self.diagnosticWindow)
        ])
    }

    func balanceFocusedSpace() throws {
        let beforeSpace = run(["-m", "query", "--spaces", "--space"])
        let beforeWindows = run(["-m", "query", "--windows", "--space"])
        guard beforeSpace.succeeded, beforeWindows.succeeded else {
            throw AppError.message("Could not capture the current Space before balancing: \(beforeSpace.usefulError) \(beforeWindows.usefulError)")
        }
        diagnostics?.log("balance_requested", [
            "space_before": beforeSpace.standardOutput,
            "windows_before": beforeWindows.standardOutput
        ])
        try requireSuccess(["-m", "space", "--balance"], action: "balance the current Space")
        Thread.sleep(forTimeInterval: 0.15)
        let after = run(["-m", "query", "--windows", "--space"])
        guard after.succeeded else {
            throw AppError.message("yabai accepted balance, but the resulting window state could not be queried: \(after.usefulError)")
        }
        diagnostics?.log("balance_verified", ["windows_after": after.standardOutput])
    }

    func diagnosticSnapshot(uiSnapshot: String) -> String {
        var sections: [String] = []
        sections.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        sections.append("architecture: \(Self.architecture)")
        sections.append("app: \(Bundle.main.bundleIdentifier ?? "unknown") \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"))")
        sections.append("accessibility trusted: \(AXIsProcessTrusted())")
        sections.append(uiSnapshot)
        sections.append("yabai path: \(executableURL?.path ?? "not found")")
        let commands: [(String, [String])] = [
            ("YABAI VERSION", ["--version"]),
            ("MOUSE MODIFIER", ["-m", "config", "mouse_modifier"]),
            ("MOUSE ACTION 1", ["-m", "config", "mouse_action1"]),
            ("MOUSE ACTION 2", ["-m", "config", "mouse_action2"]),
            ("MOUSE DROP ACTION", ["-m", "config", "mouse_drop_action"]),
            ("FOCUSED DISPLAY", ["-m", "query", "--displays", "--display"]),
            ("FOCUSED SPACE", ["-m", "query", "--spaces", "--space"]),
            ("WINDOWS ON FOCUSED SPACE", ["-m", "query", "--windows", "--space"])
        ]
        for (title, arguments) in commands {
            let result = run(arguments)
            sections.append("\n--- \(title) ---\nexit=\(result.status)\nstdout:\n\(result.standardOutput)\nstderr:\n\(result.standardError)")
        }
        return sections.joined(separator: "\n")
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
        let started = Date()
        let result = ProcessRunner.run(executableURL, arguments: arguments)
        diagnostics?.log("yabai_command", [
            "arguments": arguments,
            "exit_status": Int(result.status),
            "duration_ms": Int(Date().timeIntervalSince(started) * 1000),
            "stdout": result.standardOutput,
            "stderr": result.standardError
        ])
        return result
    }

    private func requireSuccess(_ arguments: [String], action: String) throws {
        let result = run(arguments)
        guard result.succeeded else {
            throw AppError.message("Could not \(action): \(result.usefulError)")
        }
    }

    private func windows(onSpace space: Int) throws -> [BSPWindowSnapshot] {
        let result = run(["-m", "query", "--windows", "--space", String(space)])
        guard result.succeeded,
              let data = result.standardOutput.data(using: .utf8),
              let windows = try? JSONDecoder().decode([BSPWindowSnapshot].self, from: data) else {
            throw AppError.message("Could not verify the current BSP window state: \(result.usefulError)")
        }
        return windows
    }

    private static func originalDirection(for window: BSPWindowSnapshot) -> BSPWarpDirection {
        switch (window.splitType, window.splitChild) {
        case (.vertical, .first): return .west
        case (.vertical, .second): return .east
        case (.horizontal, .first): return .north
        case (.horizontal, .second): return .south
        default: return .east
        }
    }

    private static func diagnosticWindow(_ window: BSPWindowSnapshot) -> [String: Any] {
        [
            "id": window.id,
            "frame": diagnosticFrame(window.frame.rect),
            "space": window.space,
            "display": window.display,
            "split_type": window.splitType.rawValue,
            "split_child": window.splitChild.rawValue,
            "stack_index": window.stackIndex,
            "has_ax_reference": window.hasAXReference,
            "is_visible": window.isVisible,
            "is_floating": window.isFloating,
            "is_minimized": window.isMinimized,
            "is_hidden": window.isHidden
        ]
    }

    private static func diagnosticFrame(_ frame: CGRect) -> [String: Double] {
        [
            "x": Double(frame.minX),
            "y": Double(frame.minY),
            "w": Double(frame.width),
            "h": Double(frame.height)
        ]
    }

    private static var architecture: String {
#if arch(arm64)
        return "arm64"
#elseif arch(x86_64)
        return "x86_64"
#else
        return "unknown"
#endif
    }
}

private struct BSPSpaceSnapshot: Decodable {
    let type: String
}
