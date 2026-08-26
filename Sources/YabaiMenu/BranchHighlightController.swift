import AppKit
import CoreGraphics

@MainActor
final class BranchHighlightController {
    private let yabai: YabaiController
    private let statusHandler: (String) -> Void
    private let queryQueue = DispatchQueue(label: "sk.maroszofcin.YabaiMenu.bsp-query", qos: .userInitiated)

    private var mouseMonitor: Any?
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
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            Task { @MainActor in self?.handleMouseDown(event) }
        }

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
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for observer in notificationObservers {
            workspaceCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()
        resetAndHide()
    }

    private func handleMouseDown(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.option),
              !flags.contains(.control),
              !flags.contains(.command),
              !flags.contains(.shift) else {
            // A different modifier chord must never leave a stale branch
            // visible while the user performs an unrelated click.
            resetAndHide()
            return
        }

        let yabai = self.yabai
        queryQueue.async { [weak self] in
            let result = Result { try yabai.bspBranchesAtMouse() }
            DispatchQueue.main.async {
                self?.consume(result)
            }
        }
    }

    private func consume(_ result: Result<BSPBranchSelection, Error>) {
        guard Self.optionIsPressed() else {
            resetAndHide()
            return
        }

        switch result {
        case .success(let selection):
            if lastWindowID == selection.windowID, lastSpace == selection.space {
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
                return
            }
            showOverlay(frame: frame, level: branchLevel)
            statusHandler("BSP branch \(branchLevel + 1) of \(selection.branches.count)")
            startReleaseTimer()

        case .failure(let error):
            resetAndHide()
            statusHandler(error.localizedDescription)
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

    private func resetAndHide() {
        releaseTimer?.invalidate()
        releaseTimer = nil
        overlayWindow?.orderOut(nil)
        lastWindowID = nil
        lastSpace = nil
        branchLevel = 0
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
