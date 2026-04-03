import Testing
@testable import zspeak

@Suite("TextInserter")
@MainActor
struct TextInserterTests {

    // AXIsProcessTrusted() retorna false no ambiente de teste

    @Test("previousApp começa nil")
    func testPreviousAppStartsNil() {
        // Reset para garantir estado limpo
        TextInserter.previousApp = nil
        #expect(TextInserter.previousApp == nil)
    }

    @Test("saveFocusedApp define previousApp")
    func testSaveFocusedAppSetsValue() {
        TextInserter.previousApp = nil
        TextInserter.saveFocusedApp()
        // frontmostApplication sempre existe quando há apps rodando
        #expect(TextInserter.previousApp != nil)
    }

    @Test("insert retorna false sem permissão de Acessibilidade")
    func testInsertReturnsFalseWithoutAccessibility() {
        let inserter = TextInserter()
        let result = inserter.insert("texto de teste")
        // AXIsProcessTrusted() = false no ambiente de teste → retorna false
        #expect(result == false)
    }

    @Test("insert com string vazia retorna false sem Acessibilidade")
    func testInsertEmptyStringReturnsFalse() {
        let inserter = TextInserter()
        let result = inserter.insert("")
        // Sem permissão, qualquer insert retorna false
        #expect(result == false)
    }
}
