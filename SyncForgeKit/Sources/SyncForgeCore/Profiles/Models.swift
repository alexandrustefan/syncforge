import Foundation

public enum ChannelMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case stereo, mono, leftOnly, rightOnly, swapped
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .stereo: return "Stereo"
        case .mono: return "Mono (L+R)"
        case .leftOnly: return "Left only"
        case .rightOnly: return "Right only"
        case .swapped: return "Swap L/R"
        }
    }
}

public enum DelayMode: String, Codable, CaseIterable, Sendable {
    /// Compensation computed from measured (or driver-estimated) latencies, plus a fine trim.
    case automatic
    /// A fixed user-entered delay.
    case manual
}

public enum MeasurementConfidence: String, Codable, Sendable, Comparable {
    case failed, low, medium, high
    private var rank: Int { ["failed": 0, "low": 1, "medium": 2, "high": 3][rawValue]! }
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

/// The result of an acoustic latency measurement, stored per device.
public struct CalibrationRecord: Codable, Hashable, Sendable {
    /// Acoustic output latency: from the IO time stamp to sound arriving at the microphone, ms.
    public var latencyMs: Double
    /// Spread (max - min) of the accepted repetitions, ms.
    public var spreadMs: Double
    public var peakToNoiseDb: Double
    public var confidence: MeasurementConfidence
    public var repetitions: Int
    public var date: Date
    public var microphoneUID: String
    /// The driver-reported latency at the time of measurement (detects latency changes later).
    public var reportedLatencyMs: Double
    public var needsRecalibration: Bool = false
    public var recalibrationReason: String?
    /// Smoothed response measured at the microphone (AutoEQ.grid, normalised), for display.
    public var responseDb: [Double?]?

    public init(latencyMs: Double, spreadMs: Double, peakToNoiseDb: Double, confidence: MeasurementConfidence,
                repetitions: Int, date: Date, microphoneUID: String, reportedLatencyMs: Double) {
        self.latencyMs = latencyMs
        self.spreadMs = spreadMs
        self.peakToNoiseDb = peakToNoiseDb
        self.confidence = confidence
        self.repetitions = repetitions
        self.date = date
        self.microphoneUID = microphoneUID
        self.reportedLatencyMs = reportedLatencyMs
    }
}

/// Persistent settings for one output device, keyed by its Core Audio UID.
public struct DeviceProfile: Codable, Hashable, Sendable, Identifiable {
    public var id: String { uid }
    public var uid: String
    public var name: String
    public var transport: TransportKind
    public var enabled: Bool = false
    public var volume: Double = 1.0
    public var muted: Bool = false
    public var channelMode: ChannelMode = .stereo
    /// 1-based device channels used for L / R (nil: the device's preferred stereo pair).
    public var leftChannel: Int?
    public var rightChannel: Int?
    public var delayMode: DelayMode = .automatic
    public var manualDelayMs: Double = 0
    public var trimMs: Double = 0
    public var calibration: CalibrationRecord?
    public var dsp: DSPSettings = .flat
    /// Whether the system-wide EQ is applied to this output (before its own EQ).
    public var useSystemEQ: Bool = true
    /// Level trim from calibration level matching (dB, applied with the volume; positive values rely on
    /// the limiter).
    public var levelTrimDb: Double = 0
    /// Tone-matching correction from calibration (applied before the output's own EQ).
    public var correction: [EQBand] = []
    public var correctionEnabled: Bool = true

    public init(uid: String, name: String, transport: TransportKind) {
        self.uid = uid
        self.name = name
        self.transport = transport
    }

    enum CodingKeys: String, CodingKey {
        case uid, name, transport, enabled, volume, muted, channelMode, leftChannel, rightChannel
        case delayMode, manualDelayMs, trimMs, calibration, dsp, useSystemEQ, levelTrimDb, correction, correctionEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uid = try c.decode(String.self, forKey: .uid)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? uid
        transport = (try? c.decodeIfPresent(TransportKind.self, forKey: .transport)) ?? .unknown
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        channelMode = (try? c.decodeIfPresent(ChannelMode.self, forKey: .channelMode)) ?? .stereo
        leftChannel = try c.decodeIfPresent(Int.self, forKey: .leftChannel)
        rightChannel = try c.decodeIfPresent(Int.self, forKey: .rightChannel)
        delayMode = (try? c.decodeIfPresent(DelayMode.self, forKey: .delayMode)) ?? .automatic
        manualDelayMs = try c.decodeIfPresent(Double.self, forKey: .manualDelayMs) ?? 0
        trimMs = try c.decodeIfPresent(Double.self, forKey: .trimMs) ?? 0
        calibration = try? c.decodeIfPresent(CalibrationRecord.self, forKey: .calibration)
        dsp = (try? c.decodeIfPresent(DSPSettings.self, forKey: .dsp)) ?? .flat
        useSystemEQ = try c.decodeIfPresent(Bool.self, forKey: .useSystemEQ) ?? true
        levelTrimDb = try c.decodeIfPresent(Double.self, forKey: .levelTrimDb) ?? 0
        correction = (try? c.decodeIfPresent([EQBand].self, forKey: .correction)) ?? []
        correctionEnabled = try c.decodeIfPresent(Bool.self, forKey: .correctionEnabled) ?? true
    }
}

/// Global application settings.
public struct AppSettings: Codable, Hashable, Sendable {
    public var engineEnabled = false
    public var masterVolume: Double = 1.0
    public var masterMuted = false
    /// Scale non-default outputs by the macOS volume of the default output device, so the volume
    /// keys control every output together.
    public var linkSystemVolume = true
    /// Common buffering added to every output (covers capture and IO cycle jitter).
    public var baseLatencyMs: Double = 45
    public var autoBaseLatency = true
    public var maxDelayMs: Double = 3000
    public var showVirtualDevices = false
    public var showAggregateDevices = false
    public var calibrationMicrophoneUID: String?
    public var calibrationLevelDb: Double = -18
    public var calibrationMaxLatencyMs: Double = 2500
    public var calibrationRepetitions = 5
    public var verifyAfterCalibration = true
    public var matchLevelsAfterCalibration = false
    public var autoRecalibrateOnReconnect = false
    public var reconnectFadeInSeconds: Double = 2.0
    public var launchAtLogin = false
    /// System-wide EQ applied to every output that has `useSystemEQ` (limiter fields unused).
    public var systemDSP: DSPSettings = .flat
    /// Room-resonance cuts from calibration (applied before the system EQ).
    public var roomCorrection: [EQBand] = []
    public var roomCorrectionEnabled = true
    public var autoEQAfterCalibration = true
    /// Continuously keep a wireless output in sync using the microphone while music plays.
    public var liveSyncEnabled = false
    public var liveSyncAfterCalibration = true

    public init() {}

    enum CodingKeys: String, CodingKey {
        case engineEnabled, masterVolume, masterMuted, linkSystemVolume, baseLatencyMs, autoBaseLatency, maxDelayMs
        case showVirtualDevices, showAggregateDevices, calibrationMicrophoneUID, calibrationLevelDb
        case calibrationMaxLatencyMs, calibrationRepetitions, verifyAfterCalibration, matchLevelsAfterCalibration, autoRecalibrateOnReconnect
        case reconnectFadeInSeconds, launchAtLogin, systemDSP, roomCorrection, roomCorrectionEnabled, autoEQAfterCalibration, liveSyncEnabled, liveSyncAfterCalibration
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        engineEnabled = try c.decodeIfPresent(Bool.self, forKey: .engineEnabled) ?? d.engineEnabled
        masterVolume = try c.decodeIfPresent(Double.self, forKey: .masterVolume) ?? d.masterVolume
        masterMuted = try c.decodeIfPresent(Bool.self, forKey: .masterMuted) ?? d.masterMuted
        linkSystemVolume = try c.decodeIfPresent(Bool.self, forKey: .linkSystemVolume) ?? d.linkSystemVolume
        baseLatencyMs = try c.decodeIfPresent(Double.self, forKey: .baseLatencyMs) ?? d.baseLatencyMs
        autoBaseLatency = try c.decodeIfPresent(Bool.self, forKey: .autoBaseLatency) ?? d.autoBaseLatency
        maxDelayMs = try c.decodeIfPresent(Double.self, forKey: .maxDelayMs) ?? d.maxDelayMs
        showVirtualDevices = try c.decodeIfPresent(Bool.self, forKey: .showVirtualDevices) ?? d.showVirtualDevices
        showAggregateDevices = try c.decodeIfPresent(Bool.self, forKey: .showAggregateDevices) ?? d.showAggregateDevices
        calibrationMicrophoneUID = try c.decodeIfPresent(String.self, forKey: .calibrationMicrophoneUID)
        calibrationLevelDb = try c.decodeIfPresent(Double.self, forKey: .calibrationLevelDb) ?? d.calibrationLevelDb
        calibrationMaxLatencyMs = try c.decodeIfPresent(Double.self, forKey: .calibrationMaxLatencyMs) ?? d.calibrationMaxLatencyMs
        calibrationRepetitions = try c.decodeIfPresent(Int.self, forKey: .calibrationRepetitions) ?? d.calibrationRepetitions
        verifyAfterCalibration = try c.decodeIfPresent(Bool.self, forKey: .verifyAfterCalibration) ?? d.verifyAfterCalibration
        matchLevelsAfterCalibration = try c.decodeIfPresent(Bool.self, forKey: .matchLevelsAfterCalibration) ?? d.matchLevelsAfterCalibration
        autoRecalibrateOnReconnect = try c.decodeIfPresent(Bool.self, forKey: .autoRecalibrateOnReconnect) ?? d.autoRecalibrateOnReconnect
        reconnectFadeInSeconds = try c.decodeIfPresent(Double.self, forKey: .reconnectFadeInSeconds) ?? d.reconnectFadeInSeconds
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        systemDSP = (try? c.decodeIfPresent(DSPSettings.self, forKey: .systemDSP)) ?? .flat
        roomCorrection = (try? c.decodeIfPresent([EQBand].self, forKey: .roomCorrection)) ?? []
        roomCorrectionEnabled = try c.decodeIfPresent(Bool.self, forKey: .roomCorrectionEnabled) ?? true
        autoEQAfterCalibration = try c.decodeIfPresent(Bool.self, forKey: .autoEQAfterCalibration) ?? d.autoEQAfterCalibration
        liveSyncEnabled = try c.decodeIfPresent(Bool.self, forKey: .liveSyncEnabled) ?? false
        liveSyncAfterCalibration = try c.decodeIfPresent(Bool.self, forKey: .liveSyncAfterCalibration) ?? true
    }
}

/// A named snapshot of the complete output configuration.
public struct SavedSetup: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var created: Date
    public var masterVolume: Double
    public var profiles: [DeviceProfile]

    public init(id: UUID = UUID(), name: String, created: Date = Date(), masterVolume: Double, profiles: [DeviceProfile]) {
        self.id = id
        self.name = name
        self.created = created
        self.masterVolume = masterVolume
        self.profiles = profiles
    }
}

/// Everything SyncForge persists.
public struct PersistedState: Codable, Sendable {
    public var version = 1
    public var settings = AppSettings()
    public var profiles: [String: DeviceProfile] = [:]
    public var setups: [SavedSetup] = []
    public var customPresets: [EQPreset] = []
    public init() {}

    enum CodingKeys: String, CodingKey { case version, settings, profiles, setups, customPresets }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
        profiles = try c.decodeIfPresent([String: DeviceProfile].self, forKey: .profiles) ?? [:]
        setups = (try? c.decodeIfPresent([SavedSetup].self, forKey: .setups)) ?? []
        customPresets = (try? c.decodeIfPresent([EQPreset].self, forKey: .customPresets)) ?? []
    }
}
