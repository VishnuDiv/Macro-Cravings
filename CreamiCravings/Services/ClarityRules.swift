import Foundation

/// Applies the audit's text rules when ingredient text is DISPLAYED (rows, cook mode, shopping list). The stored text is never changed,
/// and search keeps both the original and the annotated text.
///   - rules run in order;
///   - a match inside existing parentheses is left alone;
///   - a rule is skipped when its added term (the "(cilantro)" in the display) is already anywhere on the line.
final class ClarityRules: @unchecked Sendable {
    private struct Compiled { var rx: NSRegularExpression; var display: String; var term: String? }
    private let rules: [Compiled]

    /// The rules the app uses; set when the catalog loads.
    nonisolated(unsafe) static var shared = ClarityRules(textRules: [])

    init(textRules: [TextRule]) {
        rules = textRules.compactMap { r in
            guard let rx = try? NSRegularExpression(pattern: r.match, options: [.caseInsensitive]) else { return nil }
            // the US term a rule adds: the text of the first "(...)" in its display, e.g. "(all-purpose flour)"
            var term: String?
            if let t = r.display.range(of: "\\(([^()]*)\\)", options: .regularExpression) {
                term = String(r.display[t]).trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            }
            return Compiled(rx: rx, display: r.display, term: term?.isEmpty == false ? term : nil)
        }
    }

    var isEmpty: Bool { rules.isEmpty }

    func annotate(_ text: String) -> String {
        var t = text
        for rule in rules {
            if let term = rule.term, t.range(of: term, options: .caseInsensitive) != nil { continue }
            let ns = t as NSString
            let matches = rule.rx.matches(in: t, range: NSRange(location: 0, length: ns.length))
            if matches.isEmpty { continue }
            var out = "", last = 0, changed = false
            for m in matches {
                // skip matches inside parentheses
                let before = ns.substring(to: m.range.location)
                if before.filter({ $0 == "(" }).count > before.filter({ $0 == ")" }).count { continue }
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                out += rule.rx.replacementString(for: m, in: t, offset: 0, template: rule.display)
                last = m.range.location + m.range.length
                changed = true
            }
            guard changed else { continue }
            out += ns.substring(from: last)
            t = out
        }
        // tidy double spaces left by deletions
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        return t.trimmingCharacters(in: .whitespaces)
    }
}
