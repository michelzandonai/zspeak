import Foundation

/// Métricas puras para benchmark de ASR.
/// WER/CER são mais confiáveis que simples overlap de palavras para regressão.
enum BenchmarkMetrics {

    /// Normaliza texto para comparação:
    /// - lowercased
    /// - trim
    /// - colapsa whitespace múltiplo em espaço simples
    static func canonicalText(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Tokeniza por palavras removendo pontuação apenas nas BORDAS do token.
    ///
    /// A tokenização anterior (`.byWords`) fragmentava termos técnicos em
    /// hífens e pontos internos — "node.js" virava ["node","js"] e
    /// "guarda-chuva" virava 2 tokens — inflando sistematicamente o WER em
    /// PT-BR com code-switching (caso de uso central do app). O padrão dos
    /// scorers de ASR (sclite/jiwer) é preservar o token e limpar as bordas.
    static func canonicalWords(_ text: String) -> [String] {
        canonicalText(text)
            .components(separatedBy: .whitespaces)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }

    /// CER sobre o MESMO texto normalizado usado pelo WER (pontuação de borda
    /// removida). Antes, o CER preservava pontuação enquanto o WER a ignorava:
    /// "Olá, mundo!" vs "olá mundo" dava WER 0 e CER > 0 — um modelo sem
    /// pontuação parecia pior no CER sem erro real de reconhecimento.
    static func characterErrorRate(expected: String, actual: String) -> Double {
        errorRate(
            reference: Array(canonicalWords(expected).joined(separator: " ")),
            hypothesis: Array(canonicalWords(actual).joined(separator: " "))
        )
    }

    /// WER sobre tokenização por palavra.
    static func wordErrorRate(expected: String, actual: String) -> Double {
        errorRate(reference: canonicalWords(expected), hypothesis: canonicalWords(actual))
    }

    /// Score 0...1 derivado de WER para exibição.
    static func accuracyScore(expected: String, actual: String) -> Double {
        max(0, 1 - wordErrorRate(expected: expected, actual: actual))
    }

    /// Distância de Levenshtein normalizada pelo tamanho da referência.
    static func errorRate<Element: Equatable>(reference: [Element], hypothesis: [Element]) -> Double {
        switch (reference.isEmpty, hypothesis.isEmpty) {
        case (true, true):
            return 0
        case (true, false):
            return 1
        case (false, true):
            return 1
        case (false, false):
            let distance = levenshteinDistance(reference, hypothesis)
            return Double(distance) / Double(reference.count)
        }
    }

    /// Implementação iterativa O(m*n) com memória linear por linha.
    static func levenshteinDistance<Element: Equatable>(_ lhs: [Element], _ rhs: [Element]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }

        var previous = Array(0...rhs.count)

        for (lhsIndex, lhsElement) in lhs.enumerated() {
            var current = Array(repeating: 0, count: rhs.count + 1)
            current[0] = lhsIndex + 1

            for (rhsIndex, rhsElement) in rhs.enumerated() {
                let substitutionCost = lhsElement == rhsElement ? 0 : 1
                current[rhsIndex + 1] = min(
                    previous[rhsIndex + 1] + 1,
                    current[rhsIndex] + 1,
                    previous[rhsIndex] + substitutionCost
                )
            }

            previous = current
        }

        return previous[rhs.count]
    }
}
