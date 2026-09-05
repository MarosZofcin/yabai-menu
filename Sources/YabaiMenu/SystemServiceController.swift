import AppKit

// Runtime-facing native capability bridge.
//
// The runtime never receives native objects or arbitrary callbacks. The host emits
// small JSON events and executes only operations explicitly allowlisted here. This
// creates a reusable category of native capabilities without exposing AppKit,
// Objective-C, the filesystem, shell commands, or unrestricted process execution.
@MainActor
final class SystemServiceController {
    static let shared = SystemServiceController()

    private static let maximumTextBytes = 1_000_000
    private static let maximumOperations = 16
    private static let stateDefaultsKey = "runtimeSystemServiceState"

    private var clipboardTimer: Timer?
    private var lastPasteboardChangeCount = NSPasteboard.general.changeCount
    private var workspaceObservers: [NSObjectProtocol] = []
    private var appObservers: [NSObjectProtocol] = []
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true

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

    private func runtimeState() -> [String: Any] {
        UserDefaults.standard.dictionary(forKey: Self.stateDefaultsKey) ?? [:]
    }

    private func applyStateSet(_ operation: [String: Any]) {
        guard let key = operation["key"] as? String,
              Self.validStateKey(key),
              let value = operation["value"],
              Self.validStateValue(value) else { return }
        var state = runtimeState()
        state[key] = value
        UserDefaults.standard.set(state, forKey: Self.stateDefaultsKey)
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
