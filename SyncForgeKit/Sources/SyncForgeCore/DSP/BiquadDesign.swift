import Foundation
import SyncForgeRT

/// Normalised biquad coefficients (a0 = 1), transposed direct form II in the renderer.
public struct Biquad: Hashable, Sendable {
    public var b0, b1, b2, a1, a2: Double

    public static let identity = Biquad(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    init(_ b0: Double, _ b1: Double, _ b2: Double, _ a0: Double, _ a1: Double, _ a2: Double) {
        self.init(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    /// Complex response at `frequency` for sample rate `fs`, returned as magnitude (linear).
    public func magnitude(at frequency: Double, sampleRate fs: Double) -> Double {
        let w = 2 * Double.pi * frequency / fs
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
        let dr = 1 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
        return sqrt((nr * nr + ni * ni) / max(dr * dr + di * di, 1e-300))
    }
}

/// Filter design (RBJ Audio EQ Cookbook + Butterworth cascades).
public enum BiquadDesign {
    public static func design(_ type: FilterType, frequency: Double, gainDb: Double, q: Double,
                              sampleRate fs: Double) -> Biquad? {
        guard fs > 0, frequency > 0, frequency < fs * 0.49 else { return nil }
        let q = max(0.05, q)
        let w0 = 2 * Double.pi * frequency / fs
        let cw = cos(w0), sw = sin(w0)
        let alpha = sw / (2 * q)
        let A = pow(10, gainDb / 40)
        switch type {
        case .peak:
            return Biquad(1 + alpha * A, -2 * cw, 1 - alpha * A, 1 + alpha / A, -2 * cw, 1 - alpha / A)
        case .lowShelf:
            let s = 2 * sqrt(A) * alpha
            return Biquad(A * ((A + 1) - (A - 1) * cw + s), 2 * A * ((A - 1) - (A + 1) * cw), A * ((A + 1) - (A - 1) * cw - s),
                          (A + 1) + (A - 1) * cw + s, -2 * ((A - 1) + (A + 1) * cw), (A + 1) + (A - 1) * cw - s)
        case .highShelf:
            let s = 2 * sqrt(A) * alpha
            return Biquad(A * ((A + 1) + (A - 1) * cw + s), -2 * A * ((A - 1) + (A + 1) * cw), A * ((A + 1) + (A - 1) * cw - s),
                          (A + 1) - (A - 1) * cw + s, 2 * ((A - 1) - (A + 1) * cw), (A + 1) - (A - 1) * cw - s)
        case .lowPass:
            return Biquad((1 - cw) / 2, 1 - cw, (1 - cw) / 2, 1 + alpha, -2 * cw, 1 - alpha)
        case .highPass:
            return Biquad((1 + cw) / 2, -(1 + cw), (1 + cw) / 2, 1 + alpha, -2 * cw, 1 - alpha)
        case .notch:
            return Biquad(1, -2 * cw, 1, 1 + alpha, -2 * cw, 1 - alpha)
        case .bandPass:
            return Biquad(alpha, 0, -alpha, 1 + alpha, -2 * cw, 1 - alpha)
        }
    }

    /// Q values of the second-order sections of an even-order Butterworth filter.
    public static func butterworthQs(order: Int) -> [Double] {
        let n = max(2, order - order % 2)
        return (1...(n / 2)).map { k in 1 / (2 * cos(Double(2 * k - 1) * Double.pi / Double(2 * n))) }
    }

    public static func passFilter(_ f: PassFilter, highPass: Bool, sampleRate: Double) -> [Biquad] {
        guard f.enabled else { return [] }
        return butterworthQs(order: f.slope.order).compactMap {
            design(highPass ? .highPass : .lowPass, frequency: f.frequency, gainDb: 0, q: $0, sampleRate: sampleRate)
        }
    }

    /// The complete cascade for a device, excluding the preamp.
    public static func cascade(_ s: DSPSettings, sampleRate: Double) -> [Biquad] {
        guard s.enabled else { return [] }
        var out: [Biquad] = []
        out += passFilter(s.highPass, highPass: true, sampleRate: sampleRate)
        for band in s.bands where band.enabled {
            if band.type.usesGain && abs(band.gainDb) < 0.01 { continue }
            if let bq = design(band.type, frequency: band.frequency, gainDb: band.gainDb, q: band.q, sampleRate: sampleRate) {
                out.append(bq)
            }
        }
        out += passFilter(s.lowPass, highPass: false, sampleRate: sampleRate)
        return Array(out.prefix(Int(SF_MAX_BIQUADS)))
    }

    /// Response of the cascade (without preamp) in dB at `frequency`.
    public static func responseDb(_ cascade: [Biquad], frequency: Double, sampleRate: Double) -> Double {
        let mag = cascade.reduce(1.0) { $0 * $1.magnitude(at: frequency, sampleRate: sampleRate) }
        return 20 * log10(max(mag, 1e-12))
    }

    /// Log-spaced frequencies used for plotting / analysis.
    public static func logFrequencies(count: Int = 256, from lo: Double = 20, to hi: Double = 20000) -> [Double] {
        (0..<count).map { lo * pow(hi / lo, Double($0) / Double(count - 1)) }
    }

    /// Maximum boost of the cascade across the audio band (dB, >= 0), used for automatic headroom.
    public static func maxBoostDb(_ s: DSPSettings, sampleRate: Double) -> Double {
        maxBoostDb(cascade(s, sampleRate: sampleRate), sampleRate: sampleRate)
    }

    public static func maxBoostDb(_ c: [Biquad], sampleRate: Double) -> Double {
        guard !c.isEmpty else { return 0 }
        let top = min(20000, sampleRate * 0.45)
        return max(0, logFrequencies(count: 400, to: top).map { responseDb(c, frequency: $0, sampleRate: sampleRate) }.max() ?? 0)
    }

    /// Effective preamp (dB) after automatic headroom.
    public static func effectivePreampDb(_ s: DSPSettings, sampleRate: Double) -> Double {
        s.autoHeadroom ? s.preampDb - maxBoostDb(s, sampleRate: sampleRate) : s.preampDb
    }

    /// The processing an output actually receives: the system EQ (if applied) followed by its own EQ.
    public struct Chain: Sendable {
        public var cascade: [Biquad]
        public var preampDb: Double
        public var isActive: Bool { !cascade.isEmpty || abs(preampDb) > 0.01 }
    }

    /// Peaking/shelf bands (e.g. calibration corrections) as biquads.
    public static func bands(_ list: [EQBand], sampleRate: Double) -> [Biquad] {
        list.filter(\.enabled).compactMap {
            design($0.type, frequency: $0.frequency, gainDb: $0.gainDb, q: $0.q, sampleRate: sampleRate)
        }
    }

    public static func chain(system: DSPSettings?, device: DSPSettings, sampleRate: Double,
                             roomCorrection: [EQBand] = [], deviceCorrection: [EQBand] = []) -> Chain {
        let sys = (system?.enabled ?? false) ? system! : nil
        let sysCascade = sys.map { cascade($0, sampleRate: sampleRate) } ?? []
        let devCascade = cascade(device, sampleRate: sampleRate)
        let corrections = bands(roomCorrection, sampleRate: sampleRate) + bands(deviceCorrection, sampleRate: sampleRate)
        let combined = Array((corrections + sysCascade + devCascade).prefix(Int(SF_MAX_BIQUADS)))
        var preamp = (sys?.preampDb ?? 0) + (device.enabled ? device.preampDb : 0)
        // Headroom for the combined boost (boosts of the two EQs can stack).
        if (sys?.autoHeadroom ?? false) || (device.enabled && device.autoHeadroom) {
            preamp -= maxBoostDb(combined, sampleRate: sampleRate)
        }
        return Chain(cascade: combined, preampDb: preamp)
    }
}
