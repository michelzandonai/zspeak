import Foundation

/// Registro de uma transcrição realizada
struct TranscriptionRecord: Identifiable, Codable {
    let id: UUID
    let text: String           // texto transcrito
    let timestamp: Date        // data/hora da transcrição
    let modelName: String      // ex: "Parakeet TDT 0.6B V3"
    let duration: TimeInterval // tempo de fala em segundos
    let targetAppName: String? // app onde texto foi inserido
    let audioFileName: String? // nome do arquivo WAV salvo (ex: "UUID.wav")
}
