import Foundation
import Testing
@testable import zspeak

@Suite("PTBRTextNormalizer - ITN de números")
struct PTBRTextNormalizerNumberTests {

    private func itn(_ text: String) -> String {
        PTBRTextNormalizer.normalize(text, options: .init(convertNumbers: true, capitalizeSentences: false))
    }

    // MARK: - Composições multi-palavra (sempre convertem)

    @Test("Composições de dezena e unidade")
    func composicoesDezenaUnidade() {
        #expect(itn("preciso de vinte e três reais") == "preciso de 23 reais")
        #expect(itn("são quarenta e sete arquivos") == "são 47 arquivos")
        #expect(itn("noventa e nove por aí") == "99 por aí")
    }

    @Test("Centenas compostas")
    func centenasCompostas() {
        #expect(itn("cento e cinquenta linhas") == "150 linhas")
        #expect(itn("duzentos e trinta e quatro") == "234")
        #expect(itn("quinhentos e um") == "501")
    }

    @Test("Milhares e anos")
    func milharesEAnos() {
        #expect(itn("dois mil e vinte e seis") == "2026")
        #expect(itn("mil novecentos e oitenta e quatro") == "1984")
        #expect(itn("porta oito mil e oitenta") == "porta 8080")
        #expect(itn("mil e quinhentos metros") == "1500 metros")
        #expect(itn("dois mil duzentos") == "2200")
        #expect(itn("dois mil e cem") == "2100")
        #expect(itn("trezentos e cinquenta mil") == "350000")
    }

    @Test("Milhões e bilhões exatos usam forma mista")
    func milhoesFormaMista() {
        #expect(itn("um milhão de usuários") == "1 milhão de usuários")
        #expect(itn("dois milhões de linhas") == "2 milhões de linhas")
        #expect(itn("três bilhões de tokens") == "3 bilhões de tokens")
        // Não-exato vai para dígitos
        #expect(itn("um milhão e duzentos mil") == "1200000")
    }

    // MARK: - Palavra única: só números "fortes"

    @Test("Teens e dezenas isoladas convertem")
    func teensEDezenasConvertem() {
        #expect(itn("tenho dez minutos") == "tenho 10 minutos")
        #expect(itn("faltam quinze dias") == "faltam 15 dias")
        #expect(itn("uns trinta segundos") == "uns 30 segundos")
    }

    @Test("Centenas exatas isoladas convertem")
    func centenasExatasConvertem() {
        #expect(itn("duzentas pessoas") == "200 pessoas")
        #expect(itn("quinhentos reais") == "500 reais")
    }

    @Test("Unidades isoladas NÃO convertem (prosa natural)")
    func unidadesNaoConvertem() {
        #expect(itn("dois amigos chegaram") == "dois amigos chegaram")
        #expect(itn("uma casa bonita") == "uma casa bonita")
        #expect(itn("digitei zero ali") == "digitei zero ali")
        #expect(itn("nove entre dez") == "nove entre 10")
    }

    @Test("cem e mil isolados NÃO convertem (uso retórico)")
    func cemEMilRetoricos() {
        #expect(itn("te falei mil vezes") == "te falei mil vezes")
        #expect(itn("cem por aí") == "cem por aí")
        #expect(itn("milhão de coisas") == "milhão de coisas")
    }

    // MARK: - Composições inválidas ficam intactas

    @Test("'e' entre números independentes não compõe")
    func eNaoCompoeNumerosIndependentes() {
        #expect(itn("entre um e dois segundos") == "entre um e dois segundos")
        #expect(itn("capítulos um e dois") == "capítulos um e dois")
        // Horário coloquial: unidade + e + dezena não compõe
        #expect(itn("às duas e vinte") == "às duas e 20")
    }

    @Test("Pontuação quebra o span")
    func pontuacaoQuebraSpan() {
        #expect(itn("vinte, e três") == "20, e três")
    }

    @Test("'cento' pendurado não é número")
    func centoPenduradoNaoConverte() {
        #expect(itn("por cento aqui não é número") == "por cento aqui não é número")
    }

    // MARK: - Contextos que destravam palavras fracas

    @Test("Percentuais")
    func percentuais() {
        #expect(itn("aumentou dez por cento") == "aumentou 10%")
        #expect(itn("cem por cento de certeza") == "100% de certeza")
        #expect(itn("cinco por cento de juros") == "5% de juros")
        #expect(itn("caiu vinte e cinco por cento") == "caiu 25%")
        // ASR já emitiu dígitos
        #expect(itn("uns 50 por cento") == "uns 50%")
    }

    @Test("Decimais com vírgula")
    func decimais() {
        #expect(itn("três vírgula quatorze") == "3,14")
        #expect(itn("um vírgula cinco segundos") == "1,5 segundos")
        #expect(itn("zero vírgula oito") == "0,8")
        #expect(itn("três vírgula zero cinco") == "3,05")
        // Sem acento (ASR pode variar)
        #expect(itn("dois virgula sete") == "2,7")
    }

    @Test("Dia de mês")
    func diaDeMes() {
        #expect(itn("três de julho de dois mil e vinte e seis") == "3 de julho de 2026")
        #expect(itn("cinco de janeiro") == "5 de janeiro")
        // Fora de contexto de data, unidade continua intacta
        #expect(itn("cinco de nós") == "cinco de nós")
    }

    // MARK: - Robustez

    @Test("Texto sem números fica idêntico")
    func textoSemNumeros() {
        let text = "faz o commit e sobe o deploy pro kubernetes, por favor."
        #expect(itn(text) == text)
    }

    @Test("Idempotência: normalizar duas vezes não muda o resultado")
    func idempotencia() {
        let once = itn("aumentou vinte e cinco por cento em dois mil e vinte e seis")
        #expect(itn(once) == once)
    }

    @Test("Case-insensitive no início de frase")
    func caseInsensitive() {
        #expect(itn("Vinte e três arquivos") == "23 arquivos")
    }

    @Test("Preserva espaçamento e pontuação ao redor")
    func preservaEntorno() {
        #expect(itn("total: vinte e três!") == "total: 23!")
        #expect(itn("(cento e dez)") == "(110)")
    }
}

@Suite("PTBRTextNormalizer - capitalização de frases")
struct PTBRTextNormalizerCapitalizationTests {

    private func cap(_ text: String) -> String {
        PTBRTextNormalizer.normalize(text, options: .init(convertNumbers: false, capitalizeSentences: true))
    }

    @Test("Capitaliza início do texto e após pontuação final")
    func capitalizaFrases() {
        #expect(cap("olá mundo. tudo bem? sim! ótimo") == "Olá mundo. Tudo bem? Sim! Ótimo")
    }

    @Test("Quebra de linha inicia frase nova")
    func quebraDeLinha() {
        #expect(cap("primeira linha\nsegunda linha") == "Primeira linha\nSegunda linha")
    }

    @Test("Não mexe em pontos internos (URLs, versões)")
    func naoMexeEmPontosInternos() {
        #expect(cap("veja o site.com agora") == "Veja o site.com agora")
        #expect(cap("versão 1.5 saiu") == "Versão 1.5 saiu")
    }

    @Test("Texto já capitalizado fica idêntico")
    func jaCapitalizado() {
        let text = "Primeira frase. Segunda frase."
        #expect(cap(text) == text)
    }

    @Test("Capitalização desligada não toca o texto")
    func desligadaNaoToca() {
        let text = "git status. npm install"
        let result = PTBRTextNormalizer.normalize(
            text,
            options: .init(convertNumbers: false, capitalizeSentences: false)
        )
        #expect(result == text)
    }
}

@Suite("TextNormalizationSettings")
struct TextNormalizationSettingsTests {

    @Test("Habilitado por default; chave desliga")
    func toggle() {
        let suite = "zspeak-itn-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        #expect(TextNormalizationSettings.isEnabled(defaults) == true)
        defaults.set(false, forKey: TextNormalizationSettings.enabledKey)
        #expect(TextNormalizationSettings.isEnabled(defaults) == false)
    }
}
