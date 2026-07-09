import Foundation

/// Regras puras para revelar texto parcial de forma progressiva no overlay.
enum ProgressiveTextReveal {
    /// Numero maximo de frames para concluir um salto grande de texto.
    static let targetFrameBudget = 36

    /// Resultado de um passo de revelação: `base` é aplicada de imediato
    /// (correções interiores trocam no lugar, sem varredura de deleção) e
    /// `tail` é o texto genuinamente novo, digitado progressivamente.
    struct RevealStep: Equatable {
        var base: String
        var tail: String
    }

    /// Divide o `target` entre o que troca no lugar e o que é digitado.
    ///
    /// Previews consecutivos do ASR reescrevem palavras já exibidas
    /// (pontuação, capitalização, correções). Animar essas reescritas como
    /// deleção+redigitação fazia o texto "sumir e voltar" no overlay. Aqui o
    /// diff é ancorado por palavras: tudo até a última palavra em comum é
    /// aplicado de uma vez; só a cauda realmente nova é datilografada.
    static func revealStep(current: String, target: String) -> RevealStep {
        // Caso comum: o alvo apenas acrescenta texto ao que já está na tela.
        if target.hasPrefix(current) {
            return RevealStep(base: current, tail: String(target.dropFirst(current.count)))
        }

        // Limita o diff de palavras à região divergente (após o prefixo comum,
        // recuado ao início da palavra) — barato mesmo com texto longo.
        let anchorLength = wordAnchorLength(current: current, target: target)
        let anchor = String(target.prefix(anchorLength))
        let currentRemainder = String(current.dropFirst(anchorLength))
        let targetRemainder = String(target.dropFirst(anchorLength))

        var base: String
        var tail: String
        if let matchEnd = lastCommonWordEnd(current: currentRemainder, target: targetRemainder) {
            base = anchor + String(targetRemainder.prefix(matchEnd))
            tail = String(targetRemainder.dropFirst(matchEnd))
        } else if anchorLength > 0 {
            // Sem palavra em comum depois da âncora: mantém a âncora e digita
            // o trecho reescrito.
            base = anchor
            tail = targetRemainder
        } else {
            // Reescrita completa: trocar de uma vez é mais fluido do que
            // apagar e redigitar um texto praticamente igual.
            base = target
            tail = ""
        }

        // Aproveita o que já está na tela: se a cauda apenas completa o texto
        // atual (ex.: "volta" → "voltando"), digita só o restante.
        if current.count > base.count, current.hasPrefix(base) {
            let currentTail = String(current.dropFirst(base.count))
            let shared = commonPrefix(currentTail, tail)
            if !shared.isEmpty {
                base += shared
                tail = String(tail.dropFirst(shared.count))
            }
        }

        return RevealStep(base: base, tail: tail)
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

    /// Intervalo entre frames da revelacao. Saltos longos usam uma cadencia mais
    /// rapida para o overlay alcancar o ASR sem parecer atrasado.
    ///
    /// Cadencia limitada a ~30-50 passos/s: cada passo e uma mutacao de estado
    /// + relayout de texto no MainActor, que compete com a waveform de 60fps.
    /// A cadencia antiga (8-13ms ≈ 80-125 passos/s, cada um numa transacao
    /// animada) monopolizava o MainActor enquanto o usuario falava e a
    /// waveform engasgava.
    static func frameDelayMilliseconds(remainingCharacterCount: Int) -> UInt64 {
        switch remainingCharacterCount {
        case ...0:
            return 0
        case ...24:
            return 32
        case ...96:
            return 26
        default:
            return 20
        }
    }

    static func nextText(current: String, target: String, maxCharacters: Int) -> String {
        let start = startText(current: current, target: target)
        guard start == current else { return start }
        guard current != target else { return target }

        let nextCount = min(target.count, current.count + max(1, maxCharacters))
        return String(target.prefix(nextCount))
    }

    // MARK: - Diff por palavras

    private struct WordToken {
        /// Forma normalizada (caixa/acentos/pontuação ignorados) usada no match.
        let normalized: String
        /// Distância (em Characters) do início do texto até o fim da palavra.
        let endOffset: Int
    }

    /// Distância (em Characters) até o fim da última palavra do `target` que
    /// também aparece, na mesma ordem, no texto atual — via LCS por palavras.
    private static func lastCommonWordEnd(current: String, target: String) -> Int? {
        let currentWords = tokens(in: current)
        let targetWords = tokens(in: target)
        guard !currentWords.isEmpty, !targetWords.isEmpty else { return nil }

        func matches(_ i: Int, _ j: Int) -> Bool {
            let lhs = currentWords[i].normalized
            return !lhs.isEmpty && lhs == targetWords[j].normalized
        }

        var table = [[Int]](
            repeating: [Int](repeating: 0, count: targetWords.count + 1),
            count: currentWords.count + 1
        )
        for i in stride(from: currentWords.count - 1, through: 0, by: -1) {
            for j in stride(from: targetWords.count - 1, through: 0, by: -1) {
                if matches(i, j) {
                    table[i][j] = table[i + 1][j + 1] + 1
                } else {
                    table[i][j] = max(table[i + 1][j], table[i][j + 1])
                }
            }
        }

        var i = 0
        var j = 0
        var lastMatchEnd: Int?
        while i < currentWords.count, j < targetWords.count {
            if matches(i, j) {
                lastMatchEnd = targetWords[j].endOffset
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }

        return lastMatchEnd
    }

    /// Comprimento (em Characters) do prefixo comum recuado até o início da
    /// palavra corrente — evita ancorar o diff no meio de uma palavra.
    private static func wordAnchorLength(current: String, target: String) -> Int {
        let prefix = commonPrefix(current, target)
        guard !prefix.isEmpty else { return 0 }
        guard let lastSpace = prefix.lastIndex(where: { $0.isWhitespace }) else { return 0 }
        return prefix.distance(from: prefix.startIndex, to: prefix.index(after: lastSpace))
    }

    private static func tokens(in text: String) -> [WordToken] {
        var result: [WordToken] = []
        var currentWord = ""
        var offset = 0

        for character in text {
            offset += 1
            if character.isWhitespace {
                if !currentWord.isEmpty {
                    result.append(WordToken(normalized: normalized(currentWord), endOffset: offset - 1))
                    currentWord = ""
                }
            } else {
                currentWord.append(character)
            }
        }
        if !currentWord.isEmpty {
            result.append(WordToken(normalized: normalized(currentWord), endOffset: offset))
        }

        return result
    }

    /// Normaliza uma palavra para o match: ignora caixa, acentos e pontuação.
    /// Assim "crítico?" ≡ "critico." — flutuações de pontuação entre previews
    /// não derrubam a âncora.
    private static func normalized(_ word: String) -> String {
        word
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }
}
