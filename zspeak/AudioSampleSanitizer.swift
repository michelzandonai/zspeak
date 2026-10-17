/// Valida PCM Float32 preservando os bits das amostras válidas.
enum AudioSampleSanitizer {
    static func sanitize(_ samples: [Float]) -> [Float] {
        // Arquivos PCM normais já são válidos: mantém o buffer compartilhado,
        // sem alocar e copiar todo o áudio apenas para confirmar o intervalo.
        guard let firstInvalid = samples.firstIndex(where: { !$0.isFinite || $0 < -1 || $0 > 1 }) else {
            return samples
        }
        var result = samples
        for index in firstInvalid..<result.count {
            let sample = result[index]
            result[index] = sample.isFinite ? min(1, max(-1, sample)) : 0
        }
        return result
    }
}
