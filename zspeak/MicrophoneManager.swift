import AVFoundation
import AppKit
import CoreAudio
import os.log

private let logger = Logger(subsystem: "com.zspeak", category: "MicrophoneManager")

struct MicrophoneInfo: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    var isConnected: Bool
}

enum MicrophonePermissionState: Equatable {
    case unavailable
    case notDetermined
    case denied
    case restricted
    case authorized

    init(status: AVAuthorizationStatus, hasUsageDescription: Bool) {
        guard hasUsageDescription else {
            self = .unavailable
            return
        }

        switch status {
        case .notDetermined:
            self = .notDetermined
        case .denied:
            self = .denied
        case .restricted:
            self = .restricted
        case .authorized:
            self = .authorized
        @unknown default:
            self = .denied
        }
    }

    var isGranted: Bool {
        self == .authorized
    }
}

@Observable
@MainActor
final class MicrophoneManager {

    // MARK: - Public properties

    var microphones: [MicrophoneInfo] = []
    var useSystemDefault: Bool {
        didSet {
            defaults.set(useSystemDefault, forKey: "useSystemDefaultMic")
        }
    }
    /// Microfones BLOQUEADOS: nunca são usados — nem como preferido, nem como
    /// fallback, nem quando são o padrão do sistema (a captura redireciona
    /// para o primeiro permitido).
    var blockedMicrophoneIDs: Set<String> {
        didSet {
            defaults.set(Array(blockedMicrophoneIDs).sorted(), forKey: Self.blockedIDsKey)
        }
    }
    var activeMicrophoneID: String?
    var permissionState: MicrophonePermissionState
    private let skipBundlePermissionCheck: Bool
    /// Injetável para testes isolarem persistência (evita corrida entre testes
    /// paralelos escrevendo no `.standard` e vazamento para o app real).
    @ObservationIgnored
    private let defaults: UserDefaults

    static let blockedIDsKey = "blockedMicrophoneIDs"

    /// Seam testável do UID do device padrão do sistema (xctest headless pode
    /// não expor AVCaptureDevice). Consulta o HAL primeiro: é ao default do HAL
    /// que o AVAudioEngine conecta com uid=nil — `AVCaptureDevice.default` pode
    /// divergir dele (ex.: mic Bluetooth vira default no HAL sem refletir ali),
    /// e o bloqueio precisa valer para o device que será usado de fato.
    @ObservationIgnored
    var systemDefaultUIDProvider: () -> String? = {
        MicrophoneManager.halDefaultInputUID() ?? AVCaptureDevice.default(for: .audio)?.uniqueID
    }

    /// UID do device de entrada padrão do HAL (CoreAudio), ou nil se a consulta
    /// falhar (ex.: nenhum device de entrada).
    nonisolated static func halDefaultInputUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else { return nil }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, pointer)
        }
        guard status == noErr else { return nil }
        let result = uid as String
        return result.isEmpty ? nil : result
    }

    // Tokens dos observers de NotificationCenter — removidos no deinit para evitar
    // callbacks em instâncias liberadas durante testes (onde várias instâncias são
    // criadas e descartadas em sequência).
    //
    // `@ObservationIgnored` evita que o macro @Observable injete tracking numa
    // property puramente interna. `nonisolated(unsafe)` é necessário porque em
    // Swift 6 o deinit de classe @MainActor é não-isolado; o acesso é seguro porque
    // escritas só ocorrem no init/observe* (main actor) e a leitura no deinit só
    // roda quando nenhuma outra referência existe.
    @ObservationIgnored
    private nonisolated(unsafe) var observerTokens: [NSObjectProtocol] = []

    // Fonte de verdade do nome do microfone mostrado no overlay durante a gravação.
    // Se `activeMicrophoneID` está setado (device específico em uso), resolve pela lista.
    // Caso contrário (toggle "System Default" ligado OU fallback), devolve o nome real do
    // device padrão do sistema via AVCaptureDevice.default. Só cai na string genérica
    // "System Default" se o sistema não expuser nenhum device de áudio.
    var activeMicrophoneName: String {
        if let id = activeMicrophoneID,
           let mic = microphones.first(where: { $0.id == id }) {
            return mic.name
        }
        return AVCaptureDevice.default(for: .audio)?.localizedName ?? "System Default"
    }

    /// Lista de microfones conectados em ordem de prioridade.
    /// - Retorna array vazio quando `useSystemDefault == true` (sinaliza ao chamador
    ///   que deve usar o device padrão do sistema em vez de escolher da lista).
    /// - Caso contrário, devolve somente os `microphones` com `isConnected == true`
    ///   e NÃO bloqueados, na ordem salva em UserDefaults.
    func connectedMicrophones() -> [MicrophoneInfo] {
        guard !useSystemDefault else { return [] }
        return microphones.filter { $0.isConnected && !blockedMicrophoneIDs.contains($0.id) }
    }

    func isBlocked(_ id: String) -> Bool {
        blockedMicrophoneIDs.contains(id)
    }

    func setBlocked(_ id: String, blocked: Bool) {
        if blocked {
            blockedMicrophoneIDs.insert(id)
        } else {
            blockedMicrophoneIDs.remove(id)
        }
    }

    /// Candidatos de captura para a próxima gravação, na ordem de tentativa
    /// (máx. 2 — cada retry custa 100–300 ms de engine.start()). `nil` = device
    /// padrão do sistema. Lista VAZIA = nenhum microfone permitido (todos
    /// bloqueados/desconectados) — o chamador deve falhar com mensagem clara.
    ///
    /// Regras:
    /// - Padrão do sistema em uso e não bloqueado → [default].
    /// - Padrão do sistema em uso mas BLOQUEADO → redireciona para o primeiro
    ///   conectado permitido (explícito, nunca o default).
    /// - Ordem de prioridade: preferido permitido + fallback (default se não
    ///   bloqueado; senão o próximo permitido da lista).
    func recordingCandidateUIDs() -> [String?] {
        let defaultUID = systemDefaultUIDProvider()
        let defaultBlocked = defaultUID.map { blockedMicrophoneIDs.contains($0) } ?? false
        let allowedConnected = microphones.filter {
            $0.isConnected && !blockedMicrophoneIDs.contains($0.id)
        }

        if useSystemDefault {
            if !defaultBlocked { return [nil] }
            return allowedConnected.prefix(1).map { $0.id as String? }
        }

        var candidates: [String?] = []
        if let preferred = allowedConnected.first?.id {
            candidates.append(preferred)
        }
        if !defaultBlocked {
            candidates.append(nil)
        } else if allowedConnected.count > 1 {
            candidates.append(allowedConnected[1].id)
        }
        return candidates
    }

    var isPermissionGranted: Bool {
        permissionState.isGranted
    }

    // MARK: - Init

    init(skipBundlePermissionCheck: Bool = false, defaults: UserDefaults = .standard) {
        self.skipBundlePermissionCheck = skipBundlePermissionCheck
        self.defaults = defaults
        let defaultKey = "useSystemDefaultMic"
        if defaults.object(forKey: defaultKey) != nil {
            self.useSystemDefault = defaults.bool(forKey: defaultKey)
        } else {
            self.useSystemDefault = true
        }
        self.blockedMicrophoneIDs = Set(
            defaults.stringArray(forKey: Self.blockedIDsKey) ?? []
        )
        self.permissionState = .notDetermined
        refreshPermissionState()
        refreshDevices()
        observeDeviceChanges()
        observeAppActivation()
    }

    deinit {
        // Remove observers registrados por self para evitar callbacks após liberação.
        // Os closures usam [weak self] e o Task { @MainActor in ... } faz hop para a
        // main thread — aqui só invalidamos a subscrição.
        let center = NotificationCenter.default
        for token in observerTokens {
            center.removeObserver(token)
        }
    }

    // MARK: - Public methods

    func reorder(fromOffsets source: IndexSet, toOffset destination: Int) {
        microphones.move(fromOffsets: source, toOffset: destination)
        savePriorityOrder()
    }

    func refreshDevices() {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        // Filtra dispositivos agregados internos do CoreAudio (criados por Teams, Zoom, etc.)
        let connectedDevices = session.devices.filter { device in
            !device.uniqueID.hasPrefix("CADefaultDeviceAggregate")
        }

        let savedOrder = defaults.stringArray(forKey: "microphonePriorityOrder") ?? []

        // Build ordered list: saved order first, then new devices
        var ordered: [MicrophoneInfo] = []
        var seen = Set<String>()

        // Existing items in saved priority order
        for id in savedOrder {
            seen.insert(id)
            if let device = connectedDevices.first(where: { $0.uniqueID == id }) {
                ordered.append(MicrophoneInfo(id: id, name: device.localizedName, isConnected: true))
            } else {
                // Keep disconnected devices from saved order
                let existingName = microphones.first(where: { $0.id == id })?.name ?? id
                ordered.append(MicrophoneInfo(id: id, name: existingName, isConnected: false))
            }
        }

        // New devices not in saved order — append at end
        for device in connectedDevices where !seen.contains(device.uniqueID) {
            ordered.append(MicrophoneInfo(
                id: device.uniqueID,
                name: device.localizedName,
                isConnected: true
            ))
        }

        microphones = ordered
        savePriorityOrder()
    }

    func refreshPermissionState() {
        permissionState = MicrophonePermissionState(
            status: AVCaptureDevice.authorizationStatus(for: .audio),
            hasUsageDescription: hasMicrophoneUsageDescription
        )
    }

    func requestPermissionIfNeeded() async -> Bool {
        refreshPermissionState()

        switch permissionState {
        case .authorized:
            return true
        case .unavailable, .denied, .restricted:
            return false
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
            refreshPermissionState()
            if granted {
                refreshDevices()
            }
            return granted
        }
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Retorna o primeiro `AVCaptureDevice` na ordem de prioridade, ou `nil` se
    /// `useSystemDefault == true` (caller deve usar o default do sistema).
    ///
    /// Não é mais usado no app real — o pipeline de captura itera `connectedMicrophones()`
    /// diretamente em `AppState.startRecording` e troca o default do HAL via
    /// `AudioCapture.overrideSystemDefaultInput`. Mantido apenas para não quebrar testes
    /// legados em `Tests/MicrophoneManagerTests.swift`.
    @available(*, deprecated, message: "Use connectedMicrophones() + AudioCapture.overrideSystemDefaultInput")
    func getPreferredDevice() -> AVCaptureDevice? {
        guard !useSystemDefault else {
            logger.debug("getPreferredDevice: useSystemDefault=true → usando device padrão do sistema")
            return nil
        }
        for mic in microphones {
            guard mic.isConnected else {
                logger.debug("getPreferredDevice: pulando mic desconectado id=\(mic.id, privacy: .public) nome=\(mic.name, privacy: .public)")
                continue
            }
            if let device = AVCaptureDevice(uniqueID: mic.id) {
                logger.debug("getPreferredDevice: escolhido id=\(mic.id, privacy: .public) nome=\(mic.name, privacy: .public)")
                return device
            } else {
                logger.debug("getPreferredDevice: AVCaptureDevice(uniqueID:) retornou nil para id=\(mic.id, privacy: .public) nome=\(mic.name, privacy: .public)")
            }
        }
        logger.debug("getPreferredDevice: nenhum mic da lista disponível → fallback para system default")
        return nil
    }

    // MARK: - Private

    private func savePriorityOrder() {
        let ids = microphones.map(\.id)
        defaults.set(ids, forKey: "microphonePriorityOrder")
    }

    /// Em builds SwiftPM executáveis, o bundle costuma não carregar o Info.plist do app.
    /// Nesse caso, pedir acesso ao microfone pode encerrar o processo; tratamos como indisponível.
    private var hasMicrophoneUsageDescription: Bool {
        if skipBundlePermissionCheck {
            return true
        }

        guard let usage = Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String else {
            return false
        }
        return !usage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func observeDeviceChanges() {
        let center = NotificationCenter.default

        let connectedToken = center.addObserver(
            forName: .AVCaptureDeviceWasConnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDevices()
            }
        }
        observerTokens.append(connectedToken)

        let disconnectedToken = center.addObserver(
            forName: .AVCaptureDeviceWasDisconnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDevices()
            }
        }
        observerTokens.append(disconnectedToken)
    }

    private func observeAppActivation() {
        let token = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPermissionState()
                self?.refreshDevices()
            }
        }
        observerTokens.append(token)
    }
}
