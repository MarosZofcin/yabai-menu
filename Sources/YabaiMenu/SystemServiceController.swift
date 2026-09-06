import AppKit

// Runtime-facing native capability bridge.
//
// The runtime never receives native objects or arbitrary callbacks. The host emits
// small JSON events and executes only operations explicitly allowlisted here. It
// also renders a bounded set of runtime-declared boolean preferences in the app
// menu. This creates reusable native capabilities without exposing AppKit,
// Objective-C, the filesystem, shell commands, or unrestricted process execution.
@MainActor
final class SystemServiceController {
    static let shared = SystemServiceController()

    private struct RuntimePreference {
        let title: String
        let key: String
        let defaultValue: Bool
    }

    private static let maximumTextBytes = 1_000_000
    private static let maximumOperations = 16
    private static let maximumPreferences = 16
    private static let stateDefaultsKey = "runtimeSystemServiceState"

    private var clipboardTimer: Timer?
    private var lastPasteboardChangeCount = NSPasteboard.general.changeCount
    private var workspaceObservers: [NSObjectProtocol] = []
    private var appObservers: [NSObjectProtocol] = []
    private var menuObserver: NSObjectProtocol?
    private var runtimePreferences: [RuntimePreference] = []
    private var preferenceRefreshInProgress = false
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true

        // Load declarations before the first menu is normally opened. Failure is
        // fail-closed: the app still works, but no runtime preference is shown.
        runtimePreferences = loadRuntimePreferences()

        let timer = Timer(timeInterval: 0.10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollClipboard() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clipboardTimer = timer

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self?.emit(
                    kind: "workspace.application.activated",
                    payload: [
                        "name": app.localizedName ?? "",
                        "bundleIdentifier": app.bundleIdentifier ?? ""
                    ]
                )
            }
        })
        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.emit(kind: "workspace.didWake", payload: [:]) }
        })
        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.emit(kind: "workspace.willSleep", payload: [:]) }
        })

        let center = NotificationCenter.default
        appObservers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.emit(kind: "display.configuration.changed", payload: [:]) }
        })
        menuObserver = center.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self, let menu = notification.object as? NSMenu else { return }
                self.injectRuntimePreferences(into: menu)
                self.refreshRuntimePreferencesForNextOpen()
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.emit(
                kind: "host.started",
                payload: [
                    "hostVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                    "hostBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                    "macOS": ProcessInfo.processInfo.operatingSystemVersionString
                ]
            )
        }
    }

    func stop() {
        guard started else { return }
        started = false
        clipboardTimer?.invalidate()
        clipboardTimer = nil

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { workspaceCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        appObservers.forEach { NotificationCenter.default.removeObserver($0) }
        appObservers.removeAll()
        if let menuObserver { NotificationCenter.default.removeObserver(menuObserver) }
        menuObserver = nil
    }

    private func pollClipboard() {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        guard changeCount != lastPasteboardChangeCount else { return }
        lastPasteboardChangeCount = changeCount

        guard let text = pasteboard.string(forType: .string),
              text.utf8.count <= Self.maximumTextBytes else { return }

        emit(
            kind: "clipboard.text.changed",
            payload: ["text": text],
            expectedPasteboardChangeCount: changeCount
        )
    }

    private func emit(
        kind: String,
        payload: [String: Any],
        expectedPasteboardChangeCount: Int? = nil
    ) {
        let input: [String: Any] = [
            "kind": kind,
            "payload": payload,
            "state": runtimeState()
        ]

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = try? RuntimeController.shared.call("systemEvent", input: input)
            guard let result else { return }
            DispatchQueue.main.async {
                self?.apply(
                    result: result,
                    eventKind: kind,
                    expectedPasteboardChangeCount: expectedPasteboardChangeCount
                )
            }
        }
    }

    private func apply(
        result: Any,
        eventKind: String,
        expectedPasteboardChangeCount: Int?
    ) {
        guard let envelope = result as? [String: Any],
              let rawOperations = envelope["operations"] as? [Any],
              rawOperations.count <= Self.maximumOperations else { return }

        for rawOperation in rawOperations {
            guard let operation = rawOperation as? [String: Any],
                  let kind = operation["kind"] as? String else { continue }

            switch kind {
            case "clipboard.replaceText":
                applyClipboardReplacement(
                    operation,
                    eventKind: eventKind,
                    expectedPasteboardChangeCount: expectedPasteboardChangeCount
                )
            case "state.set":
                applyStateSet(operation)
            case "state.remove":
                applyStateRemove(operation)
            default:
                // Unknown runtime operations are intentionally ignored. Adding a
                // new native authority always requires an explicit host change.
                continue
            }
        }
    }

    private func applyClipboardReplacement(
        _ operation: [String: Any],
        eventKind: String,
        expectedPasteboardChangeCount: Int?
    ) {
        guard eventKind == "clipboard.text.changed",
              let expectedPasteboardChangeCount,
              let text = operation["text"] as? String,
              text.utf8.count <= Self.maximumTextBytes else { return }

        let pasteboard = NSPasteboard.general
        // Never overwrite a newer user copy while the runtime worker was busy.
        guard pasteboard.changeCount == expectedPasteboardChangeCount else { return }
        guard pasteboard.string(forType: .string) != text else { return }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Our own write changes changeCount. Record it immediately to avoid a loop.
        lastPasteboardChangeCount = pasteboard.changeCount
    }

    // MARK: - Runtime-declared preferences

    private func loadRuntimePreferences() -> [RuntimePreference] {
        guard let result = try? RuntimeController.shared.call("preferences", input: [:]),
              let rawPreferences = result as? [Any],
              rawPreferences.count <= Self.maximumPreferences else { return [] }

        var output: [RuntimePreference] = []
        var keys = Set<String>()
        for raw in rawPreferences {
            guard let object = raw as? [String: Any],
                  let title = object["title"] as? String,
                  let key = object["key"] as? String,
                  let defaultValue = object["defaultValue"] as? Bool,
                  !title.isEmpty, title.count <= 100,
                  Self.validStateKey(key),
                  !keys.contains(key) else { return [] }
            keys.insert(key)
            output.append(RuntimePreference(title: title, key: key, defaultValue: defaultValue))
        }
        return output
    }

    private func refreshRuntimePreferencesForNextOpen() {
        guard !preferenceRefreshInProgress else { return }
        preferenceRefreshInProgress = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let preferences = self.loadRuntimePreferencesOffMainThread()
            DispatchQueue.main.async {
                self.runtimePreferences = preferences
                self.preferenceRefreshInProgress = false
            }
        }
    }

    nonisolated private func loadRuntimePreferencesOffMainThread() -> [RuntimePreference] {
        guard let result = try? RuntimeController.shared.call("preferences", input: [:]),
              let rawPreferences = result as? [Any],
              rawPreferences.count <= Self.maximumPreferences else { return [] }

        var output: [RuntimePreference] = []
        var keys = Set<String>()
        for raw in rawPreferences {
            guard let object = raw as? [String: Any],
                  let title = object["title"] as? String,
                  let key = object["key"] as? String,
                  let defaultValue = object["defaultValue"] as? Bool,
                  !title.isEmpty, title.count <= 100,
                  Self.validStateKey(key),
                  !keys.contains(key) else { return [] }
            keys.insert(key)
            output.append(RuntimePreference(title: title, key: key, defaultValue: defaultValue))
        }
        return output
    }

    private func injectRuntimePreferences(into menu: NSMenu) {
        guard !runtimePreferences.isEmpty,
              menu.items.contains(where: { $0.title == "Quit Yabai Menu" }),
              let updaterIndex = menu.items.firstIndex(where: { $0.title == "Automatically Update Runtime" }) else { return }

        // AppDelegate rebuilds a fresh menu before each open. This extra guard
        // makes the injection idempotent if AppKit sends more than one tracking
        // notification for the same menu instance.
        guard !menu.items.contains(where: { ($0.representedObject as? String)?.hasPrefix("runtime.preference:") == true }) else { return }

        var insertionIndex = updaterIndex
        for preference in runtimePreferences {
            let item = NSMenuItem(
                title: preference.title,
                action: #selector(toggleRuntimePreference(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = "runtime.preference:\(preference.key)"
            item.state = boolState(for: preference.key, defaultValue: preference.defaultValue) ? .on : .off
            menu.insertItem(item, at: insertionIndex)
            insertionIndex += 1
        }
        menu.insertItem(.separator(), at: insertionIndex)
    }

    @objc private func toggleRuntimePreference(_ sender: NSMenuItem) {
        guard let marker = sender.representedObject as? String,
              marker.hasPrefix("runtime.preference:") else { return }
        let key = String(marker.dropFirst("runtime.preference:".count))
        guard let preference = runtimePreferences.first(where: { $0.key == key }) else { return }
        let next = !boolState(for: key, defaultValue: preference.defaultValue)
        setRuntimeState(next, forKey: key)
        sender.state = next ? .on : .off
    }

    private func boolState(for key: String, defaultValue: Bool) -> Bool {
        let state = runtimeState()
        return state[key] as? Bool ?? defaultValue
    }

    private func runtimeState() -> [String: Any] {
        UserDefaults.standard.dictionary(forKey: Self.stateDefaultsKey) ?? [:]
    }

    private func setRuntimeState(_ value: Any, forKey key: String) {
        guard Self.validStateKey(key), Self.validStateValue(value) else { return }
        var state = runtimeState()
        state[key] = value
        UserDefaults.standard.set(state, forKey: Self.stateDefaultsKey)
    }

    private func applyStateSet(_ operation: [String: Any]) {
        guard let key = operation["key"] as? String,
              let value = operation["value"] else { return }
        setRuntimeState(value, forKey: key)
    }

    private func applyStateRemove(_ operation: [String: Any]) {
        guard let key = operation["key"] as? String, Self.validStateKey(key) else { return }
        var state = runtimeState()
        state.removeValue(forKey: key)
        UserDefaults.standard.set(state, forKey: Self.stateDefaultsKey)
    }

    private static func validStateKey(_ key: String) -> Bool {
        guard key.hasPrefix("runtime."), key.count <= 80 else { return false }
        return key.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || ".-_".unicodeScalars.contains($0)
        }
    }

    private static func validStateValue(_ value: Any) -> Bool {
        if value is Bool { return true }
        if let string = value as? String { return string.utf8.count <= 4096 }
        if let number = value as? NSNumber { return number.doubleValue.isFinite }
        return false
    }
}
