import Foundation

struct FloatingApp: Hashable, Sendable {
    let name: String
    let bundleIdentifier: String?
    let appPattern: String
    let ruleLabel: String
}

struct DisplayState: Equatable, Sendable {
    let index: Int
    let name: String
    let layout: String
}

struct YabaiSnapshot: Equatable, Sendable {
    let isRunning: Bool
    let displays: [DisplayState]
}

struct RunningApplication: Equatable, Sendable {
    let name: String
    let bundleIdentifier: String?
}

struct CommandResult: Sendable {
    let status: Int32
    let standardOutput: String
    let standardError: String

    var succeeded: Bool { status == 0 }
    var usefulError: String {
        let error = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        if !error.isEmpty { return error }
        let output = standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? "Command failed with status \(status)." : output
    }
}

enum AppError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        }
    }
}

enum GitHubSyncState: Equatable, Sendable {
    case unknown
    case syncing
    case synced
    case localChanges
    case conflict
    case error

    var title: String {
        switch self {
        case .unknown: return "Not checked"
        case .syncing: return "Syncing…"
        case .synced: return "Synced"
        case .localChanges: return "Local changes"
        case .conflict: return "Conflict"
        case .error: return "Not synchronized"
        }
    }
}

struct GitSyncReport: Sendable {
    let message: String
    let synchronizedAt: Date
    let configChanged: Bool
}

enum GitSyncFailure: LocalizedError {
    case localChanges(String)
    case conflict(String)
    case error(String)

    var syncState: GitHubSyncState {
        switch self {
        case .localChanges: return .localChanges
        case .conflict: return .conflict
        case .error: return .error
        }
    }

    var errorDescription: String? {
        switch self {
        case .localChanges(let message), .conflict(let message), .error(let message):
            return message
        }
    }
}

