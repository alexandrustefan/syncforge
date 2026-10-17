import Foundation

/// Combines interleaved sweep measurements of several outputs into latencies that are insensitive to
/// slow changes of the microphone path's delay (wireless microphones such as an iPhone, adaptive
/// microphone DSP).
///
/// Sweeps alternate between outputs (A, B, C, A, B, C, …). The microphone delay at the moment an
/// output's sweep arrives is common to everything recorded at that moment, so each output is
/// measured *relative* to the reference output, whose latency is linearly interpolated to the same
/// instant. Absolute values are then anchored at the reference's median.
public enum DriftCancellation {
    public struct Sample: Sendable, Equatable {
        public var time: Double      // arrival time (s, any common clock)
        public var latency: Double   // measured latency (ms)
        public init(time: Double, latency: Double) {
            self.time = time
            self.latency = latency
        }
    }

    public struct Result: Sendable, Equatable {
        public var latencyMs: Double
        /// Spread (max - min) of the accepted relative measurements, ms.
        public var spreadMs: Double
        public var accepted: Int
        public var total: Int
    }

    public static func combine(_ samples: [String: [Sample]], reference: String, outlierFloorMs: Double = 0.25) -> [String: Result] {
        guard let ref = samples[reference]?.sorted(by: { $0.time < $1.time }), !ref.isEmpty else { return [:] }
        func refAt(_ t: Double) -> Double {
            if ref.count == 1 { return ref[0].latency }
            // Interpolate between neighbours; extrapolate linearly from the outermost pair.
            let i = min(max(ref.firstIndex { $0.time >= t } ?? ref.count - 1, 1), ref.count - 1)
            let a = ref[i - 1], b = ref[i]
            let f = (t - a.time) / max(b.time - a.time, 1e-9)
            return a.latency + f * (b.latency - a.latency)
        }
        let refValues = RobustStats.inliers(ref.map(\.latency), floor: outlierFloorMs)
        let anchor = RobustStats.median(refValues)
        var out: [String: Result] = [:]
        out[reference] = Result(latencyMs: anchor, spreadMs: (refValues.max() ?? 0) - (refValues.min() ?? 0),
                                accepted: refValues.count, total: ref.count)
        for (uid, list) in samples where uid != reference && !list.isEmpty {
            let rel = RobustStats.inliers(list.map { $0.latency - refAt($0.time) }, floor: outlierFloorMs)
            guard !rel.isEmpty else { continue }
            out[uid] = Result(latencyMs: anchor + RobustStats.median(rel), spreadMs: rel.max()! - rel.min()!,
                              accepted: rel.count, total: list.count)
        }
        return out
    }
}

/// Level matching between outputs from the levels their sweeps reach the microphone with.
public enum LevelMatching {
    /// Trims (dB) that make every output equally loud at the listening position. Quieter outputs are
    /// boosted by at most `maxBoostDb` (the per-output limiter prevents clipping); louder ones are cut.
    public static func trims(levelsDb: [String: Double], maxBoostDb: Double = 6, maxCutDb: Double = 24) -> [String: Double] {
        guard let minLevel = levelsDb.values.min(), let maxLevel = levelsDb.values.max() else { return [:] }
        let target = min(maxLevel, minLevel + maxBoostDb)
        return levelsDb.mapValues { min(maxBoostDb, max(-maxCutDb, target - $0)) }
    }
}
