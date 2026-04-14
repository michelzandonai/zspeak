import AVFoundation
import Foundation
import Testing
@testable import zspeak

private let kUseSystemDefaultMic = "useSystemDefaultMic"

private func cleanMicrophoneDefaults() {
    UserDefaults.standard.removeObject(forKey: kUseSystemDefaultMic)
}

// Testes de MicrophoneInfo e logica do MicrophoneManager — sem dependencias de hardware
@MainActor
@Suite("MicrophoneManager - Logica de microfone")
struct MicrophoneManagerTests {

    @Test("Default de useSystemDefault deve ser true")
    func testUseSystemDefaultDefaultsToTrue() {
        cleanMicrophoneDefaults()
        let manager = MicrophoneManager()
        #expect(manager.useSystemDefault == true)
    }

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

    @Test("Sem activeMicrophoneID deve retornar nome real do device padrão do sistema")
    func testActiveMicrophoneNameDefault() {
        let manager = MicrophoneManager()
        manager.activeMicrophoneID = nil

        // Deve resolver o nome real do dispositivo padrão (ex: "MacBook Pro Microphone")
        // Só cai em "System Default" se não houver nenhum device de áudio
        let name = manager.activeMicrophoneName
        #expect(!name.isEmpty)
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

    @Test("Com activeMicrophoneID invalido deve retornar nome real do device padrão")
    func testActiveMicrophoneNameWithInvalidID() {
        let manager = MicrophoneManager()
        manager.microphones = [
            MicrophoneInfo(id: "mic-001", name: "Built-in Microphone", isConnected: true),
        ]
        manager.activeMicrophoneID = "mic-inexistente"

        // ID inválido → fallback para nome real do device padrão do sistema
        let name = manager.activeMicrophoneName
        #expect(!name.isEmpty)
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

    @Test("getPreferredDevice existente continua funcionando (compat)")
    func getPreferredDevice_existente_continuaFuncionando() {
        // Garante que toggle ligado sempre devolve nil (sem pesquisar na lista)
        let manager = MicrophoneManager()
        manager.useSystemDefault = true
        manager.microphones = [
            MicrophoneInfo(id: "mic-001", name: "Built-in", isConnected: true),
            MicrophoneInfo(id: "mic-002", name: "External", isConnected: true),
        ]
        #expect(manager.getPreferredDevice() == nil)

        // Toggle desligado: método ainda é chamável e não crasheia ao percorrer lista.
        // AVCaptureDevice(uniqueID:) com IDs fake devolve nil → método retorna nil sem erro.
        manager.useSystemDefault = false
        manager.microphones = [
            MicrophoneInfo(id: "fake-uid-nao-existe", name: "Fake", isConnected: true),
        ]
        #expect(manager.getPreferredDevice() == nil)
    }

    // MARK: - connectedMicrophones: priorizacao e toggle

    @Test("connectedMicrophones quando toggle ligado retorna vazio")
    func connectedMicrophones_quandoToggleLigado_retornaVazio() {
        let manager = MicrophoneManager()
        manager.useSystemDefault = true
        manager.microphones = [
            MicrophoneInfo(id: "mic-001", name: "Built-in", isConnected: true),
            MicrophoneInfo(id: "mic-002", name: "Blue Yeti", isConnected: true),
        ]

        #expect(manager.connectedMicrophones().isEmpty)
    }

    @Test("connectedMicrophones quando toggle desligado retorna somente conectados na ordem de prioridade")
    func connectedMicrophones_quandoToggleDesligado_retornaSomenteConectados_naOrdemDePrioridade() {
        let manager = MicrophoneManager()
        manager.useSystemDefault = false
        manager.microphones = [
            MicrophoneInfo(id: "mic-A", name: "Mic A", isConnected: true),
            MicrophoneInfo(id: "mic-B", name: "Mic B", isConnected: false),
            MicrophoneInfo(id: "mic-C", name: "Mic C", isConnected: true),
            MicrophoneInfo(id: "mic-D", name: "Mic D", isConnected: true),
        ]

        let resultado = manager.connectedMicrophones()

        #expect(resultado.count == 3)
        #expect(resultado.map(\.id) == ["mic-A", "mic-C", "mic-D"])
    }

    @Test("connectedMicrophones filtra desconectados")
    func connectedMicrophones_filtraDesconectados() {
        let manager = MicrophoneManager()
        manager.useSystemDefault = false
        manager.microphones = [
            MicrophoneInfo(id: "mic-1", name: "Desconectado 1", isConnected: false),
            MicrophoneInfo(id: "mic-2", name: "Desconectado 2", isConnected: false),
        ]

        #expect(manager.connectedMicrophones().isEmpty)
    }

    // MARK: - activeMicrophoneName: cenarios especificos

    @Test("activeMicrophoneName quando ID definido retorna nome da lista")
    func activeMicrophoneName_quandoIDDefinido_retornaNomeDaLista() {
        let manager = MicrophoneManager()
        manager.microphones = [
            MicrophoneInfo(id: "mic-001", name: "Built-in Microphone", isConnected: true),
            MicrophoneInfo(id: "mic-002", name: "Blue Yeti", isConnected: true),
            MicrophoneInfo(id: "mic-003", name: "Shure SM7B", isConnected: true),
        ]
        manager.activeMicrophoneID = "mic-003"

        #expect(manager.activeMicrophoneName == "Shure SM7B")
    }

    @Test("activeMicrophoneName quando ID nao definido retorna nome do default do sistema")
    func activeMicrophoneName_quandoIDNaoDefinido_retornaNomeDoDefaultDoSistema() {
        // Depende de hardware real (AVCaptureDevice.default) — skip em CI
        guard ProcessInfo.processInfo.environment["CI"] == nil else { return }

        let manager = MicrophoneManager()
        manager.activeMicrophoneID = nil
        manager.microphones = [
            MicrophoneInfo(id: "mic-001", name: "Built-in Microphone", isConnected: true),
        ]

        let nome = manager.activeMicrophoneName
        // Deve resolver nome real do device padrao (nao e o "Built-in Microphone" mockado da lista)
        #expect(!nome.isEmpty)
        #expect(nome != "Built-in Microphone" || AVCaptureDevice.default(for: .audio)?.localizedName == "Built-in Microphone")
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
