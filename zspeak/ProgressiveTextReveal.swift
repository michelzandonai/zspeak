import Foundation

/// Regras puras para revelar texto parcial de forma progressiva no overlay.
enum ProgressiveTextReveal {
    /// Numero maximo de frames para concluir um salto grande de texto.
    static let targetFrameBudget = 36

    struct Revision: Equatable {
        var prefix: String
        var removed: String
        var inserted: String
        var suffix: String

        var sourceText: String { prefix + removed + suffix }
        var targetText: String { prefix + inserted + suffix }
        var isPlain: Bool { removed.isEmpty && inserted.isEmpty }

        static func plain(_ text: String) -> Revision {
            Revision(prefix: text, removed: "", inserted: "", suffix: "")
        }
    }

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

    static func revision(current: String, target: String) -> Revision {
        let prefix = commonPrefix(current, target)
        let currentTail = Array(current.dropFirst(prefix.count))
        let targetTail = Array(target.dropFirst(prefix.count))
        let maxSuffixLength = min(currentTail.count, targetTail.count)
        var suffixLength = 0

        while suffixLength < maxSuffixLength,
              currentTail[currentTail.count - 1 - suffixLength] == targetTail[targetTail.count - 1 - suffixLength] {
            suffixLength += 1
        }

        let removedEnd = currentTail.count - suffixLength
        let insertedEnd = targetTail.count - suffixLength
        let removed = String(currentTail.prefix(max(0, removedEnd)))
        let inserted = String(targetTail.prefix(max(0, insertedEnd)))
        let suffix = suffixLength > 0 ? String(currentTail.suffix(suffixLength)) : ""

        return Revision(prefix: prefix, removed: removed, inserted: inserted, suffix: suffix)
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

    static func deletionBatchSize(remainingCharacterCount: Int) -> Int {
        guard remainingCharacterCount > 0 else { return 0 }
        switch remainingCharacterCount {
        case ...16:
            return 1
        case ...64:
            return 2
        default:
            return 3
        }
    }

    /// Pausa curta antes de apagar blocos grandes.
    ///
    /// Resultados parciais do ASR podem substituir um trecho amplo por poucos
    /// milissegundos e logo voltar para quase o mesmo texto. A estabilizacao
    /// evita que o overlay apague visualmente uma area grande cedo demais.
    static func deletionStabilizationDelayMilliseconds(for revision: Revision) -> UInt64 {
        let removedCount = revision.removed.count
        guard removedCount >= 18 else { return 0 }

        let sourceCount = max(1, revision.sourceText.count)
        let removedRatio = Double(removedCount) / Double(sourceCount)
        let isDominantDeletion = removedCount > revision.inserted.count + 8

        guard isDominantDeletion || removedRatio >= 0.25 else { return 0 }

        switch removedCount {
        case ...36:
            return 110
        case ...80:
            return 160
        default:
            return 220
        }
    }

    /// Intervalo entre frames da revelacao. Saltos longos usam uma cadencia mais
    /// rapida para o overlay alcancar o ASR sem parecer atrasado.
    static func frameDelayMilliseconds(remainingCharacterCount: Int) -> UInt64 {
        switch remainingCharacterCount {
        case ...0:
            return 0
        case ...24:
            return 13
        case ...96:
            return 10
        default:
            return 8
        }
    }

    static func deletionFrameDelayMilliseconds(remainingCharacterCount: Int) -> UInt64 {
        switch remainingCharacterCount {
        case ...0:
            return 0
        case ...16:
            return 28
        case ...64:
            return 22
        default:
            return 16
        }
    }

    /// Duracao da animacao visual de cada passo. Mantem letras curtas suaves e
    /// reduz o peso visual quando chega um trecho maior de uma vez.
    static func animationDuration(remainingCharacterCount: Int) -> Double {
        switch remainingCharacterCount {
        case ...0:
            return 0
        case ...24:
            return 0.065
        case ...96:
            return 0.052
        default:
            return 0.040
        }
    }

    static func nextText(current: String, target: String, maxCharacters: Int) -> String {
        let start = startText(current: current, target: target)
        guard start == current else { return start }
        guard current != target else { return target }

        let nextCount = min(target.count, current.count + max(1, maxCharacters))
        return String(target.prefix(nextCount))
    }

    static func deletingText(_ text: String, maxCharacters: Int) -> String {
        guard !text.isEmpty else { return "" }
        let nextCount = max(0, text.count - max(1, maxCharacters))
        return String(text.prefix(nextCount))
    }
}
