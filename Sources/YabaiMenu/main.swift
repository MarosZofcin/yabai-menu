import AppKit

if let index = CommandLine.arguments.firstIndex(of: "--runtime-evaluate"),
   CommandLine.arguments.indices.contains(index + 1) {
    do {
        try RuntimeController.runWorker(path: CommandLine.arguments[index + 1])
        exit(EXIT_SUCCESS)
    } catch {
        fputs("Runtime worker: \(error.localizedDescription)\n", stderr)
        exit(EXIT_FAILURE)
    }
}

if CommandLine.arguments.contains("--self-test") {
    do {
        try SelfTests.run()
        print("All self-tests passed.")
        exit(EXIT_SUCCESS)
    } catch {
        fputs("Self-test failed: \(error.localizedDescription)\n", stderr)
        exit(EXIT_FAILURE)
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
