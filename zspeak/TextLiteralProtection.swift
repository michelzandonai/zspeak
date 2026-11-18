import Foundation

/// Trechos já escritos em sintaxe técnica, cujos caracteres têm significado.
enum TextLiteralProtection {
    private static let pattern = try! NSRegularExpression(pattern: #"""
        (?s:```.*?```)|`[^`\r\n]+`|
        (?<![\p{L}\p{M}\p{N}_])(?:
            [a-zA-Z][a-zA-Z0-9+.\-]*://[^\s<>"'`]*[^\s<>"'`.,;:!?)]
            |(?:~|\.{1,2})?[\\/][\p{L}\p{M}\p{N}_]+(?:[_.\\/@+=:\-]+[\p{L}\p{M}\p{N}_]+)*
            |--?[\p{L}][\p{L}\p{M}\p{N}_]*(?:[_.\\/@+=:\-]+[\p{L}\p{M}\p{N}_]+)*
            |[\p{L}\p{M}\p{N}]+(?:[_.\\/@+=:\-]+[\p{L}\p{M}\p{N}_]+)+
        )
        """#, options: .allowCommentsAndWhitespace)

    static func ranges(in text: String) -> [NSRange] {
        pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range)
    }
}
