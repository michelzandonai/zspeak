import Foundation
import Testing
@testable import zspeak

@Suite("TranscriptionRecord")
struct TranscriptionRecordTests {

    // Encoder/decoder com .iso8601 — mesmo padrão do TranscriptionStore
    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - Codable round-trip completo

    @Test("Encode→decode preserva todos os campos")
    func testCodableRoundTripComplete() throws {
        let original = TranscriptionRecord(
            id: UUID(),
            text: "Hello world",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            modelName: "Parakeet TDT 0.6B V3",
            duration: 3.456,
            targetAppName: "Xcode",
            audioFileName: "audio-abc123.wav"
        )

        let data = try makeEncoder().encode(original)
        let decoded = try makeDecoder().decode(TranscriptionRecord.self, from: data)

        #expect(decoded.id == original.id)
        #expect(decoded.text == original.text)
        #expect(decoded.timestamp == original.timestamp)
        #expect(decoded.modelName == original.modelName)
        #expect(decoded.duration == original.duration)
        #expect(decoded.targetAppName == original.targetAppName)
        #expect(decoded.audioFileName == original.audioFileName)
    }

    // MARK: - Codable com campos opcionais nil

    @Test("Encode→decode preserva campos opcionais nil")
    func testCodableRoundTripNilOptionals() throws {
        let original = TranscriptionRecord(
            id: UUID(),
            text: "Texto sem app alvo",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            modelName: "Parakeet TDT 0.6B V3",
            duration: 1.0,
            targetAppName: nil,
            audioFileName: nil
        )

        let data = try makeEncoder().encode(original)
        let decoded = try makeDecoder().decode(TranscriptionRecord.self, from: data)

        #expect(decoded.targetAppName == nil)
        #expect(decoded.audioFileName == nil)
    }

    // MARK: - ISO8601 date encoding

    @Test("Timestamp e serializado como string ISO8601 valida no JSON")
    func testISO8601DateEncoding() throws {
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let record = TranscriptionRecord(
            id: UUID(),
            text: "iso8601 test",
            timestamp: fixedDate,
            modelName: "Parakeet TDT 0.6B V3",
            duration: 1.0,
            targetAppName: nil,
            audioFileName: nil
        )

        let data = try makeEncoder().encode(record)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let timestampString = try #require(json["timestamp"] as? String)

        // Verificar que a string e parseable pelo formatter ISO8601
        let formatter = ISO8601DateFormatter()
        let parsedDate = formatter.date(from: timestampString)
        #expect(parsedDate != nil)
    }

    // MARK: - Identifiable conformance

    @Test("Dois records distintos tem ids diferentes")
    func testIdentifiableUniqueness() {
        let record1 = TranscriptionRecord(
            id: UUID(),
            text: "primeiro",
            timestamp: Date(),
            modelName: "Parakeet TDT 0.6B V3",
            duration: 1.0,
            targetAppName: nil,
            audioFileName: nil
        )
        let record2 = TranscriptionRecord(
            id: UUID(),
            text: "segundo",
            timestamp: Date(),
            modelName: "Parakeet TDT 0.6B V3",
            duration: 1.0,
            targetAppName: nil,
            audioFileName: nil
        )

        #expect(record1.id != record2.id)
    }

    // MARK: - Duration preservada

    @Test("Duration e preservada com precisao apos encode→decode")
    func testDurationPreserved() throws {
        let expectedDuration: TimeInterval = 3.456
        let record = TranscriptionRecord(
            id: UUID(),
            text: "duration test",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            modelName: "Parakeet TDT 0.6B V3",
            duration: expectedDuration,
            targetAppName: nil,
            audioFileName: nil
        )

        let data = try makeEncoder().encode(record)
        let decoded = try makeDecoder().decode(TranscriptionRecord.self, from: data)

        #expect(decoded.duration == expectedDuration)
    }
}
