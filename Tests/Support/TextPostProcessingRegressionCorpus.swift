import Foundation
#if canImport(zspeak)
@testable import zspeak
#endif

/// Pequeno corpus de defeitos reproduzíveis; não é benchmark de qualidade ASR.
enum TextPostProcessingRegressionCorpus {
    struct VocabularyCase {
        let name: String
        let entries: [VocabularyEntry]
        let input: String
        let expected: String
    }

    static var vocabulary: [VocabularyCase] {
        [
            .init(name: "cascade", entries: [
                .init(term: "alpha", aliases: ["start here"]),
                .init(term: "omega", aliases: ["alpha"])
            ], input: "start here alpha", expected: "alpha omega"),
            .init(name: "inserted-term-part", entries: [
                .init(term: "foo bar", aliases: ["fubar"]),
                .init(term: "baz", aliases: ["bar"])
            ], input: "fubar e bar", expected: "foo bar e baz"),
            .init(name: "snake-case", entries: [
                .init(term: "push", aliases: ["posh"])
            ], input: "posh_name name_posh posh", expected: "posh_name name_posh push"),
            .init(name: "combining-mark-boundary", entries: [
                .init(term: "Coffee", aliases: ["cafe"])
            ], input: "cafe\u{301} cafe", expected: "cafe\u{301} Coffee"),
            .init(name: "canonical-unicode-alias", entries: [
                .init(term: "Codex", aliases: ["códex"])
            ], input: "abrir co\u{301}dex", expected: "abrir Codex")
        ]
    }

    struct NumberCase {
        let name: String
        let input: String
        let expected: String
    }

    static let numbers: [NumberCase] = [
        .init(name: "fraction-leading-zero", input: "três vírgula 05", expected: "3,05"),
        .init(name: "written-decimal-percent", input: "1,05 por cento", expected: "1,05%"),
        .init(name: "spoken-decimal-percent", input: "zero vírgula cinco por cento", expected: "0,5%"),
        .init(name: "fraction-precision", input: "zero vírgula 001234567890123456789012345", expected: "0,001234567890123456789012345"),
        .init(name: "article-after-number", input: "paguei vinte uma vez", expected: "paguei 20 uma vez")
    ]
}
