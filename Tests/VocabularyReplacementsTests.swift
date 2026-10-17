import Foundation
import Testing
@testable import zspeak

@Suite("VocabularyReplacements - fidelidade e passagem única")
struct VocabularyReplacementsTests {
    @Test("Corpus reproduz falhas antigas e exige as saídas corrigidas")
    func regressionCorpus() {
        for row in TextPostProcessingRegressionCorpus.vocabulary {
            let baseline = VocabularyReplacementReference(entries: row.entries).apply(to: row.input)
            let actual = VocabularyReplacements(entries: row.entries).apply(to: row.input)
            #expect(baseline != row.expected, "\(row.name) precisa reproduzir o defeito anterior")
            #expect(actual == row.expected, "\(row.name): \(actual)")
        }
    }

    @Test("Alias longo vence na mesma posição e colisões respeitam ordem cadastrada")
    func priorityAndConflicts() {
        let entries = [
            VocabularyEntry(term: "short", aliases: ["foo"]),
            VocabularyEntry(term: "long", aliases: ["foo bar"]),
            VocabularyEntry(term: "ignored", aliases: ["FOO BAR"])
        ]
        #expect(VocabularyReplacements(entries: entries).apply(to: "foo bar foo") == "long short")
    }

    @Test("Aliases sobrepostos usam o primeiro início e não reinterpretam o resultado")
    func overlappingAliases() {
        let entries = [
            VocabularyEntry(term: "first", aliases: ["foo bar"]),
            VocabularyEntry(term: "second", aliases: ["bar baz qux"])
        ]
        #expect(VocabularyReplacements(entries: entries).apply(to: "foo bar baz qux") == "first baz qux")
    }

    @Test("Símbolos e templates são literais, inclusive barras e cifrões")
    func literalSymbols() {
        let entries = [
            VocabularyEntry(term: ".NET", aliases: [".net"]),
            VocabularyEntry(term: "C++", aliases: ["c++"]),
            VocabularyEntry(term: "$1\\path", aliases: ["dollar path"]),
            VocabularyEntry(term: "@State", aliases: ["@state"])
        ]
        let input = "🧑🏽‍💻 .net, c++, dollar path @state c++x test_net"
        let expected = "🧑🏽‍💻 .NET, C++, $1\\path @State c++x test_net"
        #expect(VocabularyReplacements(entries: entries).apply(to: input) == expected)
    }

    @Test("Case folding e acentos não alteram bytes fora dos matches")
    func unicodeBytesAndCaseFolding() {
        let entries = [VocabularyEntry(term: "Street", aliases: ["straße"]),
                       VocabularyEntry(term: "Codex", aliases: ["co\u{301}dex"])]
        let input = "cafe\u{301}\tSTRASSE\nCÓDEX 🧑🏽‍💻"
        let expected = "cafe\u{301}\tStreet\nCodex 🧑🏽‍💻"
        let output = VocabularyReplacements(entries: entries).apply(to: input)
        #expect(output.utf8.elementsEqual(expected.utf8))
    }

    @Test("Exclusões de composição Unicode preservam o alias original e suas formas canônicas")
    func unicodeCompositionExclusions() {
        for alias in ["\u{0958}", "\u{1F71}"] {
            let entries = [VocabularyEntry(term: "Matched", aliases: [alias])]
            let plan = VocabularyReplacements(entries: entries)
            for input in [alias, alias.uppercased(), alias.lowercased(),
                          alias.precomposedStringWithCanonicalMapping,
                          alias.decomposedStringWithCanonicalMapping] {
                #expect(plan.apply(to: input) == "Matched")
            }
            // A deduplicação canônica não pode apagar a forma original
            // explicitamente cadastrada depois da forma normalizada.
            let normalized = alias.decomposedStringWithCanonicalMapping
            let duplicated = [VocabularyEntry(term: "First", aliases: [normalized]),
                              VocabularyEntry(term: "Second", aliases: [alias])]
            let duplicatedPlan = VocabularyReplacements(entries: duplicated)
            #expect(duplicatedPlan.apply(to: alias) == "First")
            #expect(duplicatedPlan.apply(to: normalized) == "First")
        }
    }

    @Test("Case folding ICU preserva matches e prioridade quando Foundation diverge")
    func unicodeCaseFoldingPriority() {
        for scalar in 0x1C80...0x1C88 {
            let alias = String(Unicode.Scalar(scalar)!)
            let uppercase = alias.uppercased()
            let entries = [VocabularyEntry(term: "First", aliases: [alias])]
            #expect(VocabularyReplacements(entries: entries).apply(to: uppercase) == "First")
            for aliases in [[alias, uppercase.lowercased()], [uppercase.lowercased(), alias]] {
                let colliding = [VocabularyEntry(term: "First", aliases: [aliases[0]]),
                                 VocabularyEntry(term: "Second", aliases: [aliases[1]])]
                let plan = VocabularyReplacements(entries: colliding)
                for input in [alias, uppercase, uppercase.lowercased()] {
                    #expect(plan.apply(to: input) == "First")
                }
            }
        }
        let distinct = [VocabularyEntry(term: "Dotless", aliases: ["ı"]),
                        VocabularyEntry(term: "Latin", aliases: ["i"])]
        #expect(VocabularyReplacements(entries: distinct).apply(to: "I ı") == "Latin Dotless")
    }

    @Test("Planos vazios, desabilitados ou fora da categoria preservam texto")
    func emptyAndFilteredPlans() {
        let entries = [VocabularyEntry(term: "one", aliases: ["foo"], isEnabled: false),
                       VocabularyEntry(term: "two", aliases: ["bar"], context: .dev),
                       VocabularyEntry(term: " ", aliases: ["baz"]),
                       VocabularyEntry(term: "three", aliases: [" ", ""])]
        #expect(VocabularyReplacements(entries: []).apply(to: "foo bar baz") == "foo bar baz")
        #expect(VocabularyReplacements(entries: entries, categories: [.global]).apply(to: "foo bar baz") == "foo bar baz")
        #expect(VocabularyReplacements(entries: entries).apply(to: "") == "")
    }
}
