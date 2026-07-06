// Helpers compartilhados para testes do zspeak
// Swift Testing framework — sem XCTest

import Foundation
import Testing

// MARK: - MainActor Helpers

/// Executa bloco no MainActor e retorna o resultado.
/// Útil para testar código @MainActor de forma síncrona em testes async.
@MainActor
func onMain<T: Sendable>(_ block: @MainActor () throws -> T) rethrows -> T {
    try block()
}

/// Aguarda uma condição se tornar verdadeira com timeout.
/// Usa polling com intervalo curto para não bloquear a thread.
func waitUntil(
    timeout: Duration = .seconds(5),
    interval: Duration = .milliseconds(50),
    _ condition: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: interval)
    }
    Issue.record("Timeout: condição não foi satisfeita em \(timeout)")
}

/// Versão MainActor do waitUntil para propriedades @MainActor.
@MainActor
func waitUntilOnMain(
    timeout: Duration = .seconds(5),
    interval: Duration = .milliseconds(50),
    _ condition: @MainActor () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: interval)
    }
    Issue.record("Timeout: condição não foi satisfeita em \(timeout)")
}

// MARK: - Confirmation Helpers

/// Helper para confirmar que um bloco async completa dentro do timeout.
func confirmCompletion(
    timeout: Duration = .seconds(5),
    _ operation: @escaping @Sendable () async throws -> Void
) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TimeoutError(duration: timeout)
        }
        // O primeiro a completar cancela o outro
        try await group.next()
        group.cancelAll()
    }
}

/// Erro de timeout para operações async.
struct TimeoutError: Error, CustomStringConvertible {
    let duration: Duration
    var description: String {
        "Operação não completou dentro de \(duration)"
    }
}

// MARK: - Exclusão mútua do dispositivo de áudio real

/// Mutex global dos testes que abrem o HAL de áudio real (engine.start/warmUp
/// ou override do default input). `.serialized` só serializa DENTRO de uma
/// suíte; suítes diferentes ainda rodam em paralelo e disputam o device global
/// da máquina — a causa do -10868 e da flakiness intermitente em paralelo.
private actor RealAudioDeviceLock {
    static let shared = RealAudioDeviceLock()
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isHeld {
            isHeld = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            // O lock passa direto para o próximo da fila (permanece held)
            waiters.removeFirst().resume()
        }
    }
}

/// Executa `body` com acesso exclusivo ao dispositivo de áudio real.
/// Todo teste que dispara captura real (direta ou via AppState.toggleRecording
/// com modelo pronto) deve envolver o corpo inteiro com este helper.
func withRealAudioDevice<T>(
    isolation: isolated (any Actor)? = #isolation,
    _ body: () async throws -> T
) async rethrows -> T {
    await RealAudioDeviceLock.shared.acquire()
    defer {
        Task { await RealAudioDeviceLock.shared.release() }
    }
    return try await body()
}
