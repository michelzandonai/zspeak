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
    let similarity: Double       // 0.0-1.0 word overlap
}
