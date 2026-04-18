import Foundation

public enum TextCleaner {
    private struct Rule {
        let pattern: String
        let replacement: String
        let options: NSRegularExpression.Options
    }

    private static let rules: [Rule] = [
        // Russian fillers
        Rule(pattern: #"\b(э{2,}|м{2,}|эмм+|ну|типа|короче|это\sсамое)\b"#,
             replacement: "", options: [.caseInsensitive]),
        // English fillers
        Rule(pattern: #"\b(uh+|um+|er+|uhm+|like|you\s+know|i\s+mean)\b"#,
             replacement: "", options: [.caseInsensitive]),
        // Consecutive word repetition
        Rule(pattern: #"\b(\w+)(\s+\1\b)+"#,
             replacement: "$1", options: [.caseInsensitive]),
        // Collapse whitespace
        Rule(pattern: #"\s+"#, replacement: " ", options: []),
    ]

    public static func clean(_ input: String) -> String {
        var s = input
        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: rule.options) else { continue }
            let range = NSRange(s.startIndex..., in: s)
            s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: rule.replacement)
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }
        // Capitalize first character (Unicode-safe)
        s = s.prefix(1).uppercased() + s.dropFirst()
        if let last = s.last, !".?!".contains(last) { s += "." }
        return s
    }
}
