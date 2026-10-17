import Foundation

/// Plano imutável para aliases literais. Uma passagem sobre o texto original
/// impede que um termo recém-inserido vire alias de outra entrada.
struct VocabularyReplacements {
    private struct Replacement {
        let term: String
        let priority: Int
    }

    private let regex: NSRegularExpression?
    private let termsByAlias: [String: Replacement]
    private let unicodeRules: [(regex: NSRegularExpression, replacement: Replacement)]
    private let fallbackPatterns: [(pattern: String, replacement: Replacement)]

    init(
        entries: [VocabularyEntry],
        categories: Set<VocabularyEntryContext> = Set(VocabularyEntryContext.allCases)
    ) {
        var pairs: [(alias: String, term: String, length: Int, order: Int)] = []
        for entry in entries where entry.isEnabled && categories.contains(entry.context) {
            let term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }
            for alias in entry.aliases {
                let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                pairs.append((trimmed, term, trimmed.count, pairs.count))
            }
        }
        // Na mesma posição vence o alias mais longo; em empate, a ordem da
        // lista. A varredura continua após o match sem reprocessar seu resultado.
        pairs.sort { $0.length == $1.length ? $0.order < $1.order : $0.length > $1.length }
        var replacements: [String: Replacement] = [:]
        var alternatives: [String] = []
        var seenPatterns: Set<Data> = []
        var unicodeRules: [(regex: NSRegularExpression, replacement: Replacement)] = []
        var fallbackPatterns: [(pattern: String, replacement: Replacement)] = []
        for (priority, pair) in pairs.enumerated() {
            let key = Self.lookupKey(pair.alias)
            let replacement = replacements[key] ?? Replacement(term: pair.term, priority: priority)
            replacements[key] = replacement
            // Formas canonicamente equivalentes podem ter bytes originais
            // distintos que o ICU não casa entre si. Preserva cada padrão
            // cadastrado, mas mantém o primeiro termo como vencedor da chave.
            let pattern = Self.literalPattern(for: pair.alias)
            if seenPatterns.insert(Data(pattern.utf8)).inserted {
                alternatives.append(pattern)
                let anchored = "\\A(?:\(pattern))\\z"
                fallbackPatterns.append((anchored, replacement))
                if !pair.alias.utf8.allSatisfy({ $0 < 128 }),
                   let individual = try? NSRegularExpression(pattern: anchored, options: [.caseInsensitive]) {
                    unicodeRules.append((individual, replacement))
                }
            }
        }
        termsByAlias = replacements
        self.unicodeRules = unicodeRules
        self.fallbackPatterns = fallbackPatterns
        guard !alternatives.isEmpty else {
            regex = nil
            return
        }

        // Marcas combinantes e conectores também pertencem à palavra:
        // "cafe" não pode cortar "cafe\u{301}", nem "posh" cortar "posh_name".
        let pattern = "(?<![\\p{L}\\p{N}\\p{M}\\p{Pc}])(?:\(alternatives.joined(separator: "|")))(?![\\p{L}\\p{N}\\p{M}\\p{Pc}])"
        regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    func apply(to text: String) -> String {
        guard !text.isEmpty, let regex else { return text }
        let original = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: original.length))
        guard !matches.isEmpty else { return text }

        var result = ""
        result.reserveCapacity(text.utf8.count)
        var cursor = 0
        for match in matches {
            let alias = original.substring(with: match.range)
            guard let replacement = replacement(for: alias) else { continue }
            result += original.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += replacement.term
            cursor = NSMaxRange(match.range)
        }
        result += original.substring(from: cursor)
        return result
    }

    private func replacement(for alias: String) -> Replacement? {
        let cached = termsByAlias[Self.lookupKey(alias)]
        let range = NSRange(location: 0, length: (alias as NSString).length)
        // Foundation e ICU divergem em algumas letras Unicode. Confere as
        // regras não ASCII anteriores à chave encontrada: um simples fallback
        // em cache miss perderia a prioridade em colisões como ᲀ / в / В.
        for rule in unicodeRules where rule.replacement.priority < (cached?.priority ?? Int.max) {
            if rule.regex.firstMatch(in: alias, range: range) != nil {
                return rule.replacement
            }
        }
        if let cached { return cached }
        // Um match da expressão combinada sempre pertence a uma regra.
        // Caminho raro: resolve com a mesma semântica ICU, sem adivinhar por
        // uppercased() nem guardar centenas de grupos em cada match comum.
        for rule in fallbackPatterns {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]),
                  regex.firstMatch(in: alias, range: range) != nil else { continue }
            return rule.replacement
        }
        return nil
    }

    /// Case folding Unicode cobre também expansões como ß/SS. Não há grupos
    /// de captura por alias: centenas de ranges por match custariam mais que
    /// a varredura original quando o texto contém muitos termos técnicos.
    private static func lookupKey(_ alias: String) -> String {
        alias.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    /// Aceita acentos compostos/decompostos sem normalizar a transcrição
    /// inteira: bytes e espaçamento fora do alias devem permanecer intactos.
    private static func literalPattern(for alias: String) -> String {
        if alias.utf8.allSatisfy({ $0 < 128 }) {
            return NSRegularExpression.escapedPattern(for: alias)
        }
        return alias.map { character in
            let original = String(character)
            let composed = original.precomposedStringWithCanonicalMapping
            let decomposed = original.decomposedStringWithCanonicalMapping
            var seen: Set<Data> = []
            let variants = [original, composed, decomposed].filter {
                seen.insert(Data($0.utf8)).inserted
            }.map { NSRegularExpression.escapedPattern(for: $0) }
            // Algumas letras (ex.: क़) são excluídas da recomposição Unicode:
            // NFC e NFD perdem os bytes originais, que ainda precisam casar.
            return variants.count == 1 ? variants[0] : "(?:\(variants.joined(separator: "|")))"
        }.joined()
    }
}
