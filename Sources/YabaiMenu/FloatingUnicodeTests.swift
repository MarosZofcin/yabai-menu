import Foundation
import Darwin

extension SelfTests {
    static func testFloatingUnicode(in directory: URL) throws {
        let forms = try FloatingNamePattern.forms()
        let nfc = "Syst\u{00e9}mov\u{00e9} nastavenia"
        let nfd = nfc.decomposedStringWithCanonicalMapping
        let mixed = "Syste\u{0301}mov\u{00e9} nastavenia"
        let pattern = try FloatingNamePattern.make(nfd, forms: forms)
        guard pattern.utf8.elementsEqual(try FloatingNamePattern.make(nfc, forms: forms).utf8),
              posixMatch(pattern, nfc), posixMatch(pattern, nfd), posixMatch(pattern, mixed),
              !posixMatch(pattern, "Systemove nastavenia"),
              !posixMatch(pattern, nfc + " Helper") else {
            throw AppError.message("POSIX floating Unicode equivalence regression.")
        }
        let special = "Caf\u{00e9} [QA].+(x)$ \\\"'`"
        let escaped = try FloatingNamePattern.make(special, forms: forms)
        guard posixMatch(escaped, special),
              posixMatch(escaped, special.decomposedStringWithCanonicalMapping),
              !posixMatch(escaped, "Cafe QAxxx"),
              FloatingNamePattern.literalName("^App.*$") == nil,
              FloatingNamePattern.literalName("^(App|Other)$") == nil else {
            throw AppError.message("Floating regex literal escaping regression.")
        }
        let file = directory.appendingPathComponent("unicode-yabairc")
        let label = "yabai-menu-float-3e4a5a703f65b94f"
        let custom = "yabai -m rule --add label=yabai-menu-float-custom app=\"^(Alpha|Beta)$\" manage=off"
        let source = """
        #!/bin/sh
        # Preserve the user's padding and scripts.
        yabai -m config bottom_padding 40
        \(YabaircBlacklistStore.beginMarker)
        yabai -m rule --add label=\(label) app="^\(nfd)$" manage=off # yabai-menu-bundle-id=com.apple.systempreferences
        \(custom)
        yabai -m rule --apply
        \(YabaircBlacklistStore.endMarker)
        # after block
        """
        try source.write(to: file, atomically: true, encoding: .utf8)
        let store = YabaircBlacklistStore(fileURL: file)
        guard try store.migrateUnicodeRules() else { throw AppError.message("Old NFD rule was not migrated.") }
        let migrated = try String(contentsOf: file, encoding: .utf8)
        guard migrated.contains("yabai -m config bottom_padding 40"), migrated.contains("# after block"),
              try !store.migrateUnicodeRules(),
              let app = try store.load().first(where: { $0.bundleIdentifier == "com.apple.systempreferences" }),
              app.name == nfc, app.ruleLabel == label, posixMatch(app.appPattern, nfc),
              posixMatch(app.appPattern, nfd),
              try store.load().contains(where: { $0.appPattern == "^(Alpha|Beta)$" }) else {
            throw AppError.message("Unicode migration changed user config, identity, or custom regex.")
        }
        guard try Data(contentsOf: file) == Data(migrated.utf8) else {
            throw AppError.message("Unicode migration was not byte-idempotent.")
        }
        for name in [nfc, nfd, mixed] {
            guard let existing = try store.load().first(where: { $0.ruleLabel == label }) else {
                throw AppError.message("Floating entry disappeared.")
            }
            _ = try store.removing(existing)
            let updated = try store.adding(RunningApplication(name: name, bundleIdentifier: "com.apple.systempreferences"))
            guard let added = updated.new.first(where: { $0.ruleLabel == label }),
                  added.name == nfc, added.bundleIdentifier == "com.apple.systempreferences",
                  added.appPattern.utf8.elementsEqual(pattern.utf8),
                  updated.new.filter({ $0.ruleLabel == label }).count == 1 else {
                throw AppError.message("Remove/re-add lost Unicode support or app identity.")
            }
        }
        let specialChange = try store.adding(RunningApplication(name: special, bundleIdentifier: nil))
        guard let specialApp = specialChange.new.first(where: { $0.name == special }),
              specialApp.appPattern.utf8.elementsEqual(escaped.utf8),
              store.contains(specialChange.new, application: RunningApplication(name: special.decomposedStringWithCanonicalMapping, bundleIdentifier: nil)),
              YabaiController.stableIdentifier(name: nfc, bundleIdentifier: nil) == YabaiController.stableIdentifier(name: nfd, bundleIdentifier: nil) else {
            throw AppError.message("Shell serialization or name-only Unicode identity regression.")
        }
    }

    private static func posixMatch(_ pattern: String, _ name: String) -> Bool {
        var regex = regex_t()
        guard regcomp(&regex, pattern, REG_EXTENDED | REG_NOSUB) == 0 else { return false }
        defer { regfree(&regex) }
        return regexec(&regex, name, 0, nil, 0) == 0
    }
}
