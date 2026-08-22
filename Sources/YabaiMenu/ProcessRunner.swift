import Foundation

enum ProcessRunner {
    static func run(
        _ executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil
    ) -> CommandResult {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        var processEnvironment = ProcessInfo.processInfo.environment
        processEnvironment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment?.forEach { processEnvironment[$0.key] = $0.value }
        process.environment = processEnvironment

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return CommandResult(status: -1, standardOutput: "", standardError: error.localizedDescription)
        }

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return CommandResult(status: process.terminationStatus, standardOutput: output, standardError: error)
    }
}
