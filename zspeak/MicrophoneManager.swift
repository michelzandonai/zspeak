import AVFoundation
import AppKit

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

    var activeMicrophoneName: String {
        if let id = activeMicrophoneID,
           let mic = microphones.first(where: { $0.id == id }) {
            return mic.name
        }
        // Resolve o nome real do dispositivo padrão do sistema
        return AVCaptureDevice.default(for: .audio)?.localizedName ?? "System Default"
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

    func getPreferredDevice() -> AVCaptureDevice? {
        guard !useSystemDefault else { return nil }
        for mic in microphones where mic.isConnected {
            if let device = AVCaptureDevice(uniqueID: mic.id) {
                return device
            }
        }
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
        NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasConnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDevices()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasDisconnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDevices()
            }
        }
    }

    private func observeAppActivation() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPermissionState()
                self?.refreshDevices()
            }
        }
    }
}
