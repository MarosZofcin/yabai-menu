import Foundation

enum ProcessRunner {
    static func run(
        _ executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 60
    ) -> CommandResult {
        let process = Process()
        // File-backed capture avoids deadlock when a child fills a pipe before
        // waitUntilExit returns (notably Git and runtime regression tests).
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("YabaiProcess-" + UUID().uuidString)
        do { try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { return CommandResult(status: -1, standardOutput: "", standardError: error.localizedDescription) }
        defer { try? fm.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("stdout")
        let errorURL = directory.appendingPathComponent("stderr")
        fm.createFile(atPath: outputURL.path, contents: nil)
        fm.createFile(atPath: errorURL.path, contents: nil)
        guard let outputHandle = try? FileHandle(forWritingTo: outputURL),
              let errorHandle = try? FileHandle(forWritingTo: errorURL) else {
            return CommandResult(status: -1, standardOutput: "", standardError: "Cannot capture child output")
        }
        defer { try? outputHandle.close(); try? errorHandle.close() }

        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        process.standardInput = FileHandle.nullDevice

        var processEnvironment = ProcessInfo.processInfo.environment
        processEnvironment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        processEnvironment["GIT_TERMINAL_PROMPT"] = "0"
        environment?.forEach { processEnvironment[$0.key] = $0.value }
        process.environment = processEnvironment

        do {
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning {
                process.terminate()
                let grace = Date().addingTimeInterval(0.25)
                while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.01) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                return CommandResult(status: -1, standardOutput: "", standardError: "Operation timed out")
            }
            process.waitUntilExit()
        } catch {
            return CommandResult(status: -1, standardOutput: "", standardError: error.localizedDescription)
        }

        let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        let error = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
        return CommandResult(status: process.terminationStatus, standardOutput: output, standardError: error)
    }
}
