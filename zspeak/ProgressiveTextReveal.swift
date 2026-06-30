import Foundation

/// Regras puras para revelar texto parcial de forma progressiva no overlay.
enum ProgressiveTextReveal {
    /// Numero maximo de frames para concluir um salto grande de texto.
    static let targetFrameBudget = 36

    static func commonPrefix(_ lhs: String, _ rhs: String) -> String {
        var leftIndex = lhs.startIndex
        var rightIndex = rhs.startIndex
        var result = ""

        while leftIndex < lhs.endIndex,
              rightIndex < rhs.endIndex,
              lhs[leftIndex] == rhs[rightIndex] {
            result.append(lhs[leftIndex])
            leftIndex = lhs.index(after: leftIndex)
            rightIndex = rhs.index(after: rightIndex)
        }

        return result
    }

    /// Ponto de partida para uma nova animacao.
    ///
    /// Quando o texto novo apenas expande o atual, preserva o que ja esta na tela.
    /// Quando o ASR reescreve uma parte anterior, volta ate o prefixo comum.
    static func startText(current: String, target: String) -> String {
        guard !target.hasPrefix(current) else { return current }
        return commonPrefix(current, target)
    }

    static func remainingCharacterCount(current: String, target: String) -> Int {
        let start = startText(current: current, target: target)
        return max(0, target.count - start.count)
    }

    /// Tamanho do lote por frame: letras individuais em textos curtos e passos
    /// um pouco maiores em saltos longos, mantendo a animacao fluida sem atrasar.
    static func batchSize(remainingCharacterCount: Int) -> Int {
        guard remainingCharacterCount > 0 else { return 0 }
        return max(1, Int(ceil(Double(remainingCharacterCount) / Double(targetFrameBudget))))
    }

    static func nextText(current: String, target: String, maxCharacters: Int) -> String {
        let start = startText(current: current, target: target)
        guard start == current else { return start }
        guard current != target else { return target }

        let nextCount = min(target.count, current.count + max(1, maxCharacters))
        return String(target.prefix(nextCount))
    }
}
