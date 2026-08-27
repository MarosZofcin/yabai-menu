import Foundation
import CoreGraphics

/// Persistent JSON-lines diagnostics for interactions that cannot be observed
/// on the CI runner. Every record is independently parseable and includes a
/// UTC timestamp, app version, and event-specific fields.
final class DiagnosticLogger: @unchecked Sendable {
    static let shared = DiagnosticLogger()

    private let queue = DispatchQueue(label: "sk.maroszofcin.YabaiMenu.diagnostics")
    private let logURL: URL
    private let encoderDateFormatter = ISO8601DateFormatter()

    private init() {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Yabai Menu", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        logURL = directory.appendingPathComponent("interaction.jsonl")
        Self.rotateIfNeeded(logURL)
    }

    func log(_ event: String, _ details: [String: Any] = [:]) {
        let timestamp = encoderDateFormatter.string(from: Date())
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        queue.async { [logURL] in
            Self.rotateIfNeeded(logURL)
            var record: [String: Any] = [
                "timestamp": timestamp,
                "event": event,
                "app_version": version,
                "app_build": build
            ]
            details.forEach { record[$0.key] = Self.jsonValue($0.value) }
            guard JSONSerialization.isValidJSONObject(record),
                  let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
                  var line = String(data: data, encoding: .utf8) else { return }
            line.append("\n")
            let lineData = Data(line.utf8)
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: lineData)
                return
            }
            guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: lineData)
            } catch {
                // Logging must never affect window management.
            }
        }
    }

    func exportReport(systemSnapshot: String) throws -> URL {
        let logContent = queue.sync {
            let previousURL = logURL.deletingLastPathComponent().appendingPathComponent("interaction.previous.jsonl")
            let previous = (try? String(contentsOf: previousURL, encoding: .utf8)) ?? "<no previous segment>\n"
            let current = (try? String(contentsOf: logURL, encoding: .utf8)) ?? "<no current interaction log>\n"
            return "--- PREVIOUS ROTATED SEGMENT ---\n\(previous)\n--- CURRENT SEGMENT ---\n\(current)"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let filename = "Yabai-Menu-Diagnostics-\(formatter.string(from: Date())).txt"
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        let destination = desktop.appendingPathComponent(filename)
        let report = """
        YABAI MENU DIAGNOSTIC REPORT
        Generated: \(encoderDateFormatter.string(from: Date()))

        ===== SYSTEM AND CURRENT YABAI STATE =====
        \(systemSnapshot)

        ===== INTERACTION LOG (JSON LINES) =====
        \(logContent)
        """
        try report.write(to: destination, atomically: true, encoding: .utf8)
        log("diagnostic_report_exported", ["path": destination.path])
        return destination
    }

    private static func rotateIfNeeded(_ logURL: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue > 16 * 1024 * 1024 else { return }
        let previous = logURL.deletingLastPathComponent().appendingPathComponent("interaction.previous.jsonl")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: logURL, to: previous)
    }

    private static func jsonValue(_ value: Any) -> Any {
        switch value {
        case let value as String: return value
        case let value as Bool: return value
        case let value as Int: return value
        case let value as UInt32: return Int(value)
        case let value as UInt64: return String(value)
        case let value as Double: return value
        case let value as [Any]: return value.map(jsonValue)
        case let value as [String: Any]: return value.mapValues(jsonValue)
        case let value as Set<Int>: return value.sorted()
        case let value as CGPoint:
            return ["x": value.x, "y": value.y]
        case let value as CGSize:
            return ["w": value.width, "h": value.height]
        case let value as CGRect:
            return ["x": value.minX, "y": value.minY, "w": value.width, "h": value.height]
        default: return String(describing: value)
        }
    }
}
