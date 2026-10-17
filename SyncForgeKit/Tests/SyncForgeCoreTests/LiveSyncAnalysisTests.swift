import XCTest
import Darwin
@testable import SyncForgeCore

final class LiveSyncAnalysisTests: XCTestCase {
    func testReducedRateRetainsOffsetsAcrossNativeRates() {
        let processor = LiveSyncAnalysisProcessor()
        for (programRate, micRate) in [(48000.0, 48000.0), (48000, 44100), (44100, 48000), (96000, 48000)] {
            for offset in [-0.077, 0.017, 0.15] {
                let fixture = Fixture(programRate: programRate, micRate: micRate, offset: offset)
                let result = fixture.analyze(with: processor)
                XCTAssertNotNil(result.assessment, "\(programRate)/\(micRate), \(offset)")
                XCTAssertEqual(result.assessment?.referenceOffset ?? 1, 0, accuracy: 0.0005)
                XCTAssertEqual(result.assessment?.wirelessOffset ?? 1, offset, accuracy: 0.0005)
                XCTAssertFalse(result.rhythmic)
            }
        }
    }

    func testAlignedAndSilentInputsDoNotInventDrift() {
        let processor = LiveSyncAnalysisProcessor()
        let fixture = Fixture(offset: 0)
        let result = fixture.analyze(with: processor)
        XCTAssertNotNil(result.assessment)
        XCTAssertNil(result.assessment?.wirelessOffset)
        let silent = processor.analyze(mic: [Float](repeating: 0, count: 144000), microphoneRate: 48000,
                                       program: fixture.program, programRate: 48000, search: 0.35)
        XCTAssertNil(silent.assessment)
        XCTAssertTrue(silent.peaks.isEmpty)
    }

    func testRhythmGateSurvivesRateReduction() {
        let fixture = Fixture(offset: 0.077, rhythmic: true)
        let result = fixture.analyze(with: LiveSyncAnalysisProcessor())
        XCTAssertNotNil(result.assessment?.wirelessOffset)
        XCTAssertTrue(result.rhythmic)
    }

    func testResamplerPreservesTimingAndSuppressesOutOfBandAliases() {
        for sourceRate in [44100.0, 48000, 96000] {
            let converter = LiveSyncResampler(from: sourceRate, to: 16000)
            for frequency in [1000.0, 4900] {
                let input = (0..<Int(sourceRate / 4)).map { Float(sin(2 * .pi * frequency * Double($0) / sourceRate)) }
                let output = converter.process(input)
                let errors = (100..<(output.count - 100)).map { i in
                    Double(output[i]) - sin(2 * .pi * frequency * Double(i) / 16000)
                }
                XCTAssertLessThan(rms(errors), 0.01, "Passband/timing at \(frequency) Hz from \(sourceRate)")
            }
            // 12 kHz would alias to 4 kHz without filtering and contaminate the analysis band.
            let input = (0..<Int(sourceRate / 4)).map { Float(sin(2 * .pi * 12000 * Double($0) / sourceRate)) }
            let output = converter.process(input)
            XCTAssertLessThan(rms(output[100..<(output.count - 100)].map(Double.init)), 0.0001)
        }
    }

    func testConfirmationNeedsConsecutiveFreshWindows() {
        var evidence = LiveSyncConfirmation()
        XCTAssertNil(evidence.observe(0.017, start: 0, end: 3))
        XCTAssertEqual(evidence.observe(0.019, start: 3.65, end: 6.65) ?? 0, 0.018, accuracy: 1e-9)
        XCTAssertNil(evidence.observe(0.017, start: 7.3, end: 10.3))
        XCTAssertNil(evidence.observe(nil, start: 10.95, end: 13.95))
        XCTAssertNil(evidence.observe(0.017, start: 14.6, end: 17.6))
        XCTAssertNil(evidence.observe(0.017, start: 15, end: 18), "Overlapping audio cannot confirm")
        XCTAssertNil(evidence.observe(0.017, start: 18.65, end: 21.65))
        XCTAssertNil(evidence.observe(0.017, start: 40, end: 43), "Stale evidence cannot confirm")
        XCTAssertNil(evidence.observe(-0.017, start: 43.65, end: 46.65), "Opposite signs cannot confirm")
        XCTAssertEqual(evidence.observe(-0.018, start: 47.3, end: 50.3) ?? 0, -0.0175, accuracy: 1e-9)
        XCTAssertNil(evidence.observe(0.017, start: 51, end: 54))
        evidence.reset()
        XCTAssertNil(evidence.observe(0.017, start: 55, end: 58))
    }

    func testRollbackRequiresUnchangedPostCorrectionContext() {
        func context(latency: Double) -> LiveSyncPlaybackContext {
            var wireless = DeviceProfile(uid: "wireless", name: "Wireless", transport: .bluetooth)
            wireless.calibration = CalibrationRecord(latencyMs: latency, spreadMs: 0.5, peakToNoiseDb: 30,
                                                      confidence: .high, repetitions: 5,
                                                      date: Date(timeIntervalSince1970: 0),
                                                      microphoneUID: "mic", reportedLatencyMs: 150)
            let wired = DeviceProfile(uid: "wired", name: "Wired", transport: .builtIn)
            return LiveSyncPlaybackContext(profiles: ["wireless": wireless, "wired": wired], settings: AppSettings())
        }
        let corrected = context(latency: 417)
        let pending = LiveSyncPendingCorrection(offset: 0.017, previousLatency: 400, uid: "wireless",
                                                expectedContext: corrected)
        XCTAssertEqual(pending.rollbackLatency(observedOffset: 0.017, wirelessUID: "wireless", context: corrected), 400,
                       "Our own post-correction state must remain eligible for rollback")
        XCTAssertNil(pending.rollbackLatency(observedOffset: 0.017, wirelessUID: "wireless", context: context(latency: 400)),
                     "The pre-correction state is not the expected state")
        XCTAssertNil(pending.rollbackLatency(observedOffset: 0.017, wirelessUID: "wireless", context: context(latency: 510)),
                     "Do not overwrite an external recalibration")
        var changedEQ = corrected
        changedEQ.settings.systemDSP.bands[5].gainDb = 2
        XCTAssertNil(pending.rollbackLatency(observedOffset: 0.017, wirelessUID: "wireless", context: changedEQ))
        var changedOutputs = corrected
        changedOutputs.profiles.removeValue(forKey: "wired")
        XCTAssertNil(pending.rollbackLatency(observedOffset: 0.017, wirelessUID: "wireless", context: changedOutputs))
        XCTAssertNil(pending.rollbackLatency(observedOffset: 0.017, wirelessUID: "another-output", context: corrected))
        XCTAssertNil(pending.rollbackLatency(observedOffset: 0.003, wirelessUID: "wireless", context: corrected),
                     "A path that moved must not trigger reflection rollback")
    }

    @MainActor
    func testWorkerExecutorAndResultFromMainActor() async {
        let fixture = Fixture()
        let worker = LiveSyncAnalysisWorker()
        // analyze() checks its own actor executor with preconditionIsolated() immediately before
        // synchronous DSP. This exercises isolation from a main-actor caller without a thread claim.
        let result = await worker.analyze(mic: fixture.mic, microphoneRate: fixture.micRate,
                                          program: fixture.program, programRate: fixture.programRate,
                                          search: 0.35, ignored: [], referenceTolerance: 0.008)
        XCTAssertEqual(result.assessment?.wirelessOffset ?? 1, 0.017, accuracy: 0.0005)
    }

    /// Opt in; not a timing assertion in the normal test suite. No audio devices are opened.
    /// SYNCFORGE_LIVE_SYNC_BENCHMARK=1 swift test -c release --filter LiveSyncAnalysisTests/testOfflineBenchmark
    func testOfflineBenchmark() throws {
        guard ProcessInfo.processInfo.environment["SYNCFORGE_LIVE_SYNC_BENCHMARK"] == "1" else {
            throw XCTSkip("Set SYNCFORGE_LIVE_SYNC_BENCHMARK=1 for the offline CPU benchmark")
        }
        let repetitions = 30
        print("LIVE_SYNC_BENCH environment=\(ProcessInfo.processInfo.operatingSystemVersionString) processors=\(ProcessInfo.processInfo.processorCount) repetitions=\(repetitions)")
        for (name, fixture) in [
            ("music_like_48k", Fixture()),
            ("rhythmic_48k", Fixture(offset: 0.077, rhythmic: true)),
            ("music_like_48k_44k1", Fixture(programRate: 48000, micRate: 44100)),
        ] {
            let processor = LiveSyncAnalysisProcessor()
            let coldStart = cpuSeconds()
            let cold = fixture.analyze(with: processor)
            let coldMs = (cpuSeconds() - coldStart) * 1000
            let baseline = fixture.legacyAnalysis()
            XCTAssertNotNil(cold.assessment?.wirelessOffset)
            XCTAssertNotNil(baseline.assessment?.wirelessOffset)
            XCTAssertEqual(cold.rhythmic, baseline.rhythmic)
            var oldWalls = [Double](), newWalls = [Double]()
            var oldCPU = 0.0, newCPU = 0.0
            // Alternate order to reduce systematic warmup/thermal bias.
            for i in 0..<repetitions {
                let old = {
                    let cpu = self.cpuSeconds(), wall = self.wallSeconds()
                    let result = fixture.legacyAnalysis()
                    oldWalls.append((self.wallSeconds() - wall) * 1000)
                    oldCPU += self.cpuSeconds() - cpu
                    XCTAssertNotNil(result.assessment?.wirelessOffset)
                }
                let new = {
                    let cpu = self.cpuSeconds(), wall = self.wallSeconds()
                    let result = fixture.analyze(with: processor)
                    newWalls.append((self.wallSeconds() - wall) * 1000)
                    newCPU += self.cpuSeconds() - cpu
                    XCTAssertNotNil(result.assessment?.wirelessOffset)
                }
                if i % 2 == 0 { old(); new() } else { new(); old() }
            }
            func report(_ label: String, walls: [Double], cpu: Double, cycle: Double) {
                let sorted = walls.sorted()
                let cpuPerCheck = cpu / Double(repetitions)
                let p95 = sorted[Int(Double(repetitions - 1) * 0.95)]
                print(String(format: "LIVE_SYNC_BENCH %@ %@ wall_median_ms=%.3f wall_p95_ms=%.3f cpu_ms_per_check=%.3f projected_one_core_percent=%.3f cadence_seconds=%.2f",
                             name, label, sorted[repetitions / 2], p95, cpuPerCheck * 1000, cpuPerCheck / cycle * 100, cycle))
            }
            report("baseline", walls: oldWalls, cpu: oldCPU, cycle: 9.15)
            report("candidate", walls: newWalls, cpu: newCPU, cycle: 3.65)
            print(String(format: "LIVE_SYNC_BENCH %@ candidate_cold_cpu_ms=%.3f rhythm_gate=%@", name, coldMs, cold.rhythmic ? "rejected" : "accepted"))
        }
    }

    private func rms(_ values: [Double]) -> Double {
        (values.reduce(0) { $0 + $1 * $1 } / Double(values.count)).squareRoot()
    }

    private func cpuSeconds() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time)
        return Double(time.tv_sec) + Double(time.tv_nsec) * 1e-9
    }

    private func wallSeconds() -> Double { Double(DispatchTime.now().uptimeNanoseconds) * 1e-9 }

    private struct Fixture {
        let programRate: Double
        let micRate: Double
        let program: [Float]
        let mic: [Float]

        init(programRate: Double = 48000, micRate: Double = 48000, offset: Double = 0.017, rhythmic: Bool = false) {
            self.programRate = programRate
            self.micRate = micRate
            var state: UInt64 = 12345
            func random() -> Float {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return Float(Int64(bitPattern: state >> 11) % 2000) / 1000 - 1
            }
            let period = Int((0.077 * programRate).rounded())
            var cell = [Float](repeating: 0, count: period)
            var filtered: Float = 0
            for i in cell.indices { filtered += 0.2 * (random() - filtered); cell[i] = filtered }
            var source = [Float](repeating: 0, count: Int(3.7 * programRate))
            for i in source.indices {
                filtered += 0.2 * (random() - filtered)
                let time = Double(i) / programRate
                source[i] = rhythmic ? cell[i % period] + 0.1 * random()
                    : filtered * Float(0.6 + 0.4 * sin(2 * .pi * 1.7 * time)) + 0.2 * Float(sin(2 * .pi * 220 * time))
            }
            func sample(at seconds: Double) -> Float {
                let position = seconds * programRate
                let index = Int(position), fraction = Float(position - Double(index))
                guard index >= 0, index + 1 < source.count else { return 0 }
                return source[index] * (1 - fraction) + source[index + 1] * fraction
            }
            var microphone = [Float](repeating: 0, count: Int(3 * micRate))
            for i in microphone.indices {
                let time = 0.35 + Double(i) / micRate
                microphone[i] = 0.5 * sample(at: time) + 0.4 * sample(at: time - offset) + 0.02 * random()
            }
            program = source
            mic = microphone
        }

        func analyze(with processor: LiveSyncAnalysisProcessor) -> LiveSyncAnalysisResult {
            processor.analyze(mic: mic, microphoneRate: micRate, program: program, programRate: programRate, search: 0.35)
        }

        /// Matches the previous complete numerical path, including its linear cross-rate conversion.
        func legacyAnalysis() -> LiveSyncAnalysisResult {
            let reference: [Float]
            if programRate == micRate {
                reference = program
            } else {
                let ratio = programRate / micRate
                reference = (0..<Int(Double(program.count) / ratio)).map { i in
                    let position = Double(i) * ratio
                    let index = Int(position), fraction = Float(position - Double(index))
                    return index + 1 < program.count ? program[index] * (1 - fraction) + program[index + 1] * fraction
                        : program[min(index, program.count - 1)]
                }
            }
            let peaks = LiveSyncAnalyzer.offsets(mic: mic, program: reference, sampleRate: micRate, search: 0.35)
            let assessment = LiveSyncAnalyzer.assess(peaks)
            let rhythmic = assessment?.wirelessOffset.map {
                (LiveSyncAnalyzer.selfSimilarityDb(program: reference, sampleRate: micRate, lags: [$0]).first ?? -100) > -10
            } ?? false
            return LiveSyncAnalysisResult(peaks: peaks, assessment: assessment, rhythmic: rhythmic)
        }
    }
}
