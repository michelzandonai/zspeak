// Testes para ActivationKeyManager, ActivationKey e ActivationMode
// Swift Testing framework

import Foundation
import Testing
@testable import zspeak

// Keys usadas pelo ActivationKeyManager no UserDefaults
private let kActivationKey = "activationKey"
private let kActivationMode = "activationMode"
private let kEscapeToCancel = "escapeToCancel"
private let kCustomShortcutDescription = "customShortcutDescription"

/// Limpa as keys do UserDefaults usadas pelo ActivationKeyManager
private func cleanDefaults() {
    let defaults = UserDefaults.standard
    defaults.removeObject(forKey: kActivationKey)
    defaults.removeObject(forKey: kActivationMode)
    defaults.removeObject(forKey: kEscapeToCancel)
    defaults.removeObject(forKey: kCustomShortcutDescription)
}

// MARK: - Defaults do ActivationKeyManager

@Suite("ActivationKeyManager defaults")
struct ActivationKeyManagerDefaultsTests {

    @Test("Default selectedKey é .rightCommand")
    @MainActor
    func testDefaultSelectedKey() {
        cleanDefaults()
        let manager = ActivationKeyManager()
        #expect(manager.selectedKey == .rightCommand)
    }

    @Test("Default activationMode é .toggle")
    @MainActor
    func testDefaultActivationMode() {
        cleanDefaults()
        let manager = ActivationKeyManager()
        #expect(manager.activationMode == .toggle)
    }

    @Test("Default escapeToCancel é true")
    @MainActor
    func testDefaultEscapeToCancel() {
        cleanDefaults()
        let manager = ActivationKeyManager()
        #expect(manager.escapeToCancel == true)
    }
}

// MARK: - Unicidade de raw values

@Suite("Unicidade de raw values")
struct UniquenessTests {

    @Test("Todos os ActivationKey cases têm rawValues únicos")
    func testAllActivationKeysHaveUniqueRawValues() {
        let rawValues = ActivationKey.allCases.map(\.rawValue)
        let uniqueValues = Set(rawValues)
        #expect(rawValues.count == uniqueValues.count,
                "Encontrados rawValues duplicados em ActivationKey")
    }

    @Test("Todos os ActivationMode cases têm rawValues únicos")
    func testAllActivationModesHaveUniqueRawValues() {
        let rawValues = ActivationMode.allCases.map(\.rawValue)
        let uniqueValues = Set(rawValues)
        #expect(rawValues.count == uniqueValues.count,
                "Encontrados rawValues duplicados em ActivationMode")
    }
}

// MARK: - Identifiable

@Suite("ActivationKey Identifiable")
struct ActivationKeyIdentifiableTests {

    @Test("id é igual ao rawValue para todos os cases")
    func testActivationKeyIdentifiable() {
        for key in ActivationKey.allCases {
            #expect(key.id == key.rawValue,
                    "ActivationKey.\(key) — id (\(key.id)) difere de rawValue (\(key.rawValue))")
        }
    }
}

// MARK: - Codable

@Suite("Codable round-trip")
struct CodableTests {

    @Test("ActivationKey encode/decode ciclo completo para todos os cases")
    func testActivationKeyCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for key in ActivationKey.allCases {
            let data = try encoder.encode(key)
            let decoded = try decoder.decode(ActivationKey.self, from: data)
            #expect(decoded == key,
                    "ActivationKey.\(key) não sobreviveu ao ciclo encode/decode")
        }
    }

    @Test("ActivationMode encode/decode ciclo completo para todos os cases")
    func testActivationModeCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for mode in ActivationMode.allCases {
            let data = try encoder.encode(mode)
            let decoded = try decoder.decode(ActivationMode.self, from: data)
            #expect(decoded == mode,
                    "ActivationMode.\(mode) não sobreviveu ao ciclo encode/decode")
        }
    }
}
