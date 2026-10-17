import Foundation

/// Test signals for acoustic calibration and manual synchronisation.
public enum TestSignals {
    /// Exponential (logarithmic) sine sweep from `f0` to `f1`, peak-normalised to 1, with raised-
    /// cosine fades. Sweeps give a sharp correlation peak, spread energy over the band (so a weak
    /// tweeter or woofer does not prevent detection) and are robust against background noise.
    public static func logChirp(f0: Double = 60, f1: Double = 10000, duration: Double = 0.35,
                                sampleRate: Double, fade: Double = 0.01) -> [Float] {
        let n = max(16, Int(duration * sampleRate))
        let k = log(f1 / f0)
        let fadeN = max(1, Int(fade * sampleRate))
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let phase = 2 * Double.pi * f0 * duration / k * (exp(t / duration * k) - 1)
            var env = 1.0
            if i < fadeN { env = 0.5 - 0.5 * cos(Double.pi * Double(i) / Double(fadeN)) }
            if i >= n - fadeN { env = 0.5 - 0.5 * cos(Double.pi * Double(n - 1 - i) / Double(fadeN)) }
            out[i] = Float(sin(phase) * env)
        }
        return out
    }

    /// A short, bright click for the manual sync tool: a 2 kHz + 5 kHz burst with a fast attack and
    /// an exponential decay (~25 ms).
    public static func click(sampleRate: Double) -> [Float] {
        let n = Int(0.03 * sampleRate)
        return (0..<n).map { i in
            let t = Double(i) / sampleRate
            let attack = min(1, t / 0.0005)
            let env = attack * exp(-t / 0.006)
            return Float(env * (0.7 * sin(2 * .pi * 2000 * t) + 0.3 * sin(2 * .pi * 5000 * t)))
        }
    }

    public static func dbToGain(_ db: Double) -> Float { Float(pow(10, db / 20)) }
}
