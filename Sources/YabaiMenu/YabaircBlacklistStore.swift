import Foundation

struct YabaircBlacklistStore: Sendable {
    static let beginMarker = "# --- YABAI MENU: FLOATING APPS BEGIN ---"
    static let endMarker = "# --- YABAI MENU: FLOATING APPS END ---"

    let fileURL: URL

    func load() throws -> [FloatingApp] {
        let source = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = source.components(separatedBy: "\n")
        let relevantLines: ArraySlice<String>
        let begin = lines.firstIndex(of: Self.beginMarker)
        let end = lines.firstIndex(of: Self.endMarker)

        if begin != nil || end != nil {
            guard let begin, let end, begin < end else {
                throw AppError.message("The managed floating-app block in yabairc has incomplete or misplaced markers.")
            }
            relevantLines = lines[(begin + 1)..<end]
        } else {
            relevantLines = lines[...]
        }

        return relevantLines.compactMap(Self.parseRule)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func adding(_ application: RunningApplication) throws -> (old: [FloatingApp], new: [FloatingApp]) {
        let old = try load()
        if contains(old, application: application) { return (old, old) }
        var updated = old
        updated.append(Self.makeRule(for: application))
        try save(updated)
        return (old, try load())
    }

    func removing(_ app: FloatingApp) throws -> (old: [FloatingApp], new: [FloatingApp]) {
        let old = try load()
        let updated = old.filter { $0 != app }
        try save(updated)
        return (old, try load())
    }

    func contains(_ apps: [FloatingApp], application: RunningApplication) -> Bool {
        apps.contains { entry in
            if let lhs = entry.bundleIdentifier, let rhs = application.bundleIdentifier {
                return lhs == rhs
            }
            return entry.name.caseInsensitiveCompare(application.name) == .orderedSame
        }
    }

    static func makeRule(for application: RunningApplication) -> FloatingApp {
        let pattern = "^\(NSRegularExpression.escapedPattern(for: application.name))$"
        return FloatingApp(
            name: application.name,
            bundleIdentifier: application.bundleIdentifier,
            appPattern: pattern,
            ruleLabel: YabaiController.managedRulePrefix + YabaiController.stableIdentifier(
                name: application.name,
                bundleIdentifier: application.bundleIdentifier
            )
        )
    }

    static func parseRule(_ line: String) -> FloatingApp? {
        guard line.contains("yabai"), line.contains("rule"), line.contains("--add"), line.contains("manage=off"),
              let pattern = shellValue(for: "app", in: line),
              let parsedLabel = shellValue(for: "label", in: line) else { return nil }

        let bundleIdentifier: String?
        if let range = line.range(of: "# yabai-menu-bundle-id=") {
            let value = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            bundleIdentifier = value.isEmpty ? nil : value
        } else {
            bundleIdentifier = nil
        }

        return FloatingApp(
            name: displayName(from: pattern),
            bundleIdentifier: bundleIdentifier,
            appPattern: pattern,
            ruleLabel: parsedLabel
        )
    }

    private func save(_ apps: [FloatingApp]) throws {
        let original = try String(contentsOf: fileURL, encoding: .utf8)
        var lines = original.components(separatedBy: "\n")
        let normalized = apps.map(Self.normalizedRule)
            .reduce(into: [FloatingApp]()) { result, app in
                if !result.contains(where: { $0.appPattern == app.appPattern }) { result.append(app) }
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let block = Self.generatedBlock(for: normalized)
        let begin = lines.firstIndex(of: Self.beginMarker)
        let end = lines.firstIndex(of: Self.endMarker)

        if begin != nil || end != nil {
            guard let begin, let end, begin < end else {
                throw AppError.message("The managed floating-app block in yabairc has incomplete or misplaced markers; it was not changed.")
            }
            lines.replaceSubrange(begin...end, with: block)
        } else {
            let legacyIndexes = lines.indices.filter { Self.parseRule(lines[$0]) != nil }
            if let firstRule = legacyIndexes.first, let lastRule = legacyIndexes.last {
                var start = firstRule
                var end = lastRule
                let lowerBound = max(0, firstRule - 12)
                if firstRule > 0 {
                    for index in stride(from: firstRule - 1, through: lowerBound, by: -1) {
                        if lines[index].contains("for LABEL in"), lines[index..<firstRule].contains(where: { $0.trimmingCharacters(in: .whitespaces) == "done" }) {
                            start = index
                            break
                        }
                        if lines[index].hasPrefix("# ---") { break }
                    }
                }
                let upperBound = min(lines.count - 1, lastRule + 5)
                if lastRule < upperBound {
                    for index in (lastRule + 1)...upperBound where lines[index].contains("yabai -m rule --apply") {
                        end = index
                        break
                    }
                }
                lines.replaceSubrange(start...end, with: block)
            } else {
                while lines.last?.isEmpty == true { lines.removeLast() }
                lines.append("")
                lines.append(contentsOf: block)
            }
        }

        var updated = lines.joined(separator: "\n")
        if !updated.hasSuffix("\n") { updated.append("\n") }
        try validateShell(updated)

        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        try updated.data(using: .utf8)?.write(to: fileURL, options: .atomic)
        if let permissions = attributes?[.posixPermissions] {
            try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: fileURL.path)
        }
    }

    private func validateShell(_ source: String) throws {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("yabairc-\(UUID().uuidString).sh")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try source.write(to: temporaryURL, atomically: true, encoding: .utf8)
        let result = ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-n", temporaryURL.path])
        guard result.succeeded else {
            throw AppError.message("The updated yabairc did not pass shell syntax validation: \(result.usefulError)")
        }
    }

    private static func normalizedRule(_ app: FloatingApp) -> FloatingApp {
        FloatingApp(
            name: app.name,
            bundleIdentifier: app.bundleIdentifier,
            appPattern: app.appPattern,
            ruleLabel: YabaiController.managedRulePrefix + YabaiController.stableIdentifier(
                name: app.name,
                bundleIdentifier: app.bundleIdentifier
            )
        )
    }

    private static func generatedBlock(for apps: [FloatingApp]) -> [String] {
        var lines = [
            beginMarker,
            "# Managed by Yabai Menu. This is the single source of truth for floating apps."
        ]
        if apps.isEmpty {
            lines.append("# No floating applications configured.")
        } else {
            let labels = apps.map(\.ruleLabel).joined(separator: " ")
            lines.append("for LABEL in \(labels); do")
            lines.append("    yabai -m rule --remove \"$LABEL\" 2>/dev/null || true")
            lines.append("done")
            lines.append("")
            for app in apps {
                var rule = "yabai -m rule --add label=\(shellQuote(app.ruleLabel)) app=\(shellQuote(app.appPattern)) manage=off"
                if let bundleIdentifier = app.bundleIdentifier {
                    rule += " # yabai-menu-bundle-id=\(bundleIdentifier)"
                }
                lines.append(rule)
            }
            lines.append("")
            lines.append("yabai -m rule --apply")
        }
        lines.append(endMarker)
        return lines
    }

    private static func shellQuote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
        return "\"\(escaped)\""
    }

    private static func shellValue(for key: String, in line: String) -> String? {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let pattern = "(?:^|\\s)\(escapedKey)=(?:\"((?:\\\\.|[^\"])*)\"|'([^']*)'|([^\\s#]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        for index in 1...3 where match.range(at: index).location != NSNotFound {
            guard let range = Range(match.range(at: index), in: line) else { continue }
            return unescapeDoubleQuoted(String(line[range]))
        }
        return nil
    }

    private static func unescapeDoubleQuoted(_ value: String) -> String {
        var result = ""
        var escaping = false
        for character in value {
            if escaping {
                if character == "\\" || character == "\"" || character == "$" || character == "`" {
                    result.append(character)
                } else {
                    result.append("\\")
                    result.append(character)
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        if escaping { result.append("\\") }
        return result
    }

    private static func displayName(from pattern: String) -> String {
        var name = pattern
        if name.hasPrefix("^") { name.removeFirst() }
        if name.hasPrefix(".*") { name.removeFirst(2) }
        if name.hasSuffix("$") { name.removeLast() }
        var literalName = ""
        var escaping = false
        for character in name {
            if escaping {
                literalName.append(character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                literalName.append(character)
            }
        }
        if escaping { literalName.append("\\") }
        name = literalName
        return name.isEmpty ? pattern : name
    }
}

