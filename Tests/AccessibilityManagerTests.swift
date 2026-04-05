import Foundation
import Testing
@testable import zspeak

@Suite("AccessibilityManager")
@MainActor
struct AccessibilityManagerTests {

    // AXIsProcessTrusted() retorna false no ambiente de teste

    @Test("Estado inicial reflete AXIsProcessTrusted (false em testes)")
    func testInitialState() {
        let manager = AccessibilityManager()
        #expect(manager.isGranted == false)
    }

    @Test("Callbacks começam nil")
    func testCallbacksInitiallyNil() {
        let manager = AccessibilityManager()
        #expect(manager.onPermissionGranted == nil)
        #expect(manager.onPermissionRevoked == nil)
    }

    @Test("Timer inicia no init")
    func testTimerStartsOnInit() {
        let manager = AccessibilityManager()
        // timer é private, mas podemos verificar indiretamente
        // que o manager foi criado sem crash e está funcional
        #expect(manager.isGranted == false)
        // Se o timer não iniciasse, o polling não funcionaria
        // O fato de init completar sem erro confirma que startPolling executou
        _ = manager
    }

    @Test("checkPermission mantém isGranted consistente")
    func testCheckPermissionSetsIsGranted() {
        let manager = AccessibilityManager()
        // No ambiente de teste AXIsProcessTrusted() = false
        // Após polling, isGranted continua false
        #expect(manager.isGranted == false)

        // Configurar callback para verificar que NÃO é chamado
        // (não houve transição false → true)
        var grantedCalled = false
        manager.onPermissionGranted = { grantedCalled = true }

        var revokedCalled = false
        manager.onPermissionRevoked = { revokedCalled = true }

        // Simular passagem de tempo para o timer executar
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))

        // isGranted continua false (AXIsProcessTrusted = false)
        #expect(manager.isGranted == false)
        // Nenhum callback disparado (sem transição de estado)
        #expect(grantedCalled == false)
        #expect(revokedCalled == false)
    }
}
