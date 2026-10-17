import Foundation
import Observation

/// Loads and saves SyncForge's configuration as JSON in Application Support. Writes are debounced
/// and atomic; nothing is ever written from an audio thread.
@MainActor
@Observable
public final class ProfileStore {
    public var settings: AppSettings { didSet { scheduleSave() } }
    public private(set) var profiles: [String: DeviceProfile] { didSet { scheduleSave() } }
    public var setups: [SavedSetup] { didSet { scheduleSave() } }
    public var customPresets: [EQPreset] { didSet { scheduleSave() } }
    public private(set) var loadError: String?

    @ObservationIgnored public let fileURL: URL?
    @ObservationIgnored private var saveWork: DispatchWorkItem?

    nonisolated public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("SyncForge", isDirectory: true).appendingPathComponent("state.json")
    }

    /// - Parameter fileURL: nil keeps everything in memory (tests, CLI dry runs).
    public init(fileURL: URL? = ProfileStore.defaultURL) {
        self.fileURL = fileURL
        var state = PersistedState()
        var error: String?
        if let url = fileURL, FileManager.default.fileExists(atPath: url.path) {
            do {
                state = try JSONDecoder.syncForge.decode(PersistedState.self, from: Data(contentsOf: url))
            } catch let e {
                error = "Could not read settings (\(e.localizedDescription)). A backup was kept and defaults are used."
                try? FileManager.default.copyItem(at: url, to: url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))"))
            }
        }
        settings = state.settings
        profiles = state.profiles
        setups = state.setups
        customPresets = state.customPresets
        loadError = error
    }

    public func profile(for device: AudioDeviceInfo) -> DeviceProfile {
        profiles[device.uid] ?? DeviceProfile(uid: device.uid, name: device.name, transport: device.transport)
    }

    public func profile(uid: String) -> DeviceProfile? { profiles[uid] }

    /// Creates a profile for a newly seen device (keeps an existing one, refreshing its name).
    public func register(_ device: AudioDeviceInfo) {
        if var p = profiles[device.uid] {
            if p.name != device.name || p.transport != device.transport {
                p.name = device.name
                p.transport = device.transport
                profiles[device.uid] = p
            }
        } else {
            profiles[device.uid] = DeviceProfile(uid: device.uid, name: device.name, transport: device.transport)
        }
    }

    public func update(_ uid: String, _ mutate: (inout DeviceProfile) -> Void) {
        guard var p = profiles[uid] else { return }
        mutate(&p)
        if p != profiles[uid] { profiles[uid] = p }
    }

    public func replace(_ profile: DeviceProfile) { profiles[profile.uid] = profile }

    public func forget(_ uid: String) { profiles[uid] = nil }

    public var allPresets: [EQPreset] { EQPresets.builtIn + customPresets }

    public func saveCustomPreset(name: String, settings: DSPSettings) {
        let preset = EQPreset(name: name, settings: settings)
        if let i = customPresets.firstIndex(where: { $0.name == name }) { customPresets[i] = preset } else { customPresets.append(preset) }
    }

    // MARK: Persistence

    private func scheduleSave() {
        guard fileURL != nil else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveNow() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    public func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        guard let url = fileURL else { return }
        var state = PersistedState()
        state.settings = settings
        state.profiles = profiles
        state.setups = setups
        state.customPresets = customPresets
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder.syncForge.encode(state).write(to: url, options: .atomic)
        } catch {
            loadError = "Could not save settings: \(error.localizedDescription)"
        }
    }
}

extension JSONEncoder {
    static var syncForge: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var syncForge: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
