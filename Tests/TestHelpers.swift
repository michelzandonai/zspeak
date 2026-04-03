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
