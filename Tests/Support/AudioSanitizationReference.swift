// Referência congelada anterior à remoção da cópia de PCM válido.
// Usada por regressões e benchmark: não atualizar junto com a implementação.
enum AudioSanitizationReference {
    static func sanitize(_ samples: [Float]) -> [Float] {
        samples.map { sample in
            guard sample.isFinite else { return 0 }
            return min(1, max(-1, sample))
        }
    }
}
