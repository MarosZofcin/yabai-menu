import AppKit
import CoreGraphics
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let repositoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("dotfiles")
    private lazy var yabaircURL = repositoryURL.appendingPathComponent("yabai/yabairc")
    private lazy var store = YabaircBlacklistStore(fileURL: yabaircURL)
    private lazy var gitSync = GitSyncController(repositoryURL: repositoryURL, managedFileURL: yabaircURL)
    private let diagnostics = DiagnosticLogger.shared
    private let automaticUpdater = AutomaticUpdateController()
    private lazy var yabai = YabaiController(diagnostics: diagnostics)
    private lazy var branchHighlight = BranchHighlightController(
        yabai: yabai,
        diagnostics: diagnostics
    ) { [weak self] message in
        guard let self else { return }
        self.branchHighlightStatus = message
        self.rebuildMenu()
    }

    private var statusItem: NSStatusItem!
    private var statusTimer: Timer?
    private var hourlySyncTimer: Timer?
    private var automaticUpdateTimer: Timer?
    private var snapshot = YabaiSnapshot(isRunning: false, displays: [])
    private var floatingApps: [FloatingApp] = []
    private var currentApp: RunningApplication?
    private var branchHighlightStatus = "BSP highlight: Starting…"
    private var operationStatus: String?
    private var operationInProgress = false
    private var updateCheckInProgress = false
    private var updateMenuTitle = "Check for Updates"
    private var gitHubState = GitHubSyncState.unknown
    private var lastSuccessfulSync: Date? {
        didSet { UserDefaults.standard.set(lastSuccessfulSync, forKey: "lastSuccessfulGitHubSync") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        diagnostics.log("application_started", [
            "macos": ProcessInfo.processInfo.operatingSystemVersionString,
            "version": Self.versionTitle
        ])
        lastSuccessfulSync = UserDefaults.standard.object(forKey: "lastSuccessfulGitHubSync") as? Date

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let statusImage = NSImage(
            systemSymbolName: "square.grid.2x2",
            accessibilityDescription: "Yabai Menu"
        )
        statusImage?.isTemplate = true
        statusItem.button?.image = statusImage
        statusItem.button?.toolTip = "Yabai Menu"

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeApplicationChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        loadFloatingApps()
        captureCurrentApplication(NSWorkspace.shared.frontmostApplication)
        refreshStatus()
        rebuildMenu()
        branchHighlight.start()

        configureTimers()

        DispatchQueue.main.async { [weak self] in
            self?.performGitSync(reason: "Startup sync")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + RuntimeController.shared.interval("wakeDelay", fallback: 15)) { [weak self] in
            self?.checkForUpdates(silent: true)
        }
    }

    private func configureTimers() {
        statusTimer?.invalidate()
        hourlySyncTimer?.invalidate()
        automaticUpdateTimer?.invalidate()
        let runtime = RuntimeController.shared
        statusTimer = Timer.scheduledTimer(withTimeInterval: runtime.interval("statusInterval", fallback: 3), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
        hourlySyncTimer = Timer.scheduledTimer(withTimeInterval: runtime.interval("syncInterval", fallback: 3600), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.performGitSync(reason: "Hourly sync") }
        }
        automaticUpdateTimer = Timer.scheduledTimer(withTimeInterval: runtime.interval("updateInterval", fallback: 21600), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForUpdates(silent: true) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusTimer?.invalidate()
        hourlySyncTimer?.invalidate()
        automaticUpdateTimer?.invalidate()
        branchHighlight.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshStatus()
        rebuildMenu()
    }

    @objc private func activeApplicationChanged(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        captureCurrentApplication(app)
        rebuildMenu()
    }

    @objc private func systemDidWake(_ notification: Notification) {
        performGitSync(reason: "Wake sync")
        DispatchQueue.main.asyncAfter(deadline: .now() + RuntimeController.shared.interval("wakeDelay", fallback: 15)) { [weak self] in
            self?.checkForUpdates(silent: true)
        }
    }

    private func captureCurrentApplication(_ app: NSRunningApplication?) {
        guard let app,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              let name = app.localizedName,
              !name.isEmpty else { return }
        currentApp = RunningApplication(name: name, bundleIdentifier: app.bundleIdentifier)
    }

    private func loadFloatingApps() {
        do {
            floatingApps = try store.load()
        } catch {
            operationStatus = "Could not read yabairc: \(error.localizedDescription)"
        }
    }

    private func refreshStatus() {
        snapshot = yabai.snapshot()
        branchHighlight.refreshPermissions()
        statusItem.button?.contentTintColor = nil
        statusItem.button?.toolTip = snapshot.isRunning ? "yabai is running" : "yabai is stopped"
    }

    private func rebuildMenu() {
        guard statusItem != nil else { return }
        let menu = NSMenu()
        menu.delegate = self

        menu.addItem(disabledItem("yabai: \(snapshot.isRunning ? "Running" : "Stopped")"))
        if snapshot.isRunning {
            snapshot.displays.forEach { menu.addItem(disabledItem("\($0.name): \($0.layout)")) }
        }

        menu.addItem(.separator())
        menu.addItem(disabledItem("Current app: \(currentApp?.name ?? "Unavailable")"))
        menu.addItem(disabledItem(Self.shortened(branchHighlightStatus)))
        menu.addItem(disabledItem("Accessibility: \(branchHighlight.hasAccessibilityPermission ? "Allowed" : "Required")"))
        menu.addItem(disabledItem("Input Monitoring: \(branchHighlight.hasInputMonitoringPermission ? "Allowed" : "Required")"))
        if !branchHighlight.hasAccessibilityPermission {
            menu.addItem(actionItem("Open Accessibility Settings", #selector(openAccessibilitySettings)))
        }
        if !branchHighlight.hasInputMonitoringPermission {
            menu.addItem(actionItem("Open Input Monitoring Settings", #selector(openInputMonitoringSettings)))
        }
        menu.addItem(disabledItem("Inspect branch: Control + Shift + hover"))
        menu.addItem(disabledItem("Move window: Control + Option + drag"))
        appendRuntimeMenu(to: menu, section: "tools")
        let undoItem = actionItem("Undo Last Warp", #selector(undoLastWarp))
        undoItem.isEnabled = !operationInProgress && branchHighlight.canUndo
        menu.addItem(undoItem)
        if let currentApp {
            let isFloating = store.contains(floatingApps, application: currentApp)
            let title = isFloating ? "Remove \(currentApp.name) from Floating Apps" : "Float \(currentApp.name)"
            let item = NSMenuItem(
                title: title,
                action: isFloating ? #selector(removeCurrentApp) : #selector(addCurrentApp),
                keyEquivalent: ""
            )
            item.target = self
            item.isEnabled = !operationInProgress
            menu.addItem(item)
        }

        let floatingMenuItem = NSMenuItem(title: "Floating Apps in yabairc", action: nil, keyEquivalent: "")
        let floatingMenu = NSMenu()
        if floatingApps.isEmpty {
            floatingMenu.addItem(disabledItem("No entries"))
        } else {
            for (index, app) in floatingApps.enumerated() {
                let item = NSMenuItem(title: "Remove \(app.name)", action: #selector(removeListedApp(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                item.isEnabled = !operationInProgress
                floatingMenu.addItem(item)
            }
        }
        floatingMenuItem.submenu = floatingMenu
        menu.addItem(floatingMenuItem)

        menu.addItem(.separator())
        if snapshot.isRunning {
            appendRuntimeMenu(to: menu, section: "running")
        } else {
            appendRuntimeMenu(to: menu, section: "stopped")
        }

        menu.addItem(.separator())
        menu.addItem(disabledItem("GitHub: \(gitHubState.title)"))
        let syncDate = lastSuccessfulSync.map { Self.syncDateFormatter.string(from: $0) } ?? "Never"
        menu.addItem(disabledItem("Last sync: \(syncDate)"))
        appendRuntimeMenu(to: menu, section: "sync")
        if let operationStatus {
            menu.addItem(disabledItem(Self.shortened(operationStatus)))
        }

        appendRuntimeMenu(to: menu, section: "files")
        let loggingItem = actionItem("Detailed Diagnostic Logging", #selector(toggleDiagnosticLogging))
        loggingItem.state = diagnostics.isEnabled ? .on : .off
        menu.addItem(loggingItem)
        menu.addItem(actionItem("Export Diagnostics to Desktop", #selector(exportDiagnostics)))

        if #available(macOS 13.0, *) {
            let loginItem = actionItem("Launch Yabai Menu at Login", #selector(toggleLaunchAtLogin))
            loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(loginItem)
        }

        menu.addItem(.separator())
        let updateItem = actionItem(updateMenuTitle, #selector(checkForUpdatesNow))
        updateItem.isEnabled = !operationInProgress && !updateCheckInProgress
        menu.addItem(updateItem)
        let autoItem = actionItem("Automatically Update Runtime", #selector(toggleRuntimeUpdates))
        autoItem.state = UserDefaults.standard.bool(forKey: "runtimeUpdatesDisabled") ? .off : .on
        menu.addItem(autoItem)
        menu.addItem(actionItem("Restore Previous Runtime", #selector(restorePreviousRuntime)))
        menu.addItem(actionItem("Host Releases (Manual Installation)", #selector(openHostReleases)))
        let runtimeVersion = (try? RuntimeController.shared.package().version) ?? "Unavailable"
        menu.addItem(disabledItem("Runtime \(runtimeVersion) · Host API \(RuntimeController.api)"))
        menu.addItem(disabledItem(Self.versionTitle))
        menu.addItem(actionItem("Quit Yabai Menu", #selector(quitApp), key: "q"))
        statusItem.menu = menu
    }

    @objc private func testBSPHighlight() {
        branchHighlight.runDiagnostic()
    }

    private func appendRuntimeMenu(to menu: NSMenu, section: String) {
        // Explicit selector map: runtime strings are never interpreted as ObjC
        // selectors, shell commands or paths.
        let actions: [String: Selector] = [
            "testBSPHighlight": #selector(testBSPHighlight),
            "balanceCurrentSpace": #selector(balanceCurrentSpace),
            "editYabairc": #selector(editYabairc), "openRepository": #selector(openRepository),
            "reloadYabai": #selector(reloadYabai), "stopYabai": #selector(stopYabai),
            "startYabai": #selector(startYabai), "syncNow": #selector(syncNow)
        ]
        for entry in (try? RuntimeController.shared.package().menu) ?? [] where entry.section == section {
            if let selector = actions[entry.action] { menu.addItem(actionItem(entry.title, selector)) }
        }
    }

    @objc private func toggleRuntimeUpdates() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: "runtimeUpdatesDisabled"), forKey: "runtimeUpdatesDisabled")
        rebuildMenu()
    }

    @objc private func restorePreviousRuntime() {
        do {
            try RuntimeController.shared.rollback()
            UserDefaults.standard.set(true, forKey: "runtimeUpdatesDisabled")
            updateMenuTitle = "Runtime Restored (Automatic Updates Paused)"
            configureTimers()
        } catch { operationStatus = error.localizedDescription }
        rebuildMenu()
    }

    @objc private func openHostReleases() {
        NSWorkspace.shared.open(URL(string: "https://github.com/MarosZofcin/yabai-menu/releases")!)
    }

    @objc private func balanceCurrentSpace() {
        branchHighlight.balanceCurrentSpace()
    }

    @objc private func undoLastWarp() {
        branchHighlight.undoLastWarp()
    }

    @objc private func exportDiagnostics() {
        operationStatus = "Collecting diagnostics…"
        rebuildMenu()
        let uiSnapshot = Self.uiDiagnosticSnapshot()
            + "\ndiagnostic logging enabled: \(diagnostics.isEnabled)"
            + "\nBSP listener active: \(branchHighlight.isListening)"
        let yabai = yabai
        let diagnostics = diagnostics
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let snapshot = yabai.diagnosticSnapshot(uiSnapshot: uiSnapshot)
                let url = try diagnostics.exportReport(systemSnapshot: snapshot)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.operationStatus = "Diagnostics saved: \(url.lastPathComponent)"
                    self.diagnostics.log("diagnostic_report_revealed", ["path": url.path])
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    self.rebuildMenu()
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.operationStatus = "Diagnostics failed: \(error.localizedDescription)"
                    self.diagnostics.log("diagnostic_report_failed", ["error": error.localizedDescription])
                    NSSound.beep()
                    self.rebuildMenu()
                }
            }
        }
    }

    @objc private func toggleDiagnosticLogging() {
        diagnostics.setEnabled(!diagnostics.isEnabled)
        operationStatus = diagnostics.isEnabled
            ? "Detailed diagnostic logging enabled"
            : "Detailed diagnostic logging disabled"
        rebuildMenu()
    }

    @objc private func openAccessibilitySettings() {
        openPrivacySettings(anchor: "Privacy_Accessibility")
    }

    @objc private func openInputMonitoringSettings() {
        openPrivacySettings(anchor: "Privacy_ListenEvent")
    }

    private func openPrivacySettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = !operationInProgress
        return item
    }

    @objc private func addCurrentApp() {
        guard let currentApp else { return }
        performBlacklistChange(description: "Adding \(currentApp.name)…") { store in
            try store.adding(currentApp)
        }
    }

    @objc private func removeCurrentApp() {
        guard let currentApp,
              let app = floatingApps.first(where: {
                  if let lhs = $0.bundleIdentifier, let rhs = currentApp.bundleIdentifier { return lhs == rhs }
                  return $0.name.caseInsensitiveCompare(currentApp.name) == .orderedSame
              }) else { return }
        remove(app)
    }

    @objc private func removeListedApp(_ sender: NSMenuItem) {
        guard floatingApps.indices.contains(sender.tag) else { return }
        remove(floatingApps[sender.tag])
    }

    private func remove(_ app: FloatingApp) {
        performBlacklistChange(description: "Removing \(app.name)…") { store in
            try store.removing(app)
        }
    }

    private func performBlacklistChange(
        description: String,
        change: @escaping (YabaircBlacklistStore) throws -> (old: [FloatingApp], new: [FloatingApp])
    ) {
        guard !operationInProgress else { return }
        operationInProgress = true
        operationStatus = description
        gitHubState = .syncing
        rebuildMenu()

        let store = self.store
        let gitSync = self.gitSync
        let yabai = self.yabai
        let shouldApply = snapshot.isRunning

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                _ = try gitSync.sync()
                let changed = try change(store)
                _ = try gitSync.commitManagedFile()

                if shouldApply {
                    try yabai.applyBlacklist(
                        changed.new,
                        additionalLabelsToRemove: changed.old.map(\.ruleLabel)
                    )
                    let removed = changed.old.filter { oldApp in
                        !changed.new.contains(where: { $0.appPattern == oldApp.appPattern })
                    }
                    removed.forEach { yabai.tileOpenWindows(for: $0) }
                }

                let report = try gitSync.sync()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.finishSuccessfulSync(report, message: "Blacklist updated and synchronized")
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.finishFailedOperation(error)
                }
            }
        }
    }

    @objc private func syncNow() {
        performGitSync(reason: "Manual sync")
    }

    private func performGitSync(reason: String) {
        guard !operationInProgress else { return }
        operationInProgress = true
        operationStatus = reason
        gitHubState = .syncing
        rebuildMenu()

        let gitSync = self.gitSync
        let store = self.store
        let yabai = self.yabai
        let oldLabels = floatingApps.map(\.ruleLabel)
        let shouldApply = snapshot.isRunning

        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let report = try gitSync.sync()
                let apps = try store.load()
                if report.configChanged && shouldApply {
                    try yabai.applyBlacklist(apps, additionalLabelsToRemove: oldLabels)
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.floatingApps = apps
                    self.finishSuccessfulSync(report, message: report.message)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.finishFailedOperation(error)
                }
            }
        }
    }

    private func finishSuccessfulSync(_ report: GitSyncReport, message: String) {
        operationInProgress = false
        gitHubState = .synced
        lastSuccessfulSync = report.synchronizedAt
        operationStatus = message
        loadFloatingApps()
        refreshStatus()
        rebuildMenu()
    }

    private func finishFailedOperation(_ error: Error) {
        operationInProgress = false
        if let failure = error as? GitSyncFailure {
            gitHubState = failure.syncState
        } else {
            gitHubState = .error
        }
        operationStatus = error.localizedDescription
        loadFloatingApps()
        refreshStatus()
        NSSound.beep()
        rebuildMenu()
    }

    @objc private func startYabai() {
        runYabaiOperation(label: "Starting yabai…") { [yabai, floatingApps] in
            try yabai.start()
            try yabai.applyBlacklistWhenReady(floatingApps)
            return "yabai started"
        }
    }

    @objc private func stopYabai() {
        runYabaiOperation(label: "Stopping yabai…") { [yabai] in
            try yabai.stop()
            return "yabai stopped"
        }
    }

    @objc private func reloadYabai() {
        guard !operationInProgress else { return }
        operationInProgress = true
        operationStatus = "Saving yabairc and reloading yabai…"
        gitHubState = .syncing
        rebuildMenu()

        let gitSync = self.gitSync
        let store = self.store
        let yabai = self.yabai
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let report = try gitSync.sync()
                let apps = try store.load()
                try yabai.reload()
                try yabai.applyBlacklistWhenReady(apps)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.floatingApps = apps
                    self.finishSuccessfulSync(
                        report,
                        message: "yabairc saved, synchronized, and yabai reloaded"
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    self?.finishFailedOperation(error)
                }
            }
        }
    }

    private func runYabaiOperation(label: String, operation: @escaping () throws -> String) {
        guard !operationInProgress else { return }
        operationInProgress = true
        operationStatus = label
        rebuildMenu()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try operation() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.operationInProgress = false
                switch result {
                case .success(let message): self.operationStatus = message
                case .failure(let error):
                    self.operationStatus = error.localizedDescription
                    NSSound.beep()
                }
                self.refreshStatus()
                self.rebuildMenu()
            }
        }
    }

    @objc private func editYabairc() {
        let result = ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/open"),
            arguments: ["-t", yabaircURL.path]
        )
        if !result.succeeded {
            operationStatus = "Could not open yabairc for editing: \(result.usefulError)"
            NSSound.beep()
            rebuildMenu()
        }
    }

    @objc private func openRepository() {
        NSWorkspace.shared.open(repositoryURL)
    }

    @objc private func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            operationStatus = SMAppService.mainApp.status == .enabled ? "Launch at Login enabled" : "Launch at Login disabled"
        } catch {
            operationStatus = "Could not change Launch at Login: \(error.localizedDescription)"
            NSSound.beep()
        }
        rebuildMenu()
    }

    @objc private func checkForUpdatesNow() {
        checkForUpdates(silent: false)
    }

    private func checkForUpdates(silent: Bool) {
        if silent && UserDefaults.standard.bool(forKey: "runtimeUpdatesDisabled") { return }
        guard !updateCheckInProgress else { return }
        guard !operationInProgress else {
            if silent {
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                    self?.checkForUpdates(silent: true)
                }
            }
            return
        }

        updateCheckInProgress = true
        operationInProgress = true
        updateMenuTitle = "Checking Runtime Updates…"
        rebuildMenu()

        automaticUpdater.checkAndInstall { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateCheckInProgress = false
                self.operationInProgress = false

                switch result {
                case .success(.upToDate):
                    self.updateMenuTitle = "Check for Updates (Up to Date)"
                    self.diagnostics.log("automatic_update_up_to_date")
                    self.rebuildMenu()
                case .success(.runtimeInstalled(let version)):
                    self.updateMenuTitle = "Runtime \(version) Installed"
                    self.diagnostics.log("runtime_update_installed", ["version": version])
                    self.configureTimers()
                    self.rebuildMenu()
                case .failure(let error):
                    self.updateMenuTitle = "Check for Updates (Last Check Failed)"
                    self.diagnostics.log("automatic_update_failed", ["error": error.localizedDescription])
                    if !silent {
                        self.operationStatus = "Update failed: \(error.localizedDescription)"
                        NSSound.beep()
                    }
                    self.rebuildMenu()
                }
            }
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private static func shortened(_ message: String) -> String {
        let oneLine = message.replacingOccurrences(of: "\n", with: " ")
        return oneLine.count > 110 ? String(oneLine.prefix(107)) + "…" : oneLine
    }

    private static let syncDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static var versionTitle: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = info?["CFBundleVersion"] as? String ?? "Unknown"
        return "Yabai Menu \(version) (build \(build))"
    }

    private static func uiDiagnosticSnapshot() -> String {
        let screens = NSScreen.screens.map { screen -> [String: Any] in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return [
                "display_id": number?.uint32Value as Any,
                "frame": NSStringFromRect(screen.frame),
                "visible_frame": NSStringFromRect(screen.visibleFrame),
                "backing_scale_factor": screen.backingScaleFactor
            ]
        }
        let quartzPointer = CGEvent(source: nil)?.location ?? .zero
        return "pointer (AppKit bottom-left): \(NSEvent.mouseLocation)\npointer (Quartz top-left): \(quartzPointer)\nscreens: \(screens)"
    }
}
