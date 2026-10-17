import Accelerate
import Foundation

/// The worker owns its resampling tables. No microphone, renderer or UI state crosses this actor.
actor LiveSyncAnalysisWorker {
    private let processor = LiveSyncAnalysisProcessor()

    func analyze(mic: [Float], microphoneRate: Double, program: [Float], programRate: Double,
                 search: Double, ignored: [Double], referenceTolerance: Double) -> LiveSyncAnalysisResult {
        // Check this actor's executor, not a thread identity. The synchronous processor remains
        // on this executor throughout resampling and FFT work, including calls from the main actor.
        preconditionIsolated()
        guard !Task.isCancelled else { return .unavailable }
        return processor.analyze(mic: mic, microphoneRate: microphoneRate, program: program,
                                 programRate: programRate, search: search, ignored: ignored,
                                 referenceTolerance: referenceTolerance)
    }
}

struct LiveSyncAnalysisResult: Sendable {
    var peaks: [LiveSyncAnalyzer.Offset]
    var assessment: LiveSyncAnalyzer.Assessment?
    var rhythmic: Bool
    static let unavailable = Self(peaks: [], assessment: nil, rhythmic: false)
}

/// Synchronous entry point also used by the offline benchmark. Confined to the worker in the app.
final class LiveSyncAnalysisProcessor {
    private struct Rates: Hashable { var source: Double; var target: Double }
    private var resamplers: [Rates: LiveSyncResampler] = [:]

    func analyze(mic: [Float], microphoneRate: Double, program: [Float], programRate: Double,
                 search: Double, ignored: [Double] = [], referenceTolerance: Double = 0.008) -> LiveSyncAnalysisResult {
        guard microphoneRate.isFinite, programRate.isFinite,
              (4000...384000).contains(microphoneRate), (4000...384000).contains(programRate),
              search.isFinite, search > 0, !mic.isEmpty, !program.isEmpty else { return .unavailable }
        let rate = min(16000, microphoneRate, programRate)
        let microphone = resample(mic, from: microphoneRate, to: rate)
        let reference = resample(program, from: programRate, to: rate)
        let peaks = LiveSyncAnalyzer.offsets(mic: microphone, program: reference, sampleRate: rate, search: search)
        let assessment = LiveSyncAnalyzer.assess(peaks, ignored: ignored, referenceTolerance: referenceTolerance)
        let rhythmic: Bool
        if let offset = assessment?.wirelessOffset {
            rhythmic = (LiveSyncAnalyzer.selfSimilarityDb(program: reference, sampleRate: rate,
                                                          lags: [offset]).first ?? -100) > -10
        } else {
            rhythmic = false
        }
        return LiveSyncAnalysisResult(peaks: peaks, assessment: assessment, rhythmic: rhythmic)
    }

    private func resample(_ audio: [Float], from: Double, to: Double) -> [Float] {
        guard from != to else { return audio }
        let key = Rates(source: from, target: to)
        if resamplers[key] == nil {
            // A route change cannot grow the cache indefinitely.
            if resamplers.count >= 4 { resamplers.removeAll(keepingCapacity: true) }
            resamplers[key] = LiveSyncResampler(from: from, to: to)
        }
        return resamplers[key]!.process(audio)
    }
}

/// Offline, centred windowed-sinc conversion. A centred filter preserves sample-zero's timestamp;
/// both arrays are zero-extended at their edges. The 6 kHz cutoff at 16 kHz leaves a transition band
/// above Live Sync's 5 kHz passband and below the new Nyquist frequency. This is never used for playback.
final class LiveSyncResampler {
    let sourceRate: Double
    let targetRate: Double
    private let halfWidth: Int
    private let taps: Int
    private let phases = 256
    private let coefficients: [Float]

    init(from sourceRate: Double, to targetRate: Double) {
        precondition(sourceRate.isFinite && targetRate.isFinite && sourceRate >= targetRate && targetRate > 0)
        self.sourceRate = sourceRate
        self.targetRate = targetRate
        halfWidth = Int(ceil(24 * sourceRate / targetRate))
        taps = 2 * halfWidth + 1
        let cutoff = 0.375 * targetRate / sourceRate
        var table = [Float]()
        table.reserveCapacity((phases + 1) * taps)
        for phase in 0...phases {
            let fraction = Double(phase) / Double(phases)
            var row = [Double]()
            row.reserveCapacity(taps)
            for tap in -halfWidth...halfWidth {
                let distance = Double(tap) - fraction
                let position = distance / Double(halfWidth)
                let window = abs(position) <= 1 ? 0.42 + 0.5 * cos(.pi * position) + 0.08 * cos(2 * .pi * position) : 0
                let a = 2 * .pi * cutoff * distance
                row.append(2 * cutoff * (abs(a) < 1e-12 ? 1 : sin(a) / a) * window)
            }
            let sum = row.reduce(0, +)
            table.append(contentsOf: row.map { Float($0 / sum) })
        }
        coefficients = table
    }

    func process(_ input: [Float]) -> [Float] {
        guard !input.isEmpty else { return [] }
        let count = Int(Double(input.count) * targetRate / sourceRate)
        var padded = [Float](repeating: 0, count: input.count + 2 * halfWidth)
        padded.replaceSubrange(halfWidth..<(halfWidth + input.count), with: input)
        var output = [Float](repeating: 0, count: count)
        let ratio = sourceRate / targetRate
        padded.withUnsafeBufferPointer { samples in
            coefficients.withUnsafeBufferPointer { table in
                for i in 0..<count {
                    let position = Double(i) * ratio
                    let index = Int(position)
                    let phase = Int(((position - Double(index)) * Double(phases)).rounded())
                    vDSP_dotpr(samples.baseAddress! + index, 1, table.baseAddress! + phase * taps, 1,
                               &output[i], vDSP_Length(taps))
                }
            }
        }
        return output
    }
}

/// Two agreeing observations must describe distinct, recent acoustic windows. An unclear check
/// breaks the chain; overlapping/replayed data never supplies the second confirmation.
struct LiveSyncConfirmation {
    private var pending: (offset: Double, end: Double)?

    mutating func reset() { pending = nil }

    mutating func observe(_ offset: Double?, start: Double, end: Double) -> Double? {
        guard let offset, offset.isFinite, abs(offset) > 0.0025,
              start.isFinite, end.isFinite, end > start else { reset(); return nil }
        if let previous = pending {
            guard start >= previous.end - 0.000001 else { reset(); return nil }
            if start - previous.end <= 10, previous.offset * offset > 0,
               abs(previous.offset - offset) < max(0.004, 0.15 * max(abs(previous.offset), abs(offset))) {
                reset()
                return (previous.offset + offset) / 2
            }
        }
        pending = (offset, end)
        return nil
    }
}

struct LiveSyncPlaybackContext: Equatable {
    var profiles: [String: DeviceProfile?]
    var settings: AppSettings
}

/// A rollback belongs to the exact playback state left by our correction. A user edit or a new
/// calibration must never be overwritten by verification of an older correction.
struct LiveSyncPendingCorrection {
    var offset: Double
    var previousLatency: Double
    var uid: String
    var expectedContext: LiveSyncPlaybackContext

    func rollbackLatency(observedOffset: Double?, wirelessUID: String,
                         context: LiveSyncPlaybackContext) -> Double? {
        guard wirelessUID == uid, context == expectedContext, let observedOffset,
              abs(observedOffset - offset) < 0.0015 else { return nil }
        return previousLatency
    }
}
