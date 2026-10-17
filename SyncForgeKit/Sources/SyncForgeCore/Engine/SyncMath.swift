import Foundation

/// Where a device's latency figure comes from.
public enum LatencySource: String, Sendable, Equatable {
    case measured        // acoustic calibration
    case driverEstimate  // Core Audio reported latency (often wrong for Bluetooth)
}

/// Timing decision for one output.
public struct OutputTiming: Sendable, Equatable {
    public var latencyMs: Double
    public var latencySource: LatencySource
    /// Compensation the automatic mode would apply.
    public var autoCompensationMs: Double
    /// Compensation actually applied (automatic + trim, or manual), clamped to [0, max].
    public var appliedDelayMs: Double
    /// appliedDelayMs + base latency: the delay programmed into the renderer.
    public var totalDelayMs: Double
    /// Expected acoustic arrival relative to the capture timeline (total + latency).
    public var expectedArrivalMs: Double
    public var clamped: Bool
}

public enum SyncMath {
    public struct Input: Sendable {
        public var uid: String
        public var latencyMs: Double
        public var source: LatencySource
        public var mode: DelayMode
        public var manualDelayMs: Double
        public var trimMs: Double
        public init(uid: String, latencyMs: Double, source: LatencySource, mode: DelayMode, manualDelayMs: Double, trimMs: Double) {
            self.uid = uid
            self.latencyMs = latencyMs
            self.source = source
            self.mode = mode
            self.manualDelayMs = manualDelayMs
            self.trimMs = trimMs
        }
    }

    /// Computes per-output delays so that every automatic output's sound arrives together with the
    /// slowest output. Outputs in manual mode keep their delay; they still count as participants,
    /// i.e. automatic outputs align to the latest arrival among *all* outputs.
    ///
    /// We never try to make an output faster than its physical latency: the slowest path gets no
    /// compensation and the others wait for it.
    public static func timings(_ inputs: [Input], baseLatencyMs: Double, maxDelayMs: Double) -> [String: OutputTiming] {
        guard !inputs.isEmpty else { return [:] }
        let latestAuto = inputs.filter { $0.mode == .automatic }.map(\.latencyMs).max() ?? -Double.infinity
        let latestManual = inputs.filter { $0.mode == .manual }.map { $0.latencyMs + min(max(0, $0.manualDelayMs), maxDelayMs) }.max() ?? -Double.infinity
        let target = max(latestAuto, latestManual)
        var out: [String: OutputTiming] = [:]
        for i in inputs {
            let auto = max(0, target - i.latencyMs)
            let wanted = i.mode == .automatic ? auto + i.trimMs : i.manualDelayMs
            let applied = min(max(0, wanted), maxDelayMs)
            out[i.uid] = OutputTiming(latencyMs: i.latencyMs, latencySource: i.source, autoCompensationMs: auto,
                                      appliedDelayMs: applied, totalDelayMs: applied + baseLatencyMs,
                                      expectedArrivalMs: applied + baseLatencyMs + i.latencyMs,
                                      clamped: applied != max(0, wanted) || wanted < 0)
        }
        return out
    }

    /// Volume slider position (0...1) to linear gain. Square law: 50 % = -12 dB, 25 % = -24 dB.
    public static func sliderGain(_ v: Double) -> Double {
        let x = min(max(v, 0), 1)
        return x * x
    }

    public static func dbToLinear(_ db: Double) -> Double { pow(10, db / 20) }
    public static func linearToDb(_ g: Double) -> Double { 20 * log10(max(g, 1e-9)) }
}
