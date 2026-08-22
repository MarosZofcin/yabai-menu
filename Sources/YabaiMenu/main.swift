import AppKit

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
