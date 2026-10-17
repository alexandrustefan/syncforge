import Accelerate
import Foundation

/// Result of locating a known test signal in a recording.
public struct ArrivalEstimate: Sendable, Equatable {
    /// Fractional lag (frames) of the earliest significant arrival (direct sound).
    public let lag: Double
    /// Lag of the strongest correlation peak (may be a reflection).
    public let strongestLag: Double
    /// Peak height relative to the correlation noise floor, dB.
    public let peakToNoiseDb: Double
    /// Height of the chosen (earliest) peak relative to the strongest one, dB (<= 0).
    public let earliestRelativeDb: Double
}

/// Time-of-arrival estimation by generalised cross-correlation.
///
/// * Correlation is computed in the frequency domain (vDSP FFT).
/// * PHAT-beta weighting whitens the cross-spectrum, which sharpens the peak and makes the result
///   largely independent of the speaker's and microphone's frequency response and of the room's
///   resonances. The weighting is restricted to the test signal's band, with tapered edges.
/// * The analytic (one-sided) cross-correlation is used and its envelope is searched, so a peak
///   cannot jump by a carrier cycle when speakers have different phase responses.
/// * The direct sound is taken as the *earliest* local envelope peak within `earliestWindow` before
///   the strongest peak that is no more than `earliestThresholdDb` below it: early reflections
///   (desk, walls) can be stronger than the direct path, but they always arrive later.
public enum LatencyEstimator {
    public struct Options: Sendable {
        public var bandLow: Double = 200
        public var bandHigh: Double = 10000
        public var phatBeta: Double = 0.8
        public var earliestWindow: Double = 0.02
        public var earliestThresholdDb: Double = -6
        public var noiseExclusion: Double = 0.03
        public init() {}
    }

    /// Power spectral density of background noise, used to weight the correlation by per-bin SNR.
    public struct NoiseProfile: Sendable {
        let frameLength: Int
        let window: [Float]
        let windowPower: Double
        let psd: [Double]   // per bin of a `frameLength` FFT, Hann-windowed periodogram average

        public init?(noise: [Float], frameLength: Int = 4096) {
            guard noise.count >= frameLength else { return nil }
            self.frameLength = frameLength
            var w = [Float](repeating: 0, count: frameLength)
            vDSP_hann_window(&w, vDSP_Length(frameLength), Int32(vDSP_HANN_NORM))
            window = w
            windowPower = w.reduce(0) { $0 + Double($1 * $1) }
            var acc = [Double](repeating: 0, count: frameLength / 2 + 1)
            var frames = 0
            var start = 0
            while start + frameLength <= noise.count {
                let seg = (0..<frameLength).map { Double(noise[start + $0] * w[$0]) }
                let spectrum = NoiseProfile.powerSpectrum(seg)
                for k in acc.indices { acc[k] += spectrum[k] }
                frames += 1
                start += frameLength / 2
            }
            psd = acc.map { $0 / Double(max(frames, 1)) }
        }

        /// Expected noise power in bin `k` of an `n`-point FFT of an `m`-sample (unwindowed) segment.
        func expectedPower(bin k: Int, n: Int, segmentLength m: Int) -> Double {
            let f = Double(k) / Double(n)              // cycles per sample
            let j = min(psd.count - 1, Int((f * Double(frameLength)).rounded()))
            return psd[j] * Double(m) / windowPower
        }

        static func powerSpectrum(_ x: [Double]) -> [Double] {
            let n = x.count
            var log2n = 0
            while (1 << log2n) < n { log2n += 1 }
            guard let setup = vDSP_create_fftsetupD(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else { return [] }
            defer { vDSP_destroy_fftsetupD(setup) }
            var re = x + [Double](repeating: 0, count: (1 << log2n) - n)
            var im = [Double](repeating: 0, count: re.count)
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zipD(setup, &split, 1, vDSP_Length(log2n), FFTDirection(kFFTDirection_Forward))
                }
            }
            return (0...(re.count / 2)).map { re[$0] * re[$0] + im[$0] * im[$0] }
        }
    }

    public static func estimate(recording: [Float], reference: [Float], sampleRate: Double,
                                noise: NoiseProfile? = nil, options: Options = Options()) -> ArrivalEstimate? {
        guard let env = envelope(recording: recording, reference: reference, sampleRate: sampleRate, noise: noise, options: options)
        else { return nil }
        return pickArrival(env, sampleRate: sampleRate, options: options)
    }

    /// Envelope of the weighted, analytic cross-correlation for lags 0...(recording - reference).
    public static func envelope(recording: [Float], reference: [Float], sampleRate: Double,
                                noise: NoiseProfile? = nil, options: Options = Options()) -> [Float]? {
        let m = recording.count, r = reference.count
        guard r > 16, m >= r else { return nil }
        let maxLag = m - r
        var log2n = 1
        while (1 << log2n) < m + r { log2n += 1 }
        let n = 1 << log2n
        guard let setup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }

        var xr = [Float](repeating: 0, count: n), xi = [Float](repeating: 0, count: n)
        var sr = [Float](repeating: 0, count: n), si = [Float](repeating: 0, count: n)
        xr.replaceSubrange(0..<m, with: recording)
        sr.replaceSubrange(0..<r, with: reference)

        func fft(_ re: inout [Float], _ im: inout [Float], _ direction: FFTDirection) {
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zip(setup, &split, 1, vDSP_Length(log2n), direction)
                }
            }
        }
        fft(&xr, &xi, FFTDirection(kFFTDirection_Forward))
        fft(&sr, &si, FFTDirection(kFFTDirection_Forward))

        // Cross spectrum G = X * conj(S), weighted, one-sided (analytic correlation).
        let binHz = sampleRate / Double(n)
        let lo = options.bandLow, hi = min(options.bandHigh, sampleRate * 0.45)
        let taper = pow(2.0, 1.0 / 3.0)
        var gr = [Float](repeating: 0, count: n), gi = [Float](repeating: 0, count: n)
        var weights = [Double](repeating: 0, count: n / 2)
        var maxMag = 0.0
        for k in 1..<(n / 2) {
            let f = Double(k) * binHz
            guard f >= lo, f <= hi else { continue }
            let re = Double(xr[k]) * Double(sr[k]) + Double(xi[k]) * Double(si[k])
            let im = Double(xi[k]) * Double(sr[k]) - Double(xr[k]) * Double(si[k])
            gr[k] = Float(re)
            gi[k] = Float(im)
            let mag = pow((re * re + im * im).squareRoot(), options.phatBeta)
            weights[k] = mag
            maxMag = max(maxMag, mag)
        }
        guard maxMag > 0 else { return nil }
        let eps = maxMag * 1e-4

        // Per-bin SNR weighting (Wiener factor). Without it, PHAT gives bins that contain only noise
        // (e.g. above a microphone's processing cut-off) the same weight as bins with signal.
        var snrWeight = [Double](repeating: 1, count: n / 2)
        if let noise {
            // Recording power per bin, smoothed over ~1/6 octave to reduce variance.
            var px = [Double](repeating: 0, count: n / 2)
            for k in 1..<(n / 2) { px[k] = Double(xr[k]) * Double(xr[k]) + Double(xi[k]) * Double(xi[k]) }
            var prefix = [Double](repeating: 0, count: n / 2 + 1)
            for k in 0..<(n / 2) { prefix[k + 1] = prefix[k] + px[k] }
            for k in 1..<(n / 2) {
                let half = max(2, Int(Double(k) * 0.06))
                let a = max(1, k - half), b = min(n / 2 - 1, k + half)
                let smoothed = (prefix[b + 1] - prefix[a]) / Double(b - a + 1)
                let pn = noise.expectedPower(bin: k, n: n, segmentLength: m)
                let snr = max(0, smoothed - pn) / max(pn, 1e-30)
                snrWeight[k] = snr / (1 + snr)
            }
        }

        for k in 1..<(n / 2) {
            let f = Double(k) * binHz
            guard f >= lo, f <= hi else { continue }
            var edge = 1.0
            if f < lo * taper { edge = 0.5 - 0.5 * cos(Double.pi * (f - lo) / (lo * taper - lo)) }
            if f > hi / taper { edge = min(edge, 0.5 - 0.5 * cos(Double.pi * (hi - f) / (hi - hi / taper))) }
            let w = Float(2 * edge * snrWeight[k] / (weights[k] + eps))
            gr[k] *= w
            gi[k] *= w
        }
        fft(&gr, &gi, FFTDirection(kFFTDirection_Inverse))

        var env = [Float](repeating: 0, count: maxLag + 1)
        for k in 0...maxLag { env[k] = (gr[k] * gr[k] + gi[k] * gi[k]).squareRoot() }
        return env
    }

    static func pickArrival(_ env: [Float], sampleRate: Double, options: Options) -> ArrivalEstimate? {
        let maxLag = env.count - 1
        // Strongest peak.
        var vmax: Float = 0
        var imax: vDSP_Length = 0
        vDSP_maxvi(env, 1, &vmax, &imax, vDSP_Length(env.count))
        guard vmax > 0 else { return nil }
        let strongest = Int(imax)

        // Earliest significant local peak before it.
        let threshold = vmax * Float(pow(10, options.earliestThresholdDb / 20))
        let windowStart = max(1, strongest - Int(options.earliestWindow * sampleRate))
        var chosen = strongest
        if windowStart < strongest {
            for k in windowStart..<strongest where k + 1 < env.count {
                if env[k] >= threshold && env[k] >= env[k - 1] && env[k] >= env[k + 1] {
                    chosen = k
                    break
                }
            }
        }

        // Noise floor: RMS of the envelope away from the arrival and its reverberant tail.
        let excludeLo = chosen - Int(options.noiseExclusion * sampleRate)
        let excludeHi = strongest + Int(options.noiseExclusion * 3 * sampleRate)
        var sum = 0.0
        var count = 0
        for k in 0...maxLag where k < excludeLo || k > excludeHi {
            sum += Double(env[k]) * Double(env[k])
            count += 1
        }
        let noise = count > 16 ? (sum / Double(count)).squareRoot() : Double(vmax) * 1e-3
        let pnr = 20 * log10(Double(vmax) / max(noise, 1e-20))

        return ArrivalEstimate(lag: refine(env, chosen), strongestLag: refine(env, strongest),
                               peakToNoiseDb: pnr,
                               earliestRelativeDb: 20 * log10(Double(env[chosen]) / Double(vmax)))
    }

    /// Received level of a sweep relative to the reference, in `band` (dB): energy of the recording
    /// starting at the arrival, over the sweep's length, compared with the reference's energy.
    public static func bandGainDb(recording: [Float], arrival: Int, reference: [Float], sampleRate: Double,
                                  band: ClosedRange<Double> = 200...4000) -> Double? {
        let r = reference.count
        guard arrival >= 0, arrival + r <= recording.count else { return nil }
        let seg = Array(recording[arrival..<(arrival + r)]).map(Double.init)
        let ref = reference.map(Double.init)
        let ps = NoiseProfile.powerSpectrum(seg), pr = NoiseProfile.powerSpectrum(ref)
        let n = (ps.count - 1) * 2
        var es = 0.0, er = 0.0
        for k in 1..<ps.count {
            let f = Double(k) * sampleRate / Double(n)
            guard band.contains(f) else { continue }
            es += ps[k]
            er += pr[k]
        }
        guard er > 0, es > 0 else { return nil }
        return 10 * log10(es / er)
    }

    public struct Peak: Sendable, Equatable {
        public var lag: Double            // fractional lag (frames)
        public var relativeDb: Double     // relative to the strongest peak (<= 0)
        public var peakToNoiseDb: Double  // relative to the median envelope level
    }

    /// Distinct local maxima of an envelope, strongest first: at most `maxCount`, at least
    /// `separation` frames apart, no weaker than `floorDb` below the strongest.
    public static func peaks(_ env: [Float], separation: Int, floorDb: Double = -12, maxCount: Int = 4) -> [Peak] {
        guard env.count > 2, let vmax = env.max(), vmax > 0 else { return [] }
        let sorted = env.sorted()
        let median = Double(sorted[sorted.count / 2])
        let threshold = vmax * Float(pow(10, floorDb / 20))
        var candidates: [Int] = []
        for k in 1..<(env.count - 1) where env[k] >= threshold && env[k] >= env[k - 1] && env[k] >= env[k + 1] {
            candidates.append(k)
        }
        candidates.sort { env[$0] > env[$1] }
        var chosen: [Int] = []
        for k in candidates where chosen.allSatisfy({ abs($0 - k) >= separation }) {
            chosen.append(k)
            if chosen.count == maxCount { break }
        }
        return chosen.map { k in
            Peak(lag: refine(env, k), relativeDb: 20 * log10(Double(env[k]) / Double(vmax)),
                 peakToNoiseDb: 20 * log10(Double(env[k]) / max(median, 1e-20)))
        }
    }

    /// Parabolic interpolation around a peak.
    static func refine(_ y: [Float], _ k: Int) -> Double {
        guard k > 0, k + 1 < y.count else { return Double(k) }
        let a = Double(y[k - 1]), b = Double(y[k]), c = Double(y[k + 1])
        let d = a - 2 * b + c
        guard abs(d) > 1e-30 else { return Double(k) }
        return Double(k) + max(-0.5, min(0.5, 0.5 * (a - c) / d))
    }
}

/// Robust statistics for repeated measurements.
public enum RobustStats {
    public static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return .nan }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : 0.5 * (s[s.count / 2 - 1] + s[s.count / 2])
    }

    /// Inliers: values within max(`floor`, 3 * scaled MAD) of the median.
    public static func inliers(_ v: [Double], floor: Double) -> [Double] {
        guard v.count > 2 else { return v }
        let med = median(v)
        let mad = median(v.map { abs($0 - med) }) * 1.4826
        let limit = max(floor, 3 * mad)
        return v.filter { abs($0 - med) <= limit }
    }

    public static func standardDeviation(_ v: [Double]) -> Double {
        guard v.count > 1 else { return 0 }
        let mean = v.reduce(0, +) / Double(v.count)
        return (v.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(v.count - 1)).squareRoot()
    }
}
