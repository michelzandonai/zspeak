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
    let sourceRecordID: UUID?  // se é resultado de correção LLM, aponta ao registro original
    /// Map speakerId → nome humano renomeado pelo usuário (modo Reunião).
    /// Opcional: registros antigos não têm este campo.
    var speakerNames: [String: String]?

    init(
        id: UUID,
        text: String,
        timestamp: Date,
        modelName: String,
        duration: TimeInterval,
        targetAppName: String?,
        audioFileName: String?,
        sourceRecordID: UUID? = nil,
        speakerNames: [String: String]? = nil
    ) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.modelName = modelName
        self.duration = duration
        self.targetAppName = targetAppName
        self.audioFileName = audioFileName
        self.sourceRecordID = sourceRecordID
        self.speakerNames = speakerNames
    }

    // Decodable backward-compat: arquivos antigos não têm sourceRecordID nem speakerNames
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.text = try c.decode(String.self, forKey: .text)
        self.timestamp = try c.decode(Date.self, forKey: .timestamp)
        self.modelName = try c.decode(String.self, forKey: .modelName)
        self.duration = try c.decode(TimeInterval.self, forKey: .duration)
        self.targetAppName = try c.decodeIfPresent(String.self, forKey: .targetAppName)
        self.audioFileName = try c.decodeIfPresent(String.self, forKey: .audioFileName)
        self.sourceRecordID = try c.decodeIfPresent(UUID.self, forKey: .sourceRecordID)
        self.speakerNames = try c.decodeIfPresent([String: String].self, forKey: .speakerNames)
    }

    /// Retorna o nome customizado do speaker (se houver) ou o ID original
    func displayName(for speakerId: String) -> String {
        speakerNames?[speakerId] ?? speakerId
    }
}
