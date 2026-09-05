import Foundation

struct GitSyncController: Sendable {
    let repositoryURL: URL
    let managedFileURL: URL
    private let gitURL = URL(fileURLWithPath: "/usr/bin/git")

    func sync() throws -> GitSyncReport {
        guard FileManager.default.fileExists(atPath: repositoryURL.appendingPathComponent(".git").path) else {
            throw GitSyncFailure.error("\(repositoryURL.path) is not a Git repository.")
        }

        let before = try? Data(contentsOf: managedFileURL)
        let autoCommitted = try commitManagedFile(message: "Update yabai configuration")
        let changedPaths = try workingTreeChanges()
        guard changedPaths.isEmpty else {
            let preview = changedPaths.prefix(3).joined(separator: ", ")
            throw GitSyncFailure.localChanges("Sync paused: uncommitted changes in \(preview)")
        }

        try requireGit(["fetch", "--prune"], failurePrefix: "GitHub fetch failed")
        let upstream = try requireGit(
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
            failurePrefix: "No upstream branch is configured"
        ).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)

        let countsResult = try requireGit(
            ["rev-list", "--left-right", "--count", "HEAD...\(upstream)"],
            failurePrefix: "Could not compare the local and GitHub branches"
        )
        let counts = countsResult.standardOutput.split(whereSeparator: { $0.isWhitespace }).compactMap { Int($0) }
        guard counts.count == 2 else {
            throw GitSyncFailure.error("Could not read the Git branch state.")
        }
        let ahead = counts[0]
        let behind = counts[1]

        guard let plan = try RuntimeController.shared.call("gitPlan", input: ["ahead": ahead, "behind": behind]) as? [String: String],
              let integration = plan["integration"],
              ["rebase", "fastForward", "none"].contains(integration) else {
            throw GitSyncFailure.error("Runtime returned an unsupported Git integration plan.")
        }
        // Safety remains native: do not allow a runtime to overwrite local
        // commits or skip integration of a behind branch before pushing.
        guard (behind == 0 && integration == "none") ||
              (behind > 0 && integration == "rebase") ||
              (behind > 0 && ahead == 0 && integration == "fastForward") else {
            throw GitSyncFailure.error("Runtime Git plan violates host safety constraints.")
        }
        if integration == "rebase" {
            let pull = git(["pull", "--rebase"])
            guard pull.succeeded else {
                abortRebaseIfNeeded()
                throw GitSyncFailure.conflict("GitHub conflict: local commits were preserved. \(pull.usefulError)")
            }
        } else if integration == "fastForward" {
            try requireGit(["merge", "--ff-only", upstream], failurePrefix: "Could not fast-forward from GitHub")
        }

        let remainingAhead = try aheadCount(upstream: upstream)
        if remainingAhead > 0 {
            try requireGit(["push"], failurePrefix: "GitHub push failed")
        }

        let after = try? Data(contentsOf: managedFileURL)
        let message = (try? RuntimeController.shared.call("syncMessage", input: ["autoCommitted": autoCommitted])) as? String
        return GitSyncReport(
            message: message ?? "Synchronized with GitHub",
            synchronizedAt: Date(),
            configChanged: before != after
        )
    }

    func commitManagedFile(message: String = "Update yabai floating apps") throws -> Bool {
        let relativePath = try managedRelativePath()
        let changes = try workingTreeChanges()
        let unrelated = changes.filter { $0 != relativePath }
        guard unrelated.isEmpty else {
            throw GitSyncFailure.localChanges("Could not commit because dotfiles also contains changes in \(unrelated.prefix(3).joined(separator: ", "))")
        }

        try validateManagedFile()
        try requireGit(["add", "--", relativePath], failurePrefix: "Could not stage yabairc")
        let staged = git(["diff", "--cached", "--quiet", "--", relativePath])
        if staged.status == 0 { return false }
        guard staged.status == 1 else {
            throw GitSyncFailure.error("Could not inspect the staged yabairc: \(staged.usefulError)")
        }
        try requireGit(
            ["commit", "-m", message, "--", relativePath],
            failurePrefix: "Could not commit yabairc"
        )
        return true
    }

    static func pathFromStatusLine(_ line: String) -> String? {
        guard line.count >= 4 else { return nil }
        let start = line.index(line.startIndex, offsetBy: 3)
        let path = String(line[start...])
        if let arrow = path.range(of: " -> ") {
            return String(path[arrow.upperBound...])
        }
        if path.hasPrefix("\"") && path.hasSuffix("\"") {
            return String(path.dropFirst().dropLast())
        }
        return path
    }

    private func validateManagedFile() throws {
        let result = ProcessRunner.run(
            URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-n", managedFileURL.path]
        )
        guard result.succeeded else {
            throw GitSyncFailure.localChanges(
                "yabairc was not committed because its shell syntax is invalid: \(result.usefulError)"
            )
        }
    }

    private func workingTreeChanges() throws -> [String] {
        let result = try requireGit(
            ["status", "--porcelain=v1", "--untracked-files=all"],
            failurePrefix: "Could not inspect dotfiles"
        )
        return result.standardOutput.split(separator: "\n").map(String.init).compactMap(Self.pathFromStatusLine)
    }

    private func managedRelativePath() throws -> String {
        let prefix = repositoryURL.standardizedFileURL.path + "/"
        let path = managedFileURL.standardizedFileURL.path
        guard path.hasPrefix(prefix) else {
            throw GitSyncFailure.error("The managed yabairc is outside the dotfiles repository.")
        }
        return String(path.dropFirst(prefix.count))
    }

    private func aheadCount(upstream: String) throws -> Int {
        let result = try requireGit(
            ["rev-list", "--left-right", "--count", "HEAD...\(upstream)"],
            failurePrefix: "Could not verify the synchronized branch"
        )
        return Int(result.standardOutput.split(whereSeparator: { $0.isWhitespace }).first ?? "0") ?? 0
    }

    private func abortRebaseIfNeeded() {
        let gitDirectory = repositoryURL.appendingPathComponent(".git")
        let isRebasing = FileManager.default.fileExists(atPath: gitDirectory.appendingPathComponent("rebase-merge").path)
            || FileManager.default.fileExists(atPath: gitDirectory.appendingPathComponent("rebase-apply").path)
        if isRebasing {
            _ = git(["rebase", "--abort"])
        }
    }

    private func git(_ arguments: [String]) -> CommandResult {
        ProcessRunner.run(gitURL, arguments: arguments, currentDirectory: repositoryURL)
    }

    @discardableResult
    private func requireGit(_ arguments: [String], failurePrefix: String) throws -> CommandResult {
        let result = git(arguments)
        guard result.succeeded else {
            throw GitSyncFailure.error("\(failurePrefix): \(result.usefulError)")
        }
        return result
    }
}
