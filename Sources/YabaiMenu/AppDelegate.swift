import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let repositoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("dotfiles")
    private lazy var yabaircURL = repositoryURL.appendingPathComponent("yabai/yabairc")
    private lazy var store = YabaircBlacklistStore(fileURL: yabaircURL)
    private lazy var gitSync = GitSyncController(repositoryURL: repositoryURL, managedFileURL: yabaircURL)
    private let yabai = YabaiController()
    private lazy var branchHighlight = BranchHighlightController(yabai: yabai) { [weak self] message in
        guard let self else { return }
        self.branchHighlightStatus = message
        self.rebuildMenu()
    }

    private var statusItem: NSStatusItem!
    private var statusTimer: Timer?
    private var hourlySyncTimer: Timer?
    private var snapshot = YabaiSnapshot(isRunning: false, displays: [])
    private var floatingApps: [FloatingApp] = []
    private var currentApp: RunningApplication?
    private var branchHighlightStatus = "BSP highlight: Starting…"
    private var operationStatus: String?
    private var operationInProgress = false
    private var gitHubState = GitHubSyncState.unknown
    private var lastSuccessfulSync: Date? {
        didSet { UserDefaults.standard.set(lastSuccessfulSync, forKey: "lastSuccessfulGitHubSync") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
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

        statusTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
        hourlySyncTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.performGitSync(reason: "Hourly sync") }
        }

        DispatchQueue.main.async { [weak self] in
            self?.performGitSync(reason: "Startup sync")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusTimer?.invalidate()
        hourlySyncTimer?.invalidate()
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
        menu.addItem(actionItem("Test BSP Highlight in 3 Seconds", #selector(testBSPHighlight)))
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
            menu.addItem(actionItem("Reload yabai", #selector(reloadYabai)))
            menu.addItem(actionItem("Stop yabai", #selector(stopYabai)))
        } else {
            menu.addItem(actionItem("Start yabai", #selector(startYabai)))
        }

        menu.addItem(.separator())
        menu.addItem(disabledItem("GitHub: \(gitHubState.title)"))
        let syncDate = lastSuccessfulSync.map { Self.syncDateFormatter.string(from: $0) } ?? "Never"
        menu.addItem(disabledItem("Last sync: \(syncDate)"))
        menu.addItem(actionItem("Sync Now", #selector(syncNow)))
        if let operationStatus {
            menu.addItem(disabledItem(Self.shortened(operationStatus)))
        }

        menu.addItem(actionItem("Edit yabairc", #selector(editYabairc)))
        menu.addItem(actionItem("Open dotfiles Folder", #selector(openRepository)))

        if #available(macOS 13.0, *) {
            let loginItem = actionItem("Launch Yabai Menu at Login", #selector(toggleLaunchAtLogin))
            loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(loginItem)
        }

        menu.addItem(.separator())
        menu.addItem(disabledItem(Self.versionTitle))
        menu.addItem(actionItem("Quit Yabai Menu", #selector(quitApp), key: "q"))
        statusItem.menu = menu
    }

    @objc private func testBSPHighlight() {
        branchHighlight.runDiagnostic()
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
        runYabaiOperation(label: "Reloading yabai…") { [yabai, floatingApps] in
            try yabai.reload()
            try yabai.applyBlacklistWhenReady(floatingApps)
            return "yabai reloaded"
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
}
