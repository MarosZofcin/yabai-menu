import Foundation

// Native serialization gate: runtime selects canonical forms, never regex code.
// Each grapheme is escaped as a literal; alternation only joins equivalent forms.
enum FloatingNamePattern {
    static func forms() throws -> [String] {
        let runtime = RuntimeController.shared
        // Old packages can still be restored; keep the Unicode fix on this host.
        if try runtime.package().api < 3 { return ["NFC", "NFD"] }
        let value = try runtime.call("floatingNamePolicy", input: [:])
        guard let policy = value as? [String: Any], policy.count == 1,
              let forms = policy["forms"] as? [String],
              forms.count == 2, Set(forms) == Set(["NFC", "NFD"]) else {
            throw AppError.message("Runtime returned an invalid floating-name policy.")
        }
        return forms
    }

    static func make(_ name: String, forms: [String]) throws -> String {
        guard !name.isEmpty, name.utf8.count <= 4096,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              forms.count == 2, Set(forms) == Set(["NFC", "NFD"]) else {
            throw AppError.message("Invalid floating application name or normalization policy.")
        }
        let pieces = name.precomposedStringWithCanonicalMapping.map { character -> String in
            let literal = String(character)
            var variants: [String] = []
            for form in forms {
                let value = form == "NFC" ? literal.precomposedStringWithCanonicalMapping
                    : literal.decomposedStringWithCanonicalMapping
                // Swift String equality treats NFC and NFD as equal. Regex does not.
                if !variants.contains(where: { $0.utf8.elementsEqual(value.utf8) }) {
                    variants.append(value)
                }
            }
            let escaped = variants.map(escape)
            return escaped.count == 1 ? escaped[0] : "(" + escaped.joined(separator: "|") + ")"
        }
        return "^" + pieces.joined() + "$"
    }

    private static let metacharacters = Set("\\.^$|?*+()[]{}".unicodeScalars)

    private static func escape(_ value: String) -> String {
        value.unicodeScalars.map { metacharacters.contains($0) ? "\\" + String($0) : String($0) }.joined()
    }

    // Only recognize anchored literal patterns, never reinterpret custom regex.
    static func literalName(_ pattern: String) -> String? {
        let scalars = Array(pattern.unicodeScalars)
        guard scalars.count > 2, scalars.first == "^", scalars.last == "$" else { return nil }
        var result = ""
        var escaped = false
        for scalar in scalars.dropFirst().dropLast() {
            if escaped {
                // ICU's previous escapedPattern may also have escaped hyphens.
                guard metacharacters.contains(scalar) || scalar == "-" else { return nil }
                result += String(scalar)
                escaped = false
            } else if scalar == "\\" {
                escaped = true
            } else {
                guard !metacharacters.contains(scalar) else { return nil }
                result += String(scalar)
            }
        }
        return escaped || result.isEmpty ? nil : result
    }
}
