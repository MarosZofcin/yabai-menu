import AppKit

/// Geometry-first window movement. This controller deliberately has no event
/// tap: a menu command supplies a human direction and the runtime derives the
/// neighbouring visual container from yabai's current window geometry.
@MainActor
final class SmartMoveController {
    private let yabai: YabaiController
    private let diagnostics: DiagnosticLogger
    private let statusHandler: (String) -> Void
    private let queue = DispatchQueue(label: "sk.maroszofcin.YabaiMenu.smart-move", qos: .userInitiated)

    init(yabai: YabaiController, diagnostics: DiagnosticLogger, statusHandler: @escaping (String) -> Void) {
        self.yabai = yabai
        self.diagnostics = diagnostics
        self.statusHandler = statusHandler
    }

    func move(_ direction: SmartMoveDirection) {
        statusHandler("Smart Move: finding the (direction.label.lowercased()) container…")
        let yabai = yabai
        let diagnostics = diagnostics
        queue.async { [weak self] in
            let result = Result { try yabai.smartMove(direction: direction) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let target):
                    diagnostics.log("smart_move_succeeded", ["direction": direction.rawValue, "target_window_id": target])
                    self.statusHandler("Smart Move: moved (direction.label.lowercased())")
                case .failure(let error):
                    diagnostics.log("smart_move_failed", ["direction": direction.rawValue, "error": error.localizedDescription])
                    self.statusHandler("Smart Move: (error.localizedDescription)")
                    NSSound.beep()
                }
            }
        }
    }
}

enum SmartMoveDirection: String, CaseIterable, Sendable {
    case left, right, up, down
    var label: String { rawValue.capitalized }
    var yabaiInsertion: String {
        switch self { case .left: return "west"; case .right: return "east"; case .up: return "north"; case .down: return "south" }
    }
}
