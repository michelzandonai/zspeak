import AVFoundation

struct MicrophoneInfo: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    var isConnected: Bool
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

    var activeMicrophoneName: String {
        if let id = activeMicrophoneID,
           let mic = microphones.first(where: { $0.id == id }) {
            return mic.name
        }
        return "System Default"
    }

    // MARK: - Init

    init() {
        self.useSystemDefault = UserDefaults.standard.bool(forKey: "useSystemDefaultMic")
        refreshDevices()
        observeDeviceChanges()
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
}
