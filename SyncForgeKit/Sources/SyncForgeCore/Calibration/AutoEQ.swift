import Foundation

/// Frequency-response measurement from calibration sweeps and EQ fitting.
///
/// A sweep's recording divided by the sweep itself gives the response of speaker + room + microphone
/// at the listening position. The microphone's own response is unknown (built-in and iPhone
/// microphones are not measurement microphones), but it is the same in every measurement, so it
/// cancels when outputs are compared with each other. SyncForge therefore:
///   * matches the *tone* of outputs to each other (each output is corrected towards the average
///     shape of all outputs), and
///   * cuts narrow bass resonances (room modes) that stand out from the average's smooth trend.
/// Corrections are deliberately gentle: mostly cuts, small boosts, a handful of bands.
public enum AutoEQ {
    /// Analysis grid: 1/12-octave points from 40 Hz to 16 kHz.
    public static let grid: [Double] = {
        let n = Int((log2(16000.0 / 40.0) * 12).rounded()) + 1
        return (0..<n).map { 40 * pow(2, Double($0) / 12) }
    }()

    public struct Response: Sendable, Equatable {
        public var db: [Double]
        public var valid: [Bool]
        public init(db: [Double], valid: [Bool]) {
            self.db = db
            self.valid = valid
        }
    }

    /// Measures the response from one recorded sweep. `arrival` is the sweep's start in `recording`.
    /// `processing` is the digital cascade the sweep passed through. Remove its power response
    /// before averaging bins, so neither old automatic corrections nor deliberate EQ are fitted
    /// away. Its coefficients must be evaluated at the output's rate, not the microphone's rate.
    public static func response(recording: [Float], arrival: Int, reference: [Float], sampleRate fs: Double,
                                noise: LatencyEstimator.NoiseProfile?, sweepBand: ClosedRange<Double>,
                                processing: [Biquad] = [], processingSampleRate: Double? = nil) -> Response? {
        let tail = Int(0.03 * fs)
        let start = max(0, arrival - Int(0.001 * fs))
        let end = min(recording.count, arrival + reference.count + tail)
        guard end - start > reference.count / 2 else { return nil }
        var n = 1
        while n < end - start { n <<= 1 }
        let seg = Array(recording[start..<end]).map(Double.init) + [Double](repeating: 0, count: n - (end - start))
        let ref = reference.map(Double.init) + [Double](repeating: 0, count: n - reference.count)
        let px = LatencyEstimator.NoiseProfile.powerSpectrum(seg)
        let ps = LatencyEstimator.NoiseProfile.powerSpectrum(ref)
        let binHz = fs / Double(n)
        let outputRate = processingSampleRate ?? fs
        let processingPower = processing.isEmpty ? [] : px.indices.map { k -> Double in
            let f = Double(k) * binHz
            guard f < outputRate / 2 else { return 0 }
            let magnitude = processing.reduce(1.0) { $0 * $1.magnitude(at: f, sampleRate: outputRate) }
            return magnitude * magnitude
        }
        var db = [Double](repeating: 0, count: grid.count)
        var valid = [Bool](repeating: false, count: grid.count)
        let lo = sweepBand.lowerBound * 1.15, hi = min(sweepBand.upperBound / 1.15, fs * 0.45)
        for (i, f) in grid.enumerated() where f >= lo && f <= hi {
            // Average over +/- 1/12 octave around the grid point.
            let a = max(1, Int(f / pow(2, 1.0 / 24) / binHz)), b = min(px.count - 1, Int(f * pow(2, 1.0 / 24) / binHz))
            guard b >= a else { continue }
            var sx = 0.0, sr = 0.0, sn = 0.0
            for k in a...b {
                let power = processingPower.isEmpty ? 1 : processingPower[k]
                // A deep digital null contains no useful measurement of the physical speaker.
                guard power > 1e-8, power.isFinite else { continue }
                sx += px[k] / power
                sr += ps[k]
                if let noise { sn += noise.expectedPower(bin: k, n: n, segmentLength: end - start) / power }
            }
            guard sr > 0, sx > 0 else { continue }
            db[i] = 10 * log10(sx / sr)
            valid[i] = noise == nil || sx > sn * 10   // >= 10 dB above the room noise
        }
        return Response(db: db, valid: valid)
    }

    /// Power-average of several responses (points valid in at least half of them).
    public static func average(_ list: [Response]) -> Response? {
        guard !list.isEmpty else { return nil }
        var db = [Double](repeating: 0, count: grid.count), valid = [Bool](repeating: false, count: grid.count)
        for i in grid.indices {
            let vals = list.filter { $0.valid[i] }.map { pow(10, $0.db[i] / 10) }
            guard vals.count * 2 >= list.count, !vals.isEmpty else { continue }
            db[i] = 10 * log10(vals.reduce(0, +) / Double(vals.count))
            valid[i] = true
        }
        return Response(db: db, valid: valid)
    }

    /// Smoothing over a fraction of an octave (valid points only).
    public static func smooth(_ r: Response, octaves: Double) -> Response {
        let half = max(1, Int((octaves * 12 / 2).rounded()))
        var out = r.db
        for i in grid.indices where r.valid[i] {
            let lo = max(0, i - half), hi = min(grid.count - 1, i + half)
            let vals = (lo...hi).filter { r.valid[$0] }.map { r.db[$0] }
            out[i] = vals.reduce(0, +) / Double(vals.count)
        }
        return Response(db: out, valid: r.valid)
    }

    /// Mean level over `band` (valid points), used to separate loudness from tone.
    public static func meanLevel(_ r: Response, band: ClosedRange<Double> = 200...4000) -> Double? {
        let vals = grid.indices.filter { r.valid[$0] && band.contains(grid[$0]) }.map { r.db[$0] }
        return vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count)
    }

    /// Fits peaking bands so that `deviation` (dB, positive = too loud) is cancelled.
    public static func fit(deviation: [Double], valid: [Bool], range: ClosedRange<Double> = 60...8000,
                           maxBands: Int = 6, maxCutDb: Double = 9, maxBoostDb: Double = 3, stopBelowDb: Double = 1.5) -> [EQBand] {
        var bands: [EQBand] = []
        var residual = deviation
        var tried = Set<Int>()
        let fs = 48000.0
        let usable = grid.indices.filter { valid[$0] && range.contains(grid[$0]) }
        guard usable.count >= 6 else { return [] }
        while bands.count < maxBands {
            // Prefer cutting peaks over filling dips (dips are often cancellations that EQ can't fix).
            guard let i = usable.filter({ !tried.contains($0) }).max(by: {
                abs(residual[$0]) * (residual[$0] > 0 ? 1 : 0.6) < abs(residual[$1]) * (residual[$1] > 0 ? 1 : 0.6)
            }) else { break }
            let peak = residual[i]
            if abs(peak) < stopBelowDb { break }
            tried.insert(i)
            // Width: where the residual stays above half the peak, same sign.
            var lo = i, hi = i
            while lo > 0, valid[lo - 1], residual[lo - 1] * peak > 0, abs(residual[lo - 1]) >= abs(peak) / 2 { lo -= 1 }
            while hi < grid.count - 1, valid[hi + 1], residual[hi + 1] * peak > 0, abs(residual[hi + 1]) >= abs(peak) / 2 { hi += 1 }
            let bw = min(3, max(1.0 / 6, Double(hi - lo + 1) / 12))
            if peak < 0 && bw < 1.0 / 3 { continue }   // don't try to fill narrow dips
            let gain = min(maxBoostDb, max(-maxCutDb, -peak))
            // A deviation that runs into the edge of the measured range is a tilt: use a shelf.
            let band: EQBand
            if hi >= usable.last! - 1 && bw >= 1 {
                band = EQBand(type: .highShelf, frequency: grid[lo].rounded(), gainDb: (gain * 10).rounded() / 10, q: 0.7)
            } else if lo <= usable.first! + 1 && bw >= 1 {
                band = EQBand(type: .lowShelf, frequency: grid[hi].rounded(), gainDb: (gain * 10).rounded() / 10, q: 0.7)
            } else {
                let q = pow(2, bw / 2) / (pow(2, bw) - 1)
                band = EQBand(type: .peak, frequency: grid[i].rounded(), gainDb: (gain * 10).rounded() / 10, q: (q * 100).rounded() / 100)
            }
            guard let bq = BiquadDesign.design(band.type, frequency: band.frequency, gainDb: band.gainDb, q: band.q, sampleRate: fs) else { continue }
            bands.append(band)
            for k in grid.indices where valid[k] {
                residual[k] += 20 * log10(bq.magnitude(at: grid[k], sampleRate: fs))
            }
        }
        return bands.sorted { $0.frequency < $1.frequency }
    }

    public struct Plan: Sendable {
        /// Per-output tone-matching bands.
        public var perOutput: [String: [EQBand]]
        /// Room-resonance cuts for the system EQ.
        public var room: [EQBand]
        /// Smoothed measured response per output (normalised to 0 dB mean), for display.
        public var responses: [String: [Double?]]
    }

    /// Builds the correction plan from per-output averaged responses.
    public static func plan(_ responses: [String: Response]) -> Plan {
        var shapes: [String: Response] = [:]
        for (uid, r) in responses {
            let s = smooth(r, octaves: 1.0 / 6)
            guard let mean = meanLevel(s) else { continue }
            shapes[uid] = Response(db: s.db.map { $0 - mean }, valid: s.valid)
        }
        // Average shape across outputs where at least one output is valid.
        var avg = Response(db: [Double](repeating: 0, count: grid.count), valid: [Bool](repeating: false, count: grid.count))
        for i in grid.indices {
            let vals = shapes.values.filter { $0.valid[i] }.map { $0.db[i] }
            if !vals.isEmpty {
                avg.db[i] = vals.reduce(0, +) / Double(vals.count)
                avg.valid[i] = true
            }
        }
        var perOutput: [String: [EQBand]] = [:]
        if shapes.count >= 2 {
            for (uid, s) in shapes {
                // Only where both this output and the average are valid, and avoid correcting
                // a speaker beyond what it can physically reproduce (where it isn't valid).
                let valid = grid.indices.map { s.valid[$0] && avg.valid[$0] }
                let deviation = grid.indices.map { s.db[$0] - avg.db[$0] }
                perOutput[uid] = fit(deviation: deviation, valid: valid, maxBands: 5, maxCutDb: 8, maxBoostDb: 3)
            }
        }
        // Room modes: narrow bass peaks above the average's smooth (1 octave) trend.
        let trend = smooth(avg, octaves: 1)
        let bass = grid.indices.map { avg.valid[$0] ? avg.db[$0] - trend.db[$0] : 0 }
        let room = fit(deviation: bass, valid: avg.valid, range: 35...300, maxBands: 3, maxCutDb: 8, maxBoostDb: 0, stopBelowDb: 3)
        var display: [String: [Double?]] = [:]
        for (uid, s) in shapes { display[uid] = grid.indices.map { s.valid[$0] ? (s.db[$0] * 10).rounded() / 10 : nil } }
        return Plan(perOutput: perOutput, room: room, responses: display)
    }
}
