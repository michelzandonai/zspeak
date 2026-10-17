import Foundation
#if canImport(zspeak)
@testable import zspeak
#endif

/// Referência congelada do matcher sequencial anterior a esta otimização.
/// Mantém inclusive as cascatas e as fronteiras antigas para provar regressões.
struct VocabularyReplacementReference {
    private let rules: [(regex: NSRegularExpression, template: String)]

    init(entries: [VocabularyEntry]) {
        var pairs: [(alias: String, term: String)] = []
        for entry in entries where entry.isEnabled {
            let term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }
            for alias in entry.aliases {
                let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                pairs.append((trimmed, term))
            }
        }
        pairs.sort { $0.alias.count > $1.alias.count }
        rules = pairs.compactMap { alias, term in
            let pattern = "(?<![\\p{L}\\p{N}])\(NSRegularExpression.escapedPattern(for: alias))(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            return (regex, NSRegularExpression.escapedTemplate(for: term))
        }
    }

    func apply(to text: String) -> String {
        var result = text
        for rule in rules {
            result = rule.regex.stringByReplacingMatches(
                in: result,
                range: NSRange(location: 0, length: (result as NSString).length),
                withTemplate: rule.template
            )
        }
        return result
    }
}
