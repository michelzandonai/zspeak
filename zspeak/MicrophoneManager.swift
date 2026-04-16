import AVFoundation
import AppKit
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
            UserDefaults.standard.set(useSystemDefault, forKey: "useSystemDefaultMic")
        }
    }
    var activeMicrophoneID: String?
    var permissionState: MicrophonePermissionState
    private let skipBundlePermissionCheck: Bool

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
    ///   na ordem salva em UserDefaults.
    func connectedMicrophones() -> [MicrophoneInfo] {
        guard !useSystemDefault else { return [] }
        return microphones.filter(\.isConnected)
    }

    var isPermissionGranted: Bool {
        permissionState.isGranted
    }

    // MARK: - Init

    init(skipBundlePermissionCheck: Bool = false) {
        self.skipBundlePermissionCheck = skipBundlePermissionCheck
        let defaultKey = "useSystemDefaultMic"
        if UserDefaults.standard.object(forKey: defaultKey) != nil {
            self.useSystemDefault = UserDefaults.standard.bool(forKey: defaultKey)
        } else {
            self.useSystemDefault = true
        }
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

        let savedOrder = UserDefaults.standard.stringArray(forKey: "microphonePriorityOrder") ?? []

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
        UserDefaults.standard.set(ids, forKey: "microphonePriorityOrder")
    }

    private var systemDefaultDeviceID: String? {
        AVCaptureDevice.default(for: .audio)?.uniqueID
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
