import Foundation

/// Fixture de benchmark: WAV + texto esperado (ground truth) + último resultado
struct BenchmarkFixture: Identifiable, Codable {
    let id: UUID
    var name: String           // nome descritivo (ex: "Frase curta PT-BR")
    var expectedText: String   // ground truth validado pelo usuário
    let audioFileName: String  // nome do WAV em benchmarks/audio/
    let duration: TimeInterval // duração do áudio em segundos
    var lastResult: BenchmarkResult?
}

/// Resultado de um benchmark individual
struct BenchmarkResult: Codable {
    let transcribedText: String  // o que o modelo retornou
    let latency: TimeInterval    // tempo de inferência em segundos
    let timestamp: Date          // quando rodou
    let similarity: Double       // Compat: score legado 0.0-1.0 (agora derivado de WER)
    let wordErrorRate: Double?   // 0.0-1.0 — métrica principal para benchmark de ASR
    let characterErrorRate: Double? // 0.0-1.0 — útil para detectar erros finos

    /// Score principal para exibição: quando há WER, usa `1 - WER`; senão, cai no legado.
    var accuracyScore: Double {
        if let wordErrorRate {
            return max(0, 1 - wordErrorRate)
        }
        return max(0, similarity)
    }

    init(
        transcribedText: String,
        latency: TimeInterval,
        timestamp: Date,
        similarity: Double,
        wordErrorRate: Double? = nil,
        characterErrorRate: Double? = nil
    ) {
        self.transcribedText = transcribedText
        self.latency = latency
        self.timestamp = timestamp
        self.similarity = similarity
        self.wordErrorRate = wordErrorRate
        self.characterErrorRate = characterErrorRate
    }

    private enum CodingKeys: String, CodingKey {
        case transcribedText
        case latency
        case timestamp
        case similarity
        case wordErrorRate
        case characterErrorRate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transcribedText = try container.decode(String.self, forKey: .transcribedText)
        latency = try container.decode(TimeInterval.self, forKey: .latency)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        similarity = try container.decodeIfPresent(Double.self, forKey: .similarity) ?? 0
        wordErrorRate = try container.decodeIfPresent(Double.self, forKey: .wordErrorRate)
        characterErrorRate = try container.decodeIfPresent(Double.self, forKey: .characterErrorRate)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(transcribedText, forKey: .transcribedText)
        try container.encode(latency, forKey: .latency)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(similarity, forKey: .similarity)
        try container.encodeIfPresent(wordErrorRate, forKey: .wordErrorRate)
        try container.encodeIfPresent(characterErrorRate, forKey: .characterErrorRate)
    }
}
