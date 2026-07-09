import Foundation

/// Configuração do pós-processamento de texto (ITN + capitalização).
/// Persistida em UserDefaults:
///   defaults write com.zspeak.app textNormalizationEnabled -bool false
enum TextNormalizationSettings {
    static let enabledKey = "textNormalizationEnabled"

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: enabledKey) != nil else { return true }
        return defaults.bool(forKey: enabledKey)
    }
}

/// Inverse Text Normalization (ITN) determinística para PT-BR.
///
/// Converte números falados em forma escrita — o Parakeet devolve "oito mil e
/// oitenta" onde o dev quer "8080". Regras de PRECISÃO primeiro: converte
/// apenas quando a composição por extenso é inequivocamente um número ditado;
/// prosa natural ("dois amigos", "te falei mil vezes") fica intacta.
///
/// Regras:
/// - Composições multi-palavra ("vinte e três", "dois mil e vinte e seis",
///   "cento e cinquenta") sempre convertem → "23", "2026", "150".
/// - Palavra única converte só quando é número "forte": 10–19, dezenas
///   (vinte…noventa) e centenas exatas (duzentos…novecentos). Unidades (0–9),
///   "cem", "mil" e "milhão" isoladas NÃO convertem — uso retórico comum.
/// - Contextos destravam a conversão de palavras fracas:
///   · "<n> por cento"      → "N%"       (inclui "cem por cento" → "100%")
///   · "<n> vírgula <n...>" → "N,M"      ("três vírgula quatorze" → "3,14")
///   · "<n 1..31> de <mês>" → "N de mês" ("três de julho" → "3 de julho")
/// - Milhões/bilhões exatos ficam na forma mista padrão: "2 milhões".
/// - Capitalização de início de frase é OPCIONAL (desligada quando o destino é
///   app de dev — "git status" não pode virar "Git status" no terminal).
enum PTBRTextNormalizer {

    struct Options {
        var convertNumbers = true
        var capitalizeSentences = false

        init(convertNumbers: Bool = true, capitalizeSentences: Bool = false) {
            self.convertNumbers = convertNumbers
            self.capitalizeSentences = capitalizeSentences
        }
    }

    static func normalize(_ text: String, options: Options = Options()) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        if options.convertNumbers {
            result = convertSpokenNumbers(in: result)
        }
        if options.capitalizeSentences {
            result = capitalizeSentenceStarts(in: result)
        }
        return result
    }

    // MARK: - Léxico numérico

    private enum NumberWordKind {
        case unit(Int)         // um..nove (e zero)
        case teen(Int)         // dez..dezenove
        case ten(Int)          // vinte..noventa
        case hundredExact      // cem (terminal, não compõe com "e")
        case hundred(Int)      // cento, duzentos..novecentos
        case scale(Int)        // mil, milhão, bilhão
    }

    private static let numberWords: [String: NumberWordKind] = [
        "zero": .unit(0),
        "um": .unit(1), "uma": .unit(1),
        "dois": .unit(2), "duas": .unit(2),
        "tres": .unit(3), "três": .unit(3),
        "quatro": .unit(4), "cinco": .unit(5), "seis": .unit(6),
        "sete": .unit(7), "oito": .unit(8), "nove": .unit(9),
        "dez": .teen(10), "onze": .teen(11), "doze": .teen(12), "treze": .teen(13),
        "quatorze": .teen(14), "catorze": .teen(14), "quinze": .teen(15),
        "dezesseis": .teen(16), "dezessete": .teen(17), "dezoito": .teen(18),
        "dezenove": .teen(19),
        "vinte": .ten(20), "trinta": .ten(30), "quarenta": .ten(40),
        "cinquenta": .ten(50), "sessenta": .ten(60), "setenta": .ten(70),
        "oitenta": .ten(80), "noventa": .ten(90),
        "cem": .hundredExact,
        "cento": .hundred(100),
        "duzentos": .hundred(200), "duzentas": .hundred(200),
        "trezentos": .hundred(300), "trezentas": .hundred(300),
        "quatrocentos": .hundred(400), "quatrocentas": .hundred(400),
        "quinhentos": .hundred(500), "quinhentas": .hundred(500),
        "seiscentos": .hundred(600), "seiscentas": .hundred(600),
        "setecentos": .hundred(700), "setecentas": .hundred(700),
        "oitocentos": .hundred(800), "oitocentas": .hundred(800),
        "novecentos": .hundred(900), "novecentas": .hundred(900),
        "mil": .scale(1_000),
        "milhao": .scale(1_000_000), "milhão": .scale(1_000_000),
        "milhoes": .scale(1_000_000), "milhões": .scale(1_000_000),
        "bilhao": .scale(1_000_000_000), "bilhão": .scale(1_000_000_000),
        "bilhoes": .scale(1_000_000_000), "bilhões": .scale(1_000_000_000),
    ]

    private static let monthNames: Set<String> = [
        "janeiro", "fevereiro", "março", "marco", "abril", "maio", "junho",
        "julho", "agosto", "setembro", "outubro", "novembro", "dezembro",
    ]

    // MARK: - Tokenização

    private struct Token {
        let text: String
        let isWord: Bool  // letras/dígitos (inclui acentos); resto é separador
    }

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var currentIsWord: Bool?

        for char in text {
            let isWord = char.isLetter || char.isNumber
            if currentIsWord == isWord {
                current.append(char)
            } else {
                if let kind = currentIsWord {
                    tokens.append(Token(text: current, isWord: kind))
                }
                current = String(char)
                currentIsWord = isWord
            }
        }
        if let kind = currentIsWord, !current.isEmpty {
            tokens.append(Token(text: current, isWord: kind))
        }
        return tokens
    }

    /// Separador aceitável DENTRO de um span numérico: só whitespace.
    /// Vírgula/ponto quebram o span ("vinte, e três" não compõe).
    private static func isSpanSeparator(_ token: Token) -> Bool {
        !token.isWord && token.text.allSatisfy { $0 == " " || $0 == "\u{00A0}" }
    }

    // MARK: - Parser de composição

    private struct ParsedNumber {
        let value: Int
        /// Quantidade de palavras-número consumidas (sem contar "e").
        let numberWordCount: Int
        /// Índice (em tokens) do primeiro token APÓS o span.
        let endIndex: Int
        /// Palavra única que originou o span (quando numberWordCount == 1).
        let singleKind: NumberWordKind?
    }

    /// Consome a composição numérica mais longa VÁLIDA a partir de `start`
    /// (que deve ser uma palavra-número). Gramática PT-BR: centenas → dezenas
    /// → unidades ligadas por "e", escalas em ordem decrescente. "e" só é
    /// consumido quando o token seguinte continua a composição — "entre um e
    /// dois" não vira "3".
    private static func parseNumber(tokens: [Token], start: Int) -> ParsedNumber? {
        var total = 0
        var current = 0
        // Menor categoria já usada no grupo corrente: 4=nenhuma, 3=centena,
        // 2=dezena/teen, 1=unidade. Componente novo precisa de categoria menor.
        var openCategory = 4
        var lastScale = Int.max
        var wordCount = 0
        var singleKind: NumberWordKind?
        var index = start
        var lastValidEnd = start

        func category(of kind: NumberWordKind) -> Int {
            switch kind {
            case .unit: return 1
            case .teen, .ten: return 2
            case .hundred, .hundredExact: return 3
            case .scale: return 0  // tratado à parte
            }
        }

        while index < tokens.count {
            let token = tokens[index]
            guard token.isWord, let kind = numberWords[token.text.lowercased()] else { break }

            // `break` dentro do switch sairia só do switch — o flag garante que
            // um componente rejeitado encerre o span sem ser contado.
            var applied = false
            switch kind {
            case .scale(let magnitude):
                // Escala precisa ser decrescente ("mil" depois de "milhão");
                // "milhão"/"bilhão" exigem coeficiente explícito; "mil" aceita
                // implícito ("mil e quinhentos" = 1500) só no início do span.
                if magnitude < lastScale,
                   !(current == 0 && magnitude >= 1_000_000),
                   !(current == 0 && wordCount > 0) {
                    total += max(current, 1) * magnitude
                    current = 0
                    openCategory = 4
                    lastScale = magnitude
                    applied = true
                }

            case .hundredExact:
                // "cem" fecha o grupo: nada compõe depois (composto usa "cento").
                if openCategory == 4 {
                    current += 100
                    openCategory = 0
                    applied = true
                }

            case .hundred(let value):
                if openCategory > 3 {
                    current += value
                    openCategory = 3
                    applied = true
                }

            case .teen(let value):
                if openCategory > 2 {
                    current += value
                    openCategory = 1  // teen encerra dezena+unidade
                    applied = true
                }

            case .ten(let value):
                if openCategory > 2 {
                    current += value
                    openCategory = 2
                    applied = true
                }

            case .unit(let value):
                // "zero" só participa sozinho ("vinte e zero" não existe)
                if openCategory > 1, !(value == 0 && wordCount > 0) {
                    current += value
                    openCategory = 1
                    applied = true
                }
            }

            guard applied else { break }

            wordCount += 1
            singleKind = wordCount == 1 ? kind : nil
            index += 1
            lastValidEnd = index

            // Tenta consumir " e " + próxima palavra-número que CONTINUE a
            // composição; senão, o span termina aqui.
            var lookahead = index
            while lookahead < tokens.count, isSpanSeparator(tokens[lookahead]) {
                lookahead += 1
            }
            guard lookahead < tokens.count,
                  tokens[lookahead].isWord,
                  tokens[lookahead].text.lowercased() == "e" else {
                // Sem "e": composição pode continuar direto (ex.: "dois mil")
                var direct = index
                while direct < tokens.count, isSpanSeparator(tokens[direct]) {
                    direct += 1
                }
                if direct < tokens.count, direct > index,
                   tokens[direct].isWord,
                   let nextKind = numberWords[tokens[direct].text.lowercased()],
                   canContinue(after: openCategory, lastScale: lastScale, current: current, next: nextKind) {
                    index = direct
                    continue
                }
                break
            }
            var afterE = lookahead + 1
            while afterE < tokens.count, isSpanSeparator(tokens[afterE]) {
                afterE += 1
            }
            guard afterE < tokens.count,
                  tokens[afterE].isWord,
                  let nextKind = numberWords[tokens[afterE].text.lowercased()],
                  canContinue(after: openCategory, lastScale: lastScale, current: current, next: nextKind, viaE: true) else {
                break
            }
            index = afterE
        }

        guard wordCount > 0 else { return nil }

        // "cento" pendurado sem continuação não é número
        if wordCount == 1, case .hundred(100)? = singleKind { return nil }

        let value = total + current
        guard value > 0 || (wordCount == 1 && isZero(singleKind)) else { return nil }

        return ParsedNumber(
            value: value,
            numberWordCount: wordCount,
            endIndex: lastValidEnd,
            singleKind: singleKind
        )
    }

    private static func isZero(_ kind: NumberWordKind?) -> Bool {
        if case .unit(0)? = kind { return true }
        return false
    }

    /// O próximo componente pode continuar a composição corrente?
    private static func canContinue(
        after openCategory: Int,
        lastScale: Int,
        current: Int,
        next: NumberWordKind,
        viaE: Bool = false
    ) -> Bool {
        switch next {
        case .scale(let magnitude):
            // "dois mil", "trezentos e cinquenta mil": escala nova menor que a
            // anterior e com coeficiente acumulado. Via "e" não se liga escala
            // ("vinte e mil" não existe).
            return !viaE && magnitude < lastScale && current > 0
        case .hundredExact:
            // "dois mil e cem" — "cem" só abre grupo novo após escala
            return openCategory == 4
        case .hundred:
            // Centena só abre grupo novo (depois de escala): "dois mil e duzentos"
            return openCategory == 4
        case .teen, .ten:
            return openCategory > 2
        case .unit(let value):
            return openCategory > 1 && value != 0
        }
    }

    // MARK: - Conversão

    private static func convertSpokenNumbers(in text: String) -> String {
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return text }

        var output = ""
        var index = 0

        while index < tokens.count {
            let token = tokens[index]

            // Dígitos já escritos: só interessa para "% / vírgula" adiante
            if token.isWord, let digits = Int(token.text), digits >= 0 {
                let consumed = renderDigitContext(
                    tokens: tokens, index: index, value: digits, into: &output
                )
                index = consumed
                continue
            }

            guard token.isWord,
                  numberWords[token.text.lowercased()] != nil,
                  let parsed = parseNumber(tokens: tokens, start: index) else {
                output += token.text
                index += 1
                continue
            }

            // Decide se o span converte (ou se contexto destrava)
            let context = spanContext(tokens: tokens, endIndex: parsed.endIndex)
            if shouldConvert(parsed, context: context) {
                index = render(parsed, context: context, tokens: tokens, into: &output)
            } else {
                // Emite o span como estava (texto original, token a token)
                for spanIndex in index..<parsed.endIndex {
                    output += tokens[spanIndex].text
                }
                index = parsed.endIndex
            }
        }

        return output
    }

    private enum SpanContext {
        case none
        /// "por cento" logo após o span (índice do 1º token após "cento")
        case percent(endIndex: Int)
        /// "vírgula" + números após o span (fração e índice pós-fração)
        case decimal(fraction: String, endIndex: Int)
        /// "de <mês>" logo após o span
        case dateDay
    }

    private static func spanContext(tokens: [Token], endIndex: Int) -> SpanContext {
        var index = endIndex
        while index < tokens.count, isSpanSeparator(tokens[index]) { index += 1 }
        guard index < tokens.count, tokens[index].isWord else { return .none }

        let word = tokens[index].text.lowercased()

        // "<n> por cento"
        if word == "por" {
            var next = index + 1
            while next < tokens.count, isSpanSeparator(tokens[next]) { next += 1 }
            if next < tokens.count, tokens[next].isWord,
               tokens[next].text.lowercased() == "cento" {
                return .percent(endIndex: next + 1)
            }
            return .none
        }

        // "<n> vírgula <n...>"
        if word == "vírgula" || word == "virgula" {
            var fraction = ""
            var cursor = index + 1
            while true {
                var next = cursor
                while next < tokens.count, isSpanSeparator(tokens[next]) { next += 1 }
                guard next < tokens.count, tokens[next].isWord else { break }
                let fractionToken = tokens[next]
                if let digits = Int(fractionToken.text) {
                    fraction += String(digits)
                    cursor = next + 1
                    continue
                }
                guard numberWords[fractionToken.text.lowercased()] != nil,
                      let part = parseNumber(tokens: tokens, start: next),
                      part.value < 100 else { break }
                // "zero cinco" → "05": zero contribui como dígito literal
                if part.value == 0 {
                    fraction += "0"
                } else {
                    fraction += String(part.value)
                }
                cursor = part.endIndex
            }
            guard !fraction.isEmpty else { return .none }
            return .decimal(fraction: fraction, endIndex: cursor)
        }

        // "<n 1..31> de <mês>"
        if word == "de" {
            var next = index + 1
            while next < tokens.count, isSpanSeparator(tokens[next]) { next += 1 }
            if next < tokens.count, tokens[next].isWord,
               monthNames.contains(tokens[next].text.lowercased()) {
                return .dateDay
            }
            return .none
        }

        return .none
    }

    private static func shouldConvert(_ parsed: ParsedNumber, context: SpanContext) -> Bool {
        // Contexto explícito de número ditado destrava qualquer span
        switch context {
        case .percent, .decimal:
            return true
        case .dateDay:
            return parsed.value >= 1 && parsed.value <= 31
        case .none:
            break
        }

        if parsed.numberWordCount >= 2 { return true }

        // Palavra única: só números "fortes" (uso retórico improvável)
        switch parsed.singleKind {
        case .teen, .ten:
            return true
        case .hundred(let value):
            return value >= 200  // duzentos..novecentos ("cento" já foi vetado)
        case .unit, .hundredExact, .scale, .none:
            return false
        }
    }

    /// Emite o span convertido (+ sufixo de contexto) e devolve o índice do
    /// próximo token a processar.
    private static func render(
        _ parsed: ParsedNumber,
        context: SpanContext,
        tokens: [Token],
        into output: inout String
    ) -> Int {
        switch context {
        case .percent(let endIndex):
            output += "\(parsed.value)%"
            return endIndex
        case .decimal(let fraction, let endIndex):
            output += "\(parsed.value),\(fraction)"
            return endIndex
        case .dateDay, .none:
            output += formatted(parsed.value)
            return parsed.endIndex
        }
    }

    /// Contexto de %/vírgula para números que o ASR já emitiu em dígitos
    /// ("50 por cento" → "50%"). Devolve o índice do próximo token.
    private static func renderDigitContext(
        tokens: [Token],
        index: Int,
        value: Int,
        into output: inout String
    ) -> Int {
        switch spanContext(tokens: tokens, endIndex: index + 1) {
        case .percent(let endIndex):
            output += "\(value)%"
            return endIndex
        case .decimal(let fraction, let endIndex):
            output += "\(value),\(fraction)"
            return endIndex
        case .dateDay, .none:
            output += tokens[index].text
            return index + 1
        }
    }

    /// Milhões/bilhões exatos ficam na forma mista padrão de escrita.
    private static func formatted(_ value: Int) -> String {
        if value >= 1_000_000_000, value % 1_000_000_000 == 0 {
            let coefficient = value / 1_000_000_000
            return "\(coefficient) \(coefficient == 1 ? "bilhão" : "bilhões")"
        }
        if value >= 1_000_000, value % 1_000_000 == 0 {
            let coefficient = value / 1_000_000
            return "\(coefficient) \(coefficient == 1 ? "milhão" : "milhões")"
        }
        return String(value)
    }

    // MARK: - Capitalização

    /// Maiúscula no início do texto e após pontuação final de frase.
    /// NÃO usar quando o destino é app de dev — comandos ditados ("git status")
    /// não podem ganhar maiúscula.
    static func capitalizeSentenceStarts(in text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var capitalizeNext = true
        var pendingBoundary = false

        for char in text {
            if capitalizeNext, char.isLetter {
                result += String(char).uppercased()
                capitalizeNext = false
                pendingBoundary = false
                continue
            }
            if char.isLetter || char.isNumber {
                capitalizeNext = false
                pendingBoundary = false
            } else if char == "\n" {
                // Quebra de linha inicia frase mesmo sem espaço depois
                capitalizeNext = true
                pendingBoundary = false
            } else if char == "." || char == "!" || char == "?" || char == "…" {
                pendingBoundary = true
            } else if pendingBoundary, char.isWhitespace {
                capitalizeNext = true
                pendingBoundary = false
            }
            result.append(char)
        }
        return result
    }
}
