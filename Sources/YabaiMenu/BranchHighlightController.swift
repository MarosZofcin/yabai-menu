import AppKit
import ApplicationServices
import CoreGraphics

private let bspInspectModifiers: CGEventFlags = [.maskControl, .maskShift]
private let bspDragModifiers: CGEventFlags = [.maskControl, .maskAlternate]
private let bspRelevantModifiers: CGEventFlags = [.maskControl, .maskShift, .maskAlternate, .maskCommand]

private func normalizedBSPModifiers(_ flags: CGEventFlags) -> CGEventFlags {
    flags.intersection(bspRelevantModifiers)
}

@MainActor
final class BranchHighlightController {
    private let yabai: YabaiController
    private let diagnostics: DiagnosticLogger
    private let statusHandler: (String) -> Void
    private let queryQueue = DispatchQueue(label: "sk.maroszofcin.YabaiMenu.bsp-query", qos: .userInitiated)

    private let branchOverlay = BranchOverlayPanel(
        strokeColor: NSColor.systemCyan,
        fillColor: NSColor.systemCyan.withAlphaComponent(0.10),
        lineWidth: 6
    )
    private let sourceOverlay = BranchOverlayPanel(
        strokeColor: NSColor.systemBlue,
        fillColor: NSColor.systemBlue.withAlphaComponent(0.08),
        lineWidth: 5
    )
    private let targetOverlay = BranchOverlayPanel(
        strokeColor: NSColor.systemGreen,
        fillColor: NSColor.systemGreen.withAlphaComponent(0.22),
        lineWidth: 5
    )

    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var currentModifiers: CGEventFlags = []
    private var lastLoggedModifiers: CGEventFlags = []
    private var latestPointer = CGPoint.zero

    private var hoverGeneration = 0
    private var hoverQueryInFlight = false
    private var lastHoverQueryAt = Date.distantPast
    private var lastHoverWindowID: Int?

    private var dragToken: UUID?
    private var dragMouseIsDown = false
    private var dragIsFinalizing = false
    private var dragSource: BSPBranchSelection?
    private var dragTarget: BSPWindowSnapshot?
    private var dragDirection: BSPWarpDirection?
    private var dragTargetQueryInFlight = false
    private var lastDragTargetQueryAt = Date.distantPast
    private var lastUndoRecord: BSPWarpUndoRecord?

    private var status = "BSP tools: Starting…"
    private var isStarted = false

    var canUndo: Bool { lastUndoRecord != nil }
    var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }
    var hasInputMonitoringPermission: Bool { CGPreflightListenEventAccess() }
    var isListening: Bool { eventTap != nil }

    init(
        yabai: YabaiController,
        diagnostics: DiagnosticLogger,
        statusHandler: @escaping (String) -> Void
    ) {
        self.yabai = yabai
        self.diagnostics = diagnostics
        self.statusHandler = statusHandler
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let accessibility = AXIsProcessTrustedWithOptions(options)
        let inputMonitoring = CGPreflightListenEventAccess() || CGRequestListenEventAccess()
        diagnostics.log("input_permissions_checked", [
            "accessibility": accessibility,
            "input_monitoring": inputMonitoring,
            "prompted": true
        ])
        refreshPermissions()
    }

    func refreshPermissions() {
        guard isStarted else { return }
        let accessibility = AXIsProcessTrusted()
        let inputMonitoring = CGPreflightListenEventAccess()
        guard accessibility && inputMonitoring else {
            tearDownEventTap(reason: "permission_missing")
            let missing: String
            if !accessibility && !inputMonitoring {
                missing = "Accessibility and Input Monitoring permissions required"
            } else if !accessibility {
                missing = "Accessibility permission required"
            } else {
                missing = "Input Monitoring permission required"
            }
            updateStatus("BSP tools: \(missing)")
            return
        }
        guard eventTap == nil else { return }

        let mask = [
            CGEventType.mouseMoved,
            .leftMouseDown,
            .leftMouseDragged,
            .leftMouseUp,
            .flagsChanged
        ].reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: bspEventTapCallback,
            userInfo: userInfo
        ) else {
            diagnostics.log("event_tap_creation_failed")
            updateStatus("BSP tools: Could not start global mouse listener")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        eventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        diagnostics.log("event_tap_started", [
            "inspect_modifiers": "control+shift",
            "drag_modifiers": "control+option"
        ])
        updateStatus("BSP tools: Ready")
    }

    func stop() {
        isStarted = false
        tearDownEventTap(reason: "application_stopping")
    }

    private func tearDownEventTap(reason: String) {
        guard eventTap != nil || eventTapSource != nil else { return }
        cancelInteractions(reason: reason)
        if let source = eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        eventTapSource = nil
        eventTap = nil
        diagnostics.log("event_tap_stopped", ["reason": reason])
    }

    func runDiagnostic() {
        diagnostics.log("highlight_test_scheduled", ["delay_seconds": 3])
        updateStatus("BSP test: point at a tiled window…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            let pointer = NSEvent.mouseLocation
            self.queryBranch(at: pointer, purpose: "diagnostic") { result in
                switch result {
                case .success(let selection):
                    guard let branch = selection.branches.first else { return }
                    self.branchOverlay.show(yabaiFrame: branch.frame, display: selection.display)
                    self.diagnostics.log("highlight_test_succeeded", [
                        "window_id": selection.windowID,
                        "branch_window_ids": branch.windowIDs,
                        "branch_frame": branch.frame
                    ])
                    self.updateStatus("BSP test: highlighted windows \(branch.windowIDs.sorted())")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                        self?.branchOverlay.hide()
                    }
                case .failure(let error):
                    self.diagnostics.log("highlight_test_failed", ["error": error.localizedDescription])
                    self.updateStatus("BSP test failed: \(error.localizedDescription)")
                    NSSound.beep()
                }
            }
        }
    }

    func balanceCurrentSpace() {
        diagnostics.log("balance_ui_requested")
        updateStatus("BSP tools: Balancing current Space…")
        let yabai = yabai
        queryQueue.async { [weak self] in
            let result = Result { try yabai.balanceFocusedSpace() }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success:
                    self.diagnostics.log("balance_ui_succeeded")
                    self.updateStatus("BSP tools: Current Space balanced")
                case .failure(let error):
                    self.diagnostics.log("balance_ui_failed", ["error": error.localizedDescription])
                    self.updateStatus("Balance failed: \(error.localizedDescription)")
                    NSSound.beep()
                }
            }
        }
    }

    func undoLastWarp() {
        guard let record = lastUndoRecord else { return }
        lastUndoRecord = nil
        diagnostics.log("undo_ui_requested", ["source_window_id": record.sourceWindowID])
        updateStatus("BSP tools: Undoing last warp…")
        let yabai = yabai
        queryQueue.async { [weak self] in
            let result = Result { try yabai.undoWarp(record) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success:
                    self.diagnostics.log("undo_ui_succeeded")
                    self.updateStatus("BSP tools: Last warp undone")
                case .failure(let error):
                    self.diagnostics.log("undo_ui_failed", ["error": error.localizedDescription])
                    self.updateStatus("Undo failed: \(error.localizedDescription)")
                    NSSound.beep()
                }
            }
        }
    }

    fileprivate func receive(type: CGEventType, location: CGPoint, flags: CGEventFlags) {
        latestPointer = location
        currentModifiers = normalizedBSPModifiers(flags)
        if currentModifiers != lastLoggedModifiers {
            diagnostics.log("modifier_state_changed", [
                "event_type": Int(type.rawValue),
                "raw_flags": flags.rawValue,
                "normalized_flags": currentModifiers.rawValue,
                "pointer": location
            ])
            lastLoggedModifiers = currentModifiers
        }
        if type == .leftMouseDown || type == .leftMouseDragged || type == .leftMouseUp {
            diagnostics.log("mouse_button_event", [
                "event_type": Int(type.rawValue),
                "modifiers": currentModifiers.rawValue,
                "pointer": location,
                "suppressed": currentModifiers == bspDragModifiers
            ])
        }

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            diagnostics.log("event_tap_disabled", ["reason": type == .tapDisabledByTimeout ? "timeout" : "user_input"])
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            updateStatus("BSP tools: Mouse listener recovered")
            return
        }

        if currentModifiers == bspInspectModifiers {
            if dragToken != nil { cancelDrag(reason: "inspect_chord_selected") }
            if type == .mouseMoved || type == .flagsChanged {
                requestHoverIfNeeded()
            }
            return
        }

        if currentModifiers == bspDragModifiers {
            branchOverlay.hide()
            hoverGeneration += 1
            lastHoverWindowID = nil
            switch type {
            case .leftMouseDown: beginDrag(at: location)
            case .leftMouseDragged: updateDrag(at: location)
            case .leftMouseUp: finishDrag(at: location)
            default: break
            }
            return
        }

        if type == .flagsChanged || type == .mouseMoved {
            hideHover(reason: "inspect_modifiers_released")
        }
        if dragToken != nil && !dragIsFinalizing && currentModifiers != bspDragModifiers {
            cancelDrag(reason: "drag_modifiers_released")
        }
    }

    private func requestHoverIfNeeded() {
        let now = Date()
        guard !hoverQueryInFlight,
              now.timeIntervalSince(lastHoverQueryAt) >= 0.12 else { return }
        hoverQueryInFlight = true
        lastHoverQueryAt = now
        hoverGeneration += 1
        let generation = hoverGeneration
        let pointer = latestPointer
        diagnostics.log("hover_query_started", ["generation": generation, "pointer": pointer])
        queryBranch(at: pointer, purpose: "hover") { [weak self] result in
            guard let self else { return }
            self.hoverQueryInFlight = false
            guard generation == self.hoverGeneration,
                  self.currentModifiers == bspInspectModifiers else {
                self.diagnostics.log("hover_query_discarded", ["generation": generation])
                return
            }
            switch result {
            case .success(let selection):
                guard let branch = selection.branches.first else { return }
                self.branchOverlay.show(yabaiFrame: branch.frame, display: selection.display)
                if self.lastHoverWindowID != selection.windowID {
                    self.lastHoverWindowID = selection.windowID
                    self.diagnostics.log("hover_branch_shown", [
                        "window_id": selection.windowID,
                        "branch_window_ids": branch.windowIDs,
                        "branch_frame": branch.frame,
                        "pointer": pointer
                    ])
                    self.updateStatus("Inspecting nearest branch: \(branch.windowIDs.sorted())")
                }
            case .failure(let error):
                self.branchOverlay.hide()
                self.lastHoverWindowID = nil
                self.diagnostics.log("hover_query_failed", [
                    "generation": generation,
                    "pointer": pointer,
                    "error": error.localizedDescription
                ])
                self.updateStatus("Inspect: \(error.localizedDescription)")
            }
        }
    }

    private func hideHover(reason: String) {
        guard branchOverlay.isVisible || lastHoverWindowID != nil else { return }
        hoverGeneration += 1
        lastHoverWindowID = nil
        branchOverlay.hide()
        diagnostics.log("hover_hidden", ["reason": reason])
        updateStatus("BSP tools: Ready")
    }

    private func beginDrag(at point: CGPoint) {
        cancelDrag(reason: "new_drag")
        let token = UUID()
        dragToken = token
        dragMouseIsDown = true
        dragIsFinalizing = false
        latestPointer = point
        diagnostics.log("drag_started", ["token": token.uuidString, "pointer": point])
        updateStatus("BSP drag: Selecting source window…")
        queryBranch(at: point, purpose: "drag_source") { [weak self] result in
            guard let self,
                  self.dragToken == token,
                  self.dragMouseIsDown else { return }
            switch result {
            case .success(let selection):
                self.dragSource = selection
                self.sourceOverlay.show(yabaiFrame: selection.window.frame.rect, display: selection.display)
                self.diagnostics.log("drag_source_selected", [
                    "token": token.uuidString,
                    "window_id": selection.windowID,
                    "frame": selection.window.frame.rect,
                    "space": selection.space,
                    "display": selection.window.display
                ])
                self.updateStatus("BSP drag: Move over a target edge and release")
                self.requestDragTargetIfNeeded(force: true)
            case .failure(let error):
                self.diagnostics.log("drag_source_failed", [
                    "token": token.uuidString,
                    "error": error.localizedDescription
                ])
                self.cancelDrag(reason: "source_query_failed")
                self.updateStatus("BSP drag failed: \(error.localizedDescription)")
                NSSound.beep()
            }
        }
    }

    private func updateDrag(at point: CGPoint) {
        latestPointer = point
        guard dragToken != nil, dragMouseIsDown else { return }
        requestDragTargetIfNeeded(force: false)
    }

    private func requestDragTargetIfNeeded(force: Bool) {
        guard let token = dragToken,
              let source = dragSource,
              dragMouseIsDown,
              !dragTargetQueryInFlight else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastDragTargetQueryAt) >= 0.10 else { return }
        lastDragTargetQueryAt = now
        dragTargetQueryInFlight = true
        let queryPoint = latestPointer
        let yabai = yabai
        queryQueue.async { [weak self] in
            let result = Result { try yabai.tiledWindowAtMouse() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.dragTargetQueryInFlight = false
                guard self.dragToken == token,
                      self.dragMouseIsDown,
                      let currentSource = self.dragSource,
                      currentSource.windowID == source.windowID else { return }
                switch result {
                case .success(let target):
                    guard target.id != source.windowID,
                          target.space == source.space,
                          target.display == source.window.display else {
                        self.clearDragTarget(reason: "source_or_other_space")
                        return
                    }
                    let direction = BSPWarpDirection.nearestEdge(to: queryPoint, in: target.frame.rect)
                    let changed = self.dragTarget?.id != target.id || self.dragDirection != direction
                    self.dragTarget = target
                    self.dragDirection = direction
                    self.targetOverlay.show(
                        yabaiFrame: direction.previewFrame(in: target.frame.rect),
                        display: source.display
                    )
                    if changed {
                        self.diagnostics.log("drag_drop_zone_selected", [
                            "token": token.uuidString,
                            "source_window_id": source.windowID,
                            "target_window_id": target.id,
                            "direction": direction.rawValue,
                            "pointer": queryPoint,
                            "target_frame": target.frame.rect,
                            "preview_frame": direction.previewFrame(in: target.frame.rect)
                        ])
                        self.updateStatus("Drop: \(direction.rawValue) of window \(target.id)")
                    }
                case .failure(let error):
                    self.clearDragTarget(reason: "target_query_failed")
                    self.diagnostics.log("drag_target_query_failed", [
                        "token": token.uuidString,
                        "pointer": queryPoint,
                        "error": error.localizedDescription
                    ])
                }
            }
        }
    }

    private func finishDrag(at point: CGPoint) {
        latestPointer = point
        dragMouseIsDown = false
        guard let token = dragToken,
              let source = dragSource else {
            cancelDrag(reason: "released_without_valid_target")
            updateStatus("BSP drag cancelled: no valid target")
            return
        }
        dragIsFinalizing = true
        updateStatus("BSP drag: Verifying final drop target…")
        diagnostics.log("drag_final_target_query_started", [
            "token": token.uuidString,
            "source_window_id": source.windowID,
            "pointer": point,
            "preview_target_window_id": dragTarget?.id as Any,
            "preview_direction": dragDirection?.rawValue as Any
        ])
        let yabai = yabai
        queryQueue.async { [weak self] in
            let result = Result { try yabai.tiledWindowAtMouse() }
            DispatchQueue.main.async {
                guard let self,
                      self.dragToken == token,
                      self.dragIsFinalizing else { return }
                switch result {
                case .success(let target):
                    guard target.id != source.windowID,
                          target.space == source.space,
                          target.display == source.window.display else {
                        self.cancelDrag(reason: "invalid_final_target")
                        self.updateStatus("BSP drag cancelled: final target was not valid")
                        return
                    }
                    let direction = BSPWarpDirection.nearestEdge(to: point, in: target.frame.rect)
                    self.diagnostics.log("drag_final_target_verified", [
                        "token": token.uuidString,
                        "target_window_id": target.id,
                        "direction": direction.rawValue,
                        "target_frame": target.frame.rect,
                        "pointer": point
                    ])
                    self.commitWarp(token: token, source: source, target: target, direction: direction, point: point)
                case .failure(let error):
                    self.diagnostics.log("drag_final_target_failed", [
                        "token": token.uuidString,
                        "error": error.localizedDescription
                    ])
                    self.cancelDrag(reason: "final_target_query_failed")
                    self.updateStatus("BSP drag cancelled: \(error.localizedDescription)")
                    NSSound.beep()
                }
            }
        }
    }

    private func commitWarp(
        token: UUID,
        source: BSPBranchSelection,
        target: BSPWindowSnapshot,
        direction: BSPWarpDirection,
        point: CGPoint
    ) {
        diagnostics.log("drag_drop_committed", [
            "token": token.uuidString,
            "source_window_id": source.windowID,
            "target_window_id": target.id,
            "direction": direction.rawValue,
            "pointer": point
        ])
        dragToken = nil
        dragIsFinalizing = false
        dragSource = nil
        dragTarget = nil
        dragDirection = nil
        dragTargetQueryInFlight = false
        sourceOverlay.hide()
        targetOverlay.hide()
        updateStatus("BSP tools: Warping window…")

        let yabai = yabai
        queryQueue.async { [weak self] in
            let result = Result { try yabai.warp(source: source, target: target, direction: direction) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let record):
                    self.lastUndoRecord = record
                    self.diagnostics.log("drag_warp_succeeded", [
                        "source_window_id": source.windowID,
                        "target_window_id": target.id,
                        "direction": direction.rawValue,
                        "exact_undo_available": record != nil
                    ])
                    self.updateStatus(
                        record == nil
                            ? "BSP tools: Window warped; exact Undo unavailable for the old branch"
                            : "BSP tools: Window warped; Undo is available"
                    )
                case .failure(let error):
                    self.lastUndoRecord = nil
                    self.diagnostics.log("drag_warp_failed", [
                        "source_window_id": source.windowID,
                        "target_window_id": target.id,
                        "direction": direction.rawValue,
                        "error": error.localizedDescription
                    ])
                    self.updateStatus("Warp failed: \(error.localizedDescription)")
                    NSSound.beep()
                }
            }
        }
    }

    private func clearDragTarget(reason: String) {
        if dragTarget != nil || dragDirection != nil {
            diagnostics.log("drag_drop_zone_cleared", ["reason": reason])
        }
        dragTarget = nil
        dragDirection = nil
        targetOverlay.hide()
    }

    private func cancelDrag(reason: String) {
        guard dragToken != nil || dragSource != nil || dragTarget != nil else { return }
        diagnostics.log("drag_cancelled", [
            "reason": reason,
            "token": dragToken?.uuidString ?? "none",
            "source_window_id": dragSource?.windowID as Any,
            "target_window_id": dragTarget?.id as Any
        ])
        dragToken = nil
        dragMouseIsDown = false
        dragIsFinalizing = false
        dragSource = nil
        dragTarget = nil
        dragDirection = nil
        dragTargetQueryInFlight = false
        sourceOverlay.hide()
        targetOverlay.hide()
    }

    private func cancelInteractions(reason: String) {
        hideHover(reason: reason)
        cancelDrag(reason: reason)
        branchOverlay.hide()
        sourceOverlay.hide()
        targetOverlay.hide()
    }

    private func queryBranch(
        at pointer: CGPoint,
        purpose: String,
        completion: @escaping (Result<BSPBranchSelection, Error>) -> Void
    ) {
        let yabai = yabai
        let diagnostics = diagnostics
        queryQueue.async {
            let started = Date()
            let result = Result { try yabai.bspBranchesAtMouse() }
            diagnostics.log("branch_query_completed", [
                "purpose": purpose,
                "requested_pointer": pointer,
                "duration_ms": Int(Date().timeIntervalSince(started) * 1000),
                "succeeded": (try? result.get()) != nil
            ])
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func updateStatus(_ newStatus: String) {
        guard status != newStatus else { return }
        status = newStatus
        statusHandler(newStatus)
    }

}

private let bspEventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<BranchHighlightController>.fromOpaque(userInfo).takeUnretainedValue()
    let location = event.location
    let flags = event.flags
    Task { @MainActor in
        controller.receive(type: type, location: location, flags: flags)
    }

    let modifiers = normalizedBSPModifiers(flags)
    let isDragMouseEvent = type == .leftMouseDown || type == .leftMouseDragged || type == .leftMouseUp
    if isDragMouseEvent && modifiers == bspDragModifiers {
        return nil
    }
    return Unmanaged.passUnretained(event)
}

@MainActor
private final class BranchOverlayPanel {
    private let panel: NSPanel
    private let overlayView: BranchOverlayView

    var isVisible: Bool { panel.isVisible }

    init(strokeColor: NSColor, fillColor: NSColor, lineWidth: CGFloat) {
        overlayView = BranchOverlayView(strokeColor: strokeColor, fillColor: fillColor, lineWidth: lineWidth)
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = overlayView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
    }

    func show(yabaiFrame: CGRect, display: BSPDisplaySnapshot) {
        let clippedFrame = yabaiFrame.intersection(display.frame.rect)
        guard !clippedFrame.isNull, !clippedFrame.isEmpty else {
            hide()
            return
        }
        guard let screen = NSScreen.screens.first(where: { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return number.uint32Value == display.id
        }), let frame = BSPCoordinateConverter.appKitRect(
            fromYabai: clippedFrame,
            yabaiDisplayFrame: display.frame.rect,
            appKitScreenFrame: screen.frame
        ), frame.width > 0, frame.height > 0 else {
            hide()
            return
        }
        panel.setFrame(frame, display: true)
        overlayView.needsDisplay = true
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}

private final class BranchOverlayView: NSView {
    private let strokeColor: NSColor
    private let fillColor: NSColor
    private let lineWidth: CGFloat

    init(strokeColor: NSColor, fillColor: NSColor, lineWidth: CGFloat) {
        self.strokeColor = strokeColor
        self.fillColor = fillColor
        self.lineWidth = lineWidth
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        fillColor.setFill()
        bounds.fill()
        strokeColor.setStroke()
        let inset = lineWidth / 2
        let path = NSBezierPath(rect: bounds.insetBy(dx: inset, dy: inset))
        path.lineWidth = lineWidth
        path.stroke()
    }
}
