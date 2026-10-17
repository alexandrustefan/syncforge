import Foundation

public enum FilterType: String, Codable, CaseIterable, Sendable, Identifiable {
    case peak, lowShelf, highShelf, lowPass, highPass, notch, bandPass
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .peak: return "Peak"
        case .lowShelf: return "Low Shelf"
        case .highShelf: return "High Shelf"
        case .lowPass: return "Low Pass"
        case .highPass: return "High Pass"
        case .notch: return "Notch"
        case .bandPass: return "Band Pass"
        }
    }

    public var usesGain: Bool { self == .peak || self == .lowShelf || self == .highShelf }
}

/// One parametric EQ band.
public struct EQBand: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var enabled: Bool
    public var type: FilterType
    public var frequency: Double
    public var gainDb: Double
    public var q: Double

    public init(id: UUID = UUID(), enabled: Bool = true, type: FilterType = .peak,
                frequency: Double, gainDb: Double = 0, q: Double = 1.41) {
        self.id = id
        self.enabled = enabled
        self.type = type
        self.frequency = frequency
        self.gainDb = gainDb
        self.q = q
    }
}

public enum FilterSlope: Int, Codable, CaseIterable, Sendable, Identifiable {
    case db12 = 12, db24 = 24, db36 = 36, db48 = 48
    public var id: Int { rawValue }
    /// Butterworth order.
    public var order: Int { rawValue / 6 }
    public var displayName: String { "\(rawValue) dB/oct" }
}

/// A Butterworth high- or low-pass filter.
public struct PassFilter: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var frequency: Double
    public var slope: FilterSlope

    public init(enabled: Bool = false, frequency: Double, slope: FilterSlope = .db24) {
        self.enabled = enabled
        self.frequency = frequency
        self.slope = slope
    }
}

/// Complete per-device processing configuration.
public struct DSPSettings: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var preampDb: Double
    public var autoHeadroom: Bool
    public var bands: [EQBand]
    public var highPass: PassFilter
    public var lowPass: PassFilter
    public var limiterEnabled: Bool
    public var limiterCeilingDb: Double
    public var presetName: String

    public init(enabled: Bool = true, preampDb: Double = 0, autoHeadroom: Bool = true, bands: [EQBand],
                highPass: PassFilter = PassFilter(frequency: 80), lowPass: PassFilter = PassFilter(frequency: 16000),
                limiterEnabled: Bool = true, limiterCeilingDb: Double = -0.3, presetName: String = "Flat") {
        self.enabled = enabled
        self.preampDb = preampDb
        self.autoHeadroom = autoHeadroom
        self.bands = bands
        self.highPass = highPass
        self.lowPass = lowPass
        self.limiterEnabled = limiterEnabled
        self.limiterCeilingDb = limiterCeilingDb
        self.presetName = presetName
    }

    public static let graphicFrequencies: [Double] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    /// Neutral 10-band graphic layout: every band at 0 dB, filters off.
    public static var flat: DSPSettings {
        DSPSettings(bands: graphicFrequencies.enumerated().map { i, f in
            EQBand(id: UUID(uuidString: String(format: "5F0E0000-0000-0000-0000-%012d", i))!, frequency: f, gainDb: 0, q: 1.41)
        })
    }

    /// True when the configuration has no audible effect.
    public var isNeutral: Bool {
        !enabled || (abs(preampDb) < 0.01 && !highPass.enabled && !lowPass.enabled
                     && bands.allSatisfy { !$0.enabled || ($0.type.usesGain && abs($0.gainDb) < 0.01) })
    }

    enum CodingKeys: String, CodingKey {
        case enabled, preampDb, autoHeadroom, bands, highPass, lowPass, limiterEnabled, limiterCeilingDb, presetName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = DSPSettings.flat
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? base.enabled
        preampDb = try c.decodeIfPresent(Double.self, forKey: .preampDb) ?? 0
        autoHeadroom = try c.decodeIfPresent(Bool.self, forKey: .autoHeadroom) ?? true
        bands = try c.decodeIfPresent([EQBand].self, forKey: .bands) ?? base.bands
        highPass = try c.decodeIfPresent(PassFilter.self, forKey: .highPass) ?? base.highPass
        lowPass = try c.decodeIfPresent(PassFilter.self, forKey: .lowPass) ?? base.lowPass
        limiterEnabled = try c.decodeIfPresent(Bool.self, forKey: .limiterEnabled) ?? true
        limiterCeilingDb = try c.decodeIfPresent(Double.self, forKey: .limiterCeilingDb) ?? -0.3
        presetName = try c.decodeIfPresent(String.self, forKey: .presetName) ?? "Custom"
    }
}

/// A named EQ preset (built-in or user-defined).
public struct EQPreset: Codable, Hashable, Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var settings: DSPSettings
    public var isBuiltIn: Bool
    /// What the preset actually changes; optional so existing custom presets still decode.
    public var summary: String?

    public init(name: String, settings: DSPSettings, isBuiltIn: Bool = false, summary: String? = nil) {
        self.name = name
        var s = settings
        s.presetName = name
        self.settings = s
        self.isBuiltIn = isBuiltIn
        self.summary = summary
    }
}

public enum EQPresets {
    private static func tone(_ name: String, _ summary: String, bands: [EQBand],
                             highPass: PassFilter = PassFilter(frequency: 80)) -> EQPreset {
        var settings = DSPSettings(bands: bands, highPass: highPass)
        settings.presetName = name
        return EQPreset(name: name, settings: settings, isBuiltIn: true, summary: summary)
    }

    private static func shelf(_ type: FilterType, _ frequency: Double, _ gain: Double) -> EQBand {
        EQBand(type: type, frequency: frequency, gainDb: gain, q: 1 / sqrt(2))
    }

    /// Broad tone controls, with bounded total boost rather than overlapping graphic-EQ humps.
    /// Shelf turnover choices follow documented hi-fi tone controls (RME) and loudness contours
    /// (CamillaDSP). Gains are SyncForge choices, not vendor/device correction profiles.
    /// See docs/EQ_PRESETS.md for sources, intent and limitations.
    public static let builtIn: [EQPreset] = [
        EQPreset(name: "Flat", settings: .flat, isBuiltIn: true,
                 summary: "No tone shaping. Speaker and room corrections remain separate."),
        tone("Music", "Subtle bass warmth and a little air, with the midrange kept natural.", bands: [
            shelf(.lowShelf, 85, 2), shelf(.highShelf, 6500, 1),
        ]),
        tone("Warm", "A little more body, with a softer top end.", bands: [
            shelf(.lowShelf, 150, 2), shelf(.highShelf, 4500, -1.5),
        ]),
        tone("Bass Boost", "A smooth +4.5 dB bass shelf. Small speakers may not reproduce deep bass.", bands: [
            shelf(.lowShelf, 85, 4.5),
        ]),
        tone("Vocal Clarity", "Less low-end masking and a broad, modest lift in speech presence.", bands: [
            shelf(.lowShelf, 180, -2), EQBand(frequency: 2200, gainDb: 2, q: 0.7),
        ]),
        tone("Soft Treble", "Takes the edge off bright recordings without cutting the vocal range.", bands: [
            shelf(.highShelf, 4500, -3),
        ]),
        tone("Low Volume", "A fixed, gentle loudness contour for quiet listening; not volume-adaptive.", bands: [
            shelf(.lowShelf, 70, 3.5), shelf(.highShelf, 3500, 1.5),
        ]),
        tone("Night Mode", "Less bass transmission and a softer top end. EQ only, not dynamic-range compression.", bands: [
            shelf(.lowShelf, 140, -5), shelf(.highShelf, 5000, -1.5),
        ]),
        tone("Small Speakers", "Gently removes deep rumble and adds a little upper-bass body.", bands: [
            EQBand(frequency: 150, gainDb: 1.5, q: 0.8),
        ], highPass: PassFilter(enabled: true, frequency: 65, slope: .db12)),
    ]

    public static func named(_ name: String) -> EQPreset? { builtIn.first { $0.name == name } }
}
