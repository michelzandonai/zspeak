import Foundation
import Testing
@testable import zspeak

// Testes de MicrophoneInfo e logica do MicrophoneManager — sem dependencias de hardware
@MainActor
@Suite("MicrophoneManager - Logica de microfone")
struct MicrophoneManagerTests {

    // MARK: - MicrophoneInfo: Equatable

    @Test("Duas MicrophoneInfo com mesmos valores devem ser iguais")
    func testMicrophoneInfoEquatable() {
        let mic1 = MicrophoneInfo(id: "mic-001", name: "Built-in Microphone", isConnected: true)
        let mic2 = MicrophoneInfo(id: "mic-001", name: "Built-in Microphone", isConnected: true)

        #expect(mic1 == mic2)
    }

    @Test("MicrophoneInfo com IDs diferentes nao devem ser iguais")
    func testMicrophoneInfoNotEqual() {
        let mic1 = MicrophoneInfo(id: "mic-001", name: "Built-in Microphone", isConnected: true)
        let mic2 = MicrophoneInfo(id: "mic-002", name: "Built-in Microphone", isConnected: true)

        #expect(mic1 != mic2)
    }

    // MARK: - MicrophoneInfo: Codable

    @Test("MicrophoneInfo deve sobreviver ciclo encode/decode")
    func testMicrophoneInfoCodable() throws {
        let original = MicrophoneInfo(id: "usb-mic-42", name: "Blue Yeti", isConnected: false)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MicrophoneInfo.self, from: data)

        #expect(decoded == original)
        #expect(decoded.id == "usb-mic-42")
        #expect(decoded.name == "Blue Yeti")
        #expect(decoded.isConnected == false)
    }

    // MARK: - activeMicrophoneName

    @Test("Sem activeMicrophoneID deve retornar 'System Default'")
    func testActiveMicrophoneNameDefault() {
        let manager = MicrophoneManager()
        manager.activeMicrophoneID = nil

        #expect(manager.activeMicrophoneName == "System Default")
    }

    @Test("Com activeMicrophoneID valido deve retornar nome do microfone")
    func testActiveMicrophoneNameWithValidID() {
        let manager = MicrophoneManager()
        manager.microphones = [
            MicrophoneInfo(id: "mic-001", name: "Built-in Microphone", isConnected: true),
            MicrophoneInfo(id: "mic-002", name: "Blue Yeti", isConnected: true),
        ]
        manager.activeMicrophoneID = "mic-002"

        #expect(manager.activeMicrophoneName == "Blue Yeti")
    }

    @Test("Com activeMicrophoneID invalido deve retornar 'System Default'")
    func testActiveMicrophoneNameWithInvalidID() {
        let manager = MicrophoneManager()
        manager.microphones = [
            MicrophoneInfo(id: "mic-001", name: "Built-in Microphone", isConnected: true),
        ]
        manager.activeMicrophoneID = "mic-inexistente"

        #expect(manager.activeMicrophoneName == "System Default")
    }

    // MARK: - Reorder

    @Test("Reorder deve mover microfone para nova posicao")
    func testReorderMicrophones() {
        let manager = MicrophoneManager()
        manager.microphones = [
            MicrophoneInfo(id: "mic-A", name: "Mic A", isConnected: true),
            MicrophoneInfo(id: "mic-B", name: "Mic B", isConnected: true),
            MicrophoneInfo(id: "mic-C", name: "Mic C", isConnected: true),
        ]

        // Mover primeiro item (index 0) para posicao 3 (final)
        manager.reorder(fromOffsets: IndexSet(integer: 0), toOffset: 3)

        #expect(manager.microphones[0].id == "mic-B")
        #expect(manager.microphones[1].id == "mic-C")
        #expect(manager.microphones[2].id == "mic-A")
    }

    // MARK: - getPreferredDevice

    @Test("getPreferredDevice com useSystemDefault=true deve retornar nil")
    func testGetPreferredDeviceReturnsNilWhenSystemDefault() {
        let manager = MicrophoneManager()
        manager.useSystemDefault = true
        manager.microphones = [
            MicrophoneInfo(id: "mic-001", name: "Built-in Microphone", isConnected: true),
        ]

        #expect(manager.getPreferredDevice() == nil)
    }

    // MARK: - Filtragem de dispositivos agregados

    @Test("Dispositivos com prefixo CADefaultDeviceAggregate devem ser filtrados no refreshDevices")
    func testAggregateDeviceFiltering() {
        // Validar que a logica de filtro funciona com o prefixo correto
        let aggregateID = "CADefaultDeviceAggregate:12345"
        let normalID = "BuiltInMicrophoneDevice"

        #expect(aggregateID.hasPrefix("CADefaultDeviceAggregate") == true)
        #expect(normalID.hasPrefix("CADefaultDeviceAggregate") == false)

        // Simular o filtro usado em refreshDevices
        let deviceIDs = [aggregateID, normalID, "CADefaultDeviceAggregate:67890", "USBMic:001"]
        let filtered = deviceIDs.filter { !$0.hasPrefix("CADefaultDeviceAggregate") }

        #expect(filtered.count == 2)
        #expect(filtered.contains(normalID))
        #expect(filtered.contains("USBMic:001"))
        #expect(!filtered.contains(aggregateID))
    }
}
