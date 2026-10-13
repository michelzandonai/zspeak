import AVFoundation
import CoreGraphics
import CoreAudio
import Foundation
import Testing
@testable import zspeak

@Suite("SystemAudioCapture - Integração real", .serialized, .disabled(
    if: ProcessInfo.processInfo.environment["ZSPEAK_TEST_SYSTEM_AUDIO"] != "1",
    "Ative ZSPEAK_TEST_SYSTEM_AUDIO=1 em uma sessão macOS com permissão de captura."
))
struct SystemAudioCaptureIntegrationTests {
    @Test("Captura áudio reproduzido por outro processo via ScreenCaptureKit")
    func capturesKnownPlayback() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            Issue.record("O processo de teste não tem permissão de Gravação de tela e áudio do sistema. Nenhum prompt foi aberto.")
            return
        }
        let capture = SystemAudioCapture()
        let samples = SystemAudioIntegrationSamples()
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/pt-short.wav").path]
        player.standardOutput = FileHandle.nullDevice
        player.standardError = FileHandle.nullDevice
        do {
            try await capture.prepare()
            try await capture.start { samples.append($0) }
            try player.run()
            try await Task.sleep(for: .seconds(4))
            if player.isRunning { player.terminate() }
            await capture.stop()
            #expect(samples.count >= 16_000, "Deve capturar pelo menos 1 segundo de reprodução")
            #expect(samples.voicedCount > 1000, "A captura deve conter sinal, não apenas silêncio")
            #expect(samples.timestampsUseHostClock, "Timestamps devem usar o mesmo relógio do microfone")
        } catch {
            if player.isRunning { player.terminate() }
            await capture.stop()
            throw error
        }
    }

    @Test("Microfone real + reprodução do computador gera transcrição local da fixture")
    func combinedCaptureTranscribesPlaybackWithRealMicrophone() async throws {
        guard CGPreflightScreenCaptureAccess(), AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            Issue.record("O processo de teste precisa de permissões de microfone e captura. Nenhum prompt foi aberto.")
            return
        }
        let capture = RecordingAudioCapture(includesSystemAudio: { true }, includesMicrophone: { true })
        let firstMicrophoneSample = AtomicInt()
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/pt-short.wav").path]
        player.standardOutput = FileHandle.nullDevice
        player.standardError = FileHandle.nullDevice
        do {
            let startedAt = ContinuousClock.now
            try await capture.start(deviceUID: nil, onFirstSample: { firstMicrophoneSample.increment() }, onSamples: nil)
            try await waitUntil { firstMicrophoneSample.current == 1 }
            let startMilliseconds = Self.milliseconds(startedAt.duration(to: .now))
            try player.run()
            try await Task.sleep(for: .seconds(4))
            if player.isRunning { player.terminate() }
            #expect(await capture.isReceivingAudio(), "As duas fontes devem continuar ativas")
            let stopStartedAt = ContinuousClock.now
            let mixed = await capture.stop()
            let stopMilliseconds = Self.milliseconds(stopStartedAt.duration(to: .now))
            #expect(mixed.count >= 16_000)
            let transcriber = Transcriber()
            try await transcriber.initialize()
            let asrStartedAt = ContinuousClock.now
            let transcript = try await transcriber.transcribe(mixed)
            let asrMilliseconds = Self.milliseconds(asrStartedAt.duration(to: .now))
            let normalized = transcript.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))
            let matchesFixture = normalized.contains("ola") && normalized.contains("mundo")
            #expect(matchesFixture, "A transcrição deve reconhecer a fala reproduzida pela fixture")
            print(String(format: "[CAPTURE PERF] first_mic_ms=%.2f stop_ms=%.2f asr_ms=%.2f audio_seconds=%.2f fixture_recognized=%@", startMilliseconds, stopMilliseconds, asrMilliseconds, Double(mixed.count) / 16_000, matchesFixture ? "true" : "false"))
            #expect(startMilliseconds < 2_000, "Início deve caber no watchdog de 2 s do controller")
        } catch {
            if player.isRunning { player.terminate() }
            _ = await capture.stop()
            throw error
        }
    }

    @Test("Só computador transcreve reprodução sem mudar os dispositivos de entrada e saída")
    func systemOnlyPreservesAudioRoute() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            Issue.record("O processo de teste precisa de permissão de captura. Nenhum prompt foi aberto.")
            return
        }
        let outputBefore = try Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        let inputBefore = try Self.defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        let capture = RecordingAudioCapture(includesSystemAudio: { true }, includesMicrophone: { false })
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/pt-short.wav").path]
        player.standardOutput = FileHandle.nullDevice
        player.standardError = FileHandle.nullDevice
        do {
            try await capture.warmUp(deviceUID: nil)
            try await capture.start(deviceUID: nil, onFirstSample: nil, onSamples: nil)
            try player.run()
            // Verifica durante a reprodução, além de antes/depois da captura.
            for _ in 0..<16 {
                try await Task.sleep(for: .milliseconds(250))
                #expect(try Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) == outputBefore)
                #expect(try Self.defaultDevice(kAudioHardwarePropertyDefaultInputDevice) == inputBefore)
            }
            if player.isRunning { player.terminate() }
            let samples = await capture.stop()
            #expect(samples.filter { abs($0) > 0.001 }.count > 1000)
            #expect(try Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) == outputBefore)
            #expect(try Self.defaultDevice(kAudioHardwarePropertyDefaultInputDevice) == inputBefore)
            let transcriber = Transcriber()
            try await transcriber.initialize()
            let text = try await transcriber.transcribe(samples)
            let normalized = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))
            #expect(normalized.contains("ola") && normalized.contains("mundo"))
        } catch {
            if player.isRunning { player.terminate() }
            _ = await capture.stop()
            throw error
        }
    }

    @Test("Troca real computador, microfone e computador mantém as duas falas no resultado")
    func switchingSourcesPreservesRealPlayback() async throws {
        guard CGPreflightScreenCaptureAccess(), AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            Issue.record("O processo de teste precisa de permissões de microfone e captura. Nenhum prompt foi aberto.")
            return
        }
        let outputBefore = try Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        let capture = RecordingAudioCapture(includesSystemAudio: { true }, includesMicrophone: { false })
        let ready = AtomicInt()
        do {
            try await capture.start(deviceUID: nil, onFirstSample: { ready.increment() }, onSamples: nil)
            try await Self.playFixture()
            try await capture.switchSource(deviceUID: nil, includesSystemAudio: false)
            try await Task.sleep(for: .milliseconds(500))
            #expect(await capture.isReceivingAudio())
            try await capture.switchSource(deviceUID: nil, includesSystemAudio: true)
            #expect(try Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) == outputBefore)
            try await Self.playFixture()
            let samples = await capture.stop()
            #expect(ready.current == 1)
            #expect(samples.count > 90_000)
            #expect(try Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) == outputBefore)
            let transcriber = Transcriber()
            try await transcriber.initialize()
            let text = try await transcriber.transcribe(samples)
            let normalized = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))
            #expect(normalized.components(separatedBy: "mundo").count >= 3, "As duas reproduções, antes e depois da troca, devem sobreviver")
        } catch {
            _ = await capture.stop()
            throw error
        }
    }

    private static func playFixture() async throws {
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/pt-short.wav").path]
        player.standardOutput = FileHandle.nullDevice
        player.standardError = FileHandle.nullDevice
        try player.run()
        defer { if player.isRunning { player.terminate() } }
        try await Task.sleep(for: .seconds(4))
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return device
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }
}

private final class SystemAudioIntegrationSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var sampleCount = 0
    private var nonSilentCount = 0
    private var timestampsValid = true
    var count: Int { lock.withLock { sampleCount } }
    var voicedCount: Int { lock.withLock { nonSilentCount } }
    var timestampsUseHostClock: Bool { lock.withLock { timestampsValid } }
    func append(_ samples: [Float]) {
        lock.withLock {
            sampleCount += samples.count
            nonSilentCount += samples.filter { abs($0) > 0.001 }.count
        }
    }

    func append(_ chunk: TimestampedAudioChunk) {
        append(chunk.samples)
        lock.withLock { timestampsValid = timestampsValid && abs(chunk.startTime - audioHostTime()) < 2 }
    }
}
