import AppKit
import CoreGraphics

@MainActor
final class BranchHighlightController {
    private enum RequestMode {
        case optionClick
        case diagnostic
    }

    private let yabai: YabaiController
    private let statusHandler: (String) -> Void
    private let queryQueue = DispatchQueue(label: "sk.maroszofcin.YabaiMenu.bsp-query", qos: .userInitiated)

    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var eventTapUserInfo: UnsafeMutableRawPointer?
    private var releaseTimer: Timer?
    private var notificationObservers: [NSObjectProtocol] = []
    private var overlayWindow: BranchOverlayPanel?
    private var lastWindowID: Int?
    private var lastSpace: Int?
    private var branchLevel = 0

    init(yabai: YabaiController, statusHandler: @escaping (String) -> Void) {
        self.yabai = yabai
        self.statusHandler = statusHandler
    }

    func start() {
        guard eventTap == nil else { return }

        guard CGPreflightListenEventAccess() else {
            _ = CGRequestListenEventAccess()
            statusHandler("BSP highlight: Allow Input Monitoring, then relaunch Yabai Menu")
            return
        }

        let eventMask = CGEventMask(1) << CGEventType.leftMouseDown.rawValue
        let userInfo = Unmanaged.passRetained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: branchHighlightEventTapCallback,
            userInfo: userInfo
        ) else {
            Unmanaged<BranchHighlightController>.fromOpaque(userInfo).release()
            statusHandler("BSP highlight: Input Monitoring listener could not start; relaunch the app")
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            Unmanaged<BranchHighlightController>.fromOpaque(userInfo).release()
            statusHandler("BSP highlight: Input Monitoring listener could not start")
            return
        }
        eventTap = tap
        eventTapSource = source
        eventTapUserInfo = userInfo
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        statusHandler("BSP highlight: Ready — Option-click a tiled window")

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        notificationObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.resetAndHide() }
            }
        )
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.resetAndHide() }
            }
        )
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
            self.eventTapSource = nil
        }
        if let eventTapUserInfo {
            Unmanaged<BranchHighlightController>.fromOpaque(eventTapUserInfo).release()
            self.eventTapUserInfo = nil
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for observer in notificationObservers {
            workspaceCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()
        resetAndHide()
    }

    func runDiagnostic() {
        resetAndHide()
        statusHandler("BSP test: Point at a tiled window — checking in 3 seconds…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.requestHighlight(mode: .diagnostic)
        }
    }

    fileprivate func handleMouseDown(flags: CGEventFlags) {
        let relevantFlags = flags.intersection([.maskAlternate, .maskControl, .maskCommand, .maskShift])
        guard relevantFlags == .maskAlternate else {
            // A different modifier chord must never leave a stale branch
            // visible while the user performs an unrelated click.
            resetAndHide()
            return
        }

        requestHighlight(mode: .optionClick)
    }

    private func requestHighlight(mode: RequestMode) {
        if mode == .optionClick {
            statusHandler("BSP highlight: Option-click detected; reading yabai…")
        } else {
            statusHandler("BSP test: Reading yabai at the pointer…")
        }
        let yabai = self.yabai
        queryQueue.async { [weak self] in
            let result = Result { try yabai.bspBranchesAtMouse() }
            DispatchQueue.main.async {
                self?.consume(result, mode: mode)
            }
        }
    }

    private func consume(
        _ result: Result<BSPBranchSelection, Error>,
        mode: RequestMode
    ) {
        if mode == .optionClick, !Self.optionIsPressed() {
            resetAndHide()
            return
        }

        switch result {
        case .success(let selection):
            if mode == .diagnostic {
                lastWindowID = selection.windowID
                lastSpace = selection.space
                branchLevel = 0
            } else if lastWindowID == selection.windowID, lastSpace == selection.space {
                branchLevel = min(branchLevel + 1, selection.branches.count - 1)
            } else {
                lastWindowID = selection.windowID
                lastSpace = selection.space
                branchLevel = 0
            }
            guard selection.branches.indices.contains(branchLevel),
                  let frame = appKitRect(
                      for: selection.branches[branchLevel].frame,
                      display: selection.display
                  ) else {
                resetAndHide()
                let prefix = mode == .diagnostic ? "BSP test" : "BSP highlight"
                statusHandler("\(prefix): Could not map the yabai display to a macOS screen")
                return
            }
            showOverlay(frame: frame, level: branchLevel)
            if mode == .diagnostic {
                statusHandler("BSP test: Overlay displayed — yabai query works")
                startDiagnosticHideTimer()
            } else {
                statusHandler("BSP highlight: Branch \(branchLevel + 1) of \(selection.branches.count)")
                startReleaseTimer()
            }

        case .failure(let error):
            resetAndHide()
            let prefix = mode == .diagnostic ? "BSP test" : "BSP highlight"
            statusHandler("\(prefix): \(error.localizedDescription)")
        }
    }

    private func showOverlay(frame: CGRect, level: Int) {
        let panel: BranchOverlayPanel
        if let overlayWindow {
            panel = overlayWindow
        } else {
            panel = BranchOverlayPanel()
            overlayWindow = panel
        }
        let expandedFrame = frame.insetBy(dx: -4, dy: -4)
        panel.setFrame(expandedFrame, display: true)
        panel.overlayView.color = Self.colors[level % Self.colors.count]
        panel.orderFrontRegardless()
    }

    private func appKitRect(
        for yabaiRect: CGRect,
        display: BSPDisplaySnapshot
    ) -> CGRect? {
        guard let screen = NSScreen.screens.first(where: { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return number.uint32Value == display.id
        }) else { return nil }

        return BSPCoordinateConverter.appKitRect(
            fromYabai: yabaiRect,
            yabaiDisplayFrame: display.frame.rect,
            appKitScreenFrame: screen.frame
        )
    }

    private func startReleaseTimer() {
        guard releaseTimer == nil else { return }
        releaseTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            guard !Self.optionIsPressed() else { return }
            Task { @MainActor in self?.resetAndHide() }
        }
    }

    private func startDiagnosticHideTimer() {
        releaseTimer?.invalidate()
        releaseTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.resetAndHide() }
        }
    }

    private func resetAndHide() {
        releaseTimer?.invalidate()
        releaseTimer = nil
        overlayWindow?.orderOut(nil)
        lastWindowID = nil
        lastSpace = nil
        branchLevel = 0
    }

    fileprivate func reenableEventTap() {
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private static func optionIsPressed() -> Bool {
        CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate)
    }

    private static let colors: [NSColor] = [
        .systemCyan,
        .systemOrange,
        .systemPink,
        .systemGreen,
        .systemPurple,
        .systemYellow
    ]
}

private let branchHighlightEventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<BranchHighlightController>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        Task { @MainActor in controller.reenableEventTap() }
    } else if type == .leftMouseDown {
        let flags = event.flags
        Task { @MainActor in controller.handleMouseDown(flags: flags) }
    }
    return Unmanaged.passUnretained(event)
}

private final class BranchOverlayPanel: NSPanel {
    let overlayView = BranchOverlayView(frame: .zero)

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        overlayView.autoresizingMask = [.width, .height]
        contentView = overlayView
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        level = .screenSaver
        // The panel follows the selected Space; it is deliberately not a
        // canJoinAllSpaces panel, because a stale branch must not be visible
        // after the user changes Spaces on this display.
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class BranchOverlayView: NSView {
    var color: NSColor = .systemCyan {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 4, dy: 4)
        guard rect.width > 0, rect.height > 0 else { return }
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        color.withAlphaComponent(0.07).setFill()
        path.fill()
        color.withAlphaComponent(0.96).setStroke()
        path.lineWidth = 5
        path.stroke()
    }
}
