import Foundation

enum SelfTests {
    static func run() throws {
        let identifier = YabaiController.stableIdentifier(name: "Google Chrome", bundleIdentifier: "com.google.Chrome")
        guard identifier == YabaiController.stableIdentifier(name: "Google Chrome", bundleIdentifier: "com.google.Chrome"), identifier.count == 16 else {
            throw AppError.message("Stable yabai rule identifiers failed.")
        }

        guard GitSyncController.pathFromStatusLine(" M yabai/floating-apps.json") == "yabai/floating-apps.json",
              GitSyncController.pathFromStatusLine("?? yabai/floating-apps.json") == "yabai/floating-apps.json",
              GitSyncController.pathFromStatusLine("R  old.json -> yabai/floating-apps.json") == "yabai/floating-apps.json" else {
            throw AppError.message("Git status path parsing failed.")
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let yabairc = directory.appendingPathComponent("yabairc")
        let source = """
        #!/usr/bin/env sh
        # --- Okná mimo tilingu ---
        for LABEL in float-finder float-whatsapp; do
            yabai -m rule --remove "$LABEL" 2>/dev/null || true
        done
        yabai -m rule --add label=float-finder app="^Finder$" manage=off
        yabai -m rule --add label=float-whatsapp app="^.*WhatsApp$" manage=off
        yabai -m rule --apply
        """
        try source.write(to: yabairc, atomically: true, encoding: .utf8)
        let store = YabaircBlacklistStore(fileURL: yabairc)
        let existing = try store.load()
        guard existing.map(\.name) == ["Finder", "WhatsApp"] else {
            throw AppError.message("Existing yabairc rule parsing failed.")
        }
        let change = try store.adding(RunningApplication(name: "Google Chrome", bundleIdentifier: "com.google.Chrome"))
        guard change.new.map(\.name) == ["Finder", "Google Chrome", "WhatsApp"] else {
            throw AppError.message("yabairc blacklist editing failed.")
        }
        let migrated = try String(contentsOf: yabairc, encoding: .utf8)
        guard migrated.contains(YabaircBlacklistStore.beginMarker),
              migrated.contains(YabaircBlacklistStore.endMarker),
              migrated.contains("# --- Okná mimo tilingu ---"),
              migrated.components(separatedBy: "manage=off").count - 1 == 3 else {
            throw AppError.message("yabairc managed-block migration failed.")
        }

        try testLocalGitSynchronization(in: directory)
    }

    private static func testLocalGitSynchronization(in root: URL) throws {
        let remote = root.appendingPathComponent("remote.git")
        let seed = root.appendingPathComponent("seed")
        let client = root.appendingPathComponent("client")
        let verifier = root.appendingPathComponent("verifier")

        try requireGit(["init", "--bare", "--initial-branch=main", remote.path], in: root)
        try requireGit(["init", "--initial-branch=main", seed.path], in: root)
        try requireGit(["config", "user.name", "Yabai Menu Tests"], in: seed)
        try requireGit(["config", "user.email", "yabai-menu-tests@localhost"], in: seed)
        let seedYabaiDirectory = seed.appendingPathComponent("yabai")
        try FileManager.default.createDirectory(at: seedYabaiDirectory, withIntermediateDirectories: true)
        try "#!/usr/bin/env sh\n".write(
            to: seedYabaiDirectory.appendingPathComponent("yabairc"),
            atomically: true,
            encoding: .utf8
        )
        try requireGit(["add", "."], in: seed)
        try requireGit(["commit", "-m", "Initial"], in: seed)
        try requireGit(["remote", "add", "origin", remote.path], in: seed)
        try requireGit(["push", "-u", "origin", "main"], in: seed)
        try requireGit(["clone", remote.path, client.path], in: root)
        try requireGit(["config", "user.name", "Yabai Menu Tests"], in: client)
        try requireGit(["config", "user.email", "yabai-menu-tests@localhost"], in: client)

        let clientYabairc = client.appendingPathComponent("yabai/yabairc")
        let clientStore = YabaircBlacklistStore(fileURL: clientYabairc)
        _ = try clientStore.adding(RunningApplication(name: "Finder", bundleIdentifier: "com.apple.finder"))
        let sync = GitSyncController(repositoryURL: client, managedFileURL: clientYabairc)
        guard try sync.commitManagedFile() else {
            throw AppError.message("Git sync did not detect the managed yabairc change.")
        }
        _ = try sync.sync()

        try requireGit(["clone", remote.path, verifier.path], in: root)
        let verified = try String(contentsOf: verifier.appendingPathComponent("yabai/yabairc"), encoding: .utf8)
        guard verified.contains("com.apple.finder") else {
            throw AppError.message("Git sync did not push the yabairc change.")
        }
    }

    private static func requireGit(_ arguments: [String], in directory: URL) throws {
        let result = ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/git"),
            arguments: arguments,
            currentDirectory: directory
        )
        guard result.succeeded else {
            throw AppError.message("Git self-test failed: \(result.usefulError)")
        }
    }
}
