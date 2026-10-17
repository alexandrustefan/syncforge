import Darwin
import Foundation
import SyncForgeCore

// sfctl — headless control and validation for the SyncForge engine.
//
// It drives exactly the same engine as the app, with an in-memory profile store, so it never
// changes the app's saved configuration.

let usageText = """
usage: sfctl <command> [options]

  devices                                   List audio devices with driver-reported latencies.
  run --out UID[:DELAY_MS] ... [--seconds N]
                                            Capture system audio and play it on the given outputs.
                                            DELAY_MS sets a manual delay; otherwise driver estimates are used.
  calibrate --out UID ... [--mic UID] [--level DB] [--hold SECONDS] [--no-verify] [--match-levels]
                                            Measure acoustic latency with the microphone, apply it and verify.
  soak --out UID[:DELAY_MS] ... [--seconds N]
                                            Long-running stability test with periodic resource reports.

Everything that plays sound mutes normal system playback while it runs (it comes back when sfctl exits).
"""

struct Arguments {
    var command = ""
    var outputs: [(uid: String, delay: Double?)] = []
    var seconds: Double = 20
    var mic: String?
    var level: Double?
    var hold: Double = 0
    var verify = true
    var dump: String?
    var matchLevels = false

    init(_ argv: [String]) throws {
        var it = argv.dropFirst().makeIterator()
        guard let cmd = it.next() else { throw CLIError.usage }
        command = cmd
        while let a = it.next() {
            switch a {
            case "--out":
                guard let v = it.next() else { throw CLIError.usage }
                // UIDs may contain ':' (e.g. Bluetooth MAC addresses); a delay is the last
                // component only if it parses as a number.
                if let r = v.range(of: ":", options: .backwards), let d = Double(v[r.upperBound...]) {
                    outputs.append((String(v[..<r.lowerBound]), d))
                } else {
                    outputs.append((v, nil))
                }
            case "--seconds": seconds = Double(it.next() ?? "") ?? seconds
            case "--mic": mic = it.next()
            case "--level": level = Double(it.next() ?? "")
            case "--hold": hold = Double(it.next() ?? "") ?? 0
            case "--no-verify": verify = false
            case "--dump": dump = it.next()
            case "--match-levels": matchLevels = true
            default: throw CLIError.unknown(a)
            }
        }
    }
}

enum CLIError: Error, CustomStringConvertible {
    case usage, unknown(String), noDevice(String)
    var description: String {
        switch self {
        case .usage: return usageText
        case .unknown(let a): return "unknown option \(a)\n\n\(usageText)"
        case .noDevice(let u): return "no output device with UID \(u) (see `sfctl devices`)"
        }
    }
}

func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
func f(_ v: Double, _ d: Int = 1) -> String { String(format: "%.\(d)f", v) }

@MainActor
final class CLI {
    let args: Arguments
    var engine: SyncEngine!
    var calibration: CalibrationEngine!

    init(_ args: Arguments) { self.args = args }

    func run() async -> Int32 {
        switch args.command {
        case "devices": return listDevices()
        case "run": return await play(soak: false)
        case "soak": return await play(soak: true)
        case "calibrate": return await calibrate()
        default:
            print(usageText)
            return 2
        }
    }

    func listDevices() -> Int32 {
        let dm = AudioDeviceManager()
        print("OUTPUTS")
        for d in dm.outputDevices {
            let def = d.uid == dm.defaultOutputUID ? " (default)" : ""
            print("  \(pad(d.name + def, 34)) \(pad(d.transport.displayName, 12)) \(pad(f(d.nominalSampleRate / 1000, 1) + " kHz", 9)) ch \(d.outputChannels)  reported \(f(d.reportedOutputLatencyMs)) ms")
            print("      uid: \(d.uid)")
        }
        print("INPUTS")
        for d in dm.inputDevices {
            let def = d.uid == dm.defaultInputUID ? " (default)" : ""
            let warn = d.transport.isBluetooth ? "  ⚠︎ Bluetooth (avoid for calibration)" : ""
            print("  \(pad(d.name + def, 34)) \(pad(d.transport.displayName, 12)) \(pad(f(d.nominalSampleRate / 1000, 1) + " kHz", 9)) reported \(f(d.reportedInputLatency * 1000)) ms\(warn)")
            print("      uid: \(d.uid)")
        }
        if let m = dm.recommendedMicrophone { print("Recommended calibration microphone: \(m.name)") }
        return 0
    }

    func makeEngine() throws {
        let store = ProfileStore(fileURL: nil)
        let dm = AudioDeviceManager()
        engine = SyncEngine(devices: dm, store: store)
        for (uid, delay) in args.outputs {
            guard let d = dm.outputDevice(uid: uid) else { throw CLIError.noDevice(uid) }
            store.register(d)
            store.update(uid) {
                $0.enabled = true
                if let delay {
                    $0.delayMode = .manual
                    $0.manualDelayMs = delay
                }
            }
        }
        calibration = CalibrationEngine(engine: engine)
    }

    func printStatus(elapsed: Double) {
        var line = "[\(pad(f(elapsed, 0) + "s", 5))] capture \(pad(f(Double(engine.captureLevelDbRaw), 0) + " dB", 8))"
        for o in engine.outputs where o.profile.enabled {
            guard let m = engine.diagnostics[o.uid] else {
                line += " | \(o.name): \(o.status.label), diagnostics pending"
                continue
            }
            let peakDb = 20 * log10(max(max(m.peakLeft, m.peakRight), 1e-6))
            let delay = o.timing.map { f($0.appliedDelayMs) } ?? "-"
            line += " | \(o.name): \(o.status.label) +\(delay)ms pk \(f(Double(peakDb), 0)) err \(f(m.servoErrorSeconds * 1e6, 1))us \(f(m.correctionPPM, 0))ppm ur \(m.underruns) rs \(m.resyncs)"
        }
        print(line)
    }

    func play(soak: Bool) async -> Int32 {
        do { try makeEngine() } catch { print(error); return 1 }
        guard !args.outputs.isEmpty else { print(usageText); return 2 }
        engine.setEnabled(true)
        if case .failed(let m) = engine.captureStatus { print("capture failed: \(m)"); return 1 }
        print("Playing system audio on \(args.outputs.count) output(s) for \(f(args.seconds, 0)) s (base latency \(f(engine.effectiveBaseLatencyMs)) ms). Ctrl-C to stop.")
        let start = Date()
        var usage0 = rusage()
        getrusage(RUSAGE_SELF, &usage0)
        var lastReport = Date.distantPast
        var minErr: Double?, maxErr: Double?
        while Date().timeIntervalSince(start) < args.seconds {
            try? await Task.sleep(nanoseconds: 250_000_000)
            for m in engine.diagnostics.values where m.locked != 0 {
                minErr = min(minErr ?? m.servoErrorSeconds, m.servoErrorSeconds)
                maxErr = max(maxErr ?? m.servoErrorSeconds, m.servoErrorSeconds)
            }
            let interval = soak ? 10.0 : 1.0
            if Date().timeIntervalSince(lastReport) >= interval {
                lastReport = Date()
                printStatus(elapsed: Date().timeIntervalSince(start))
                if soak { printResources(since: start, usage0: usage0) }
            }
        }
        if let minErr, let maxErr {
            print("Sampled servo error range during run: \(f(minErr * 1e6, 1)) … \(f(maxErr * 1e6, 1)) µs")
        } else {
            print("No locked output measurements were collected; this run cannot establish synchronization.")
        }
        printResources(since: start, usage0: usage0)
        for e in engine.events where e.level != .info { print("event: \(e.message)") }
        engine.shutdown()
        return minErr == nil ? 1 : 0
    }

    func printResources(since start: Date, usage0: rusage) {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        func secs(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        let cpu = (secs(u.ru_utime) - secs(usage0.ru_utime)) + (secs(u.ru_stime) - secs(usage0.ru_stime))
        let wall = Date().timeIntervalSince(start)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        let rss = kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
        print("resources: CPU \(f(cpu / max(wall, 0.001) * 100, 2)) % of one core, resident memory \(f(rss)) MB")
    }

    func calibrate() async -> Int32 {
        do { try makeEngine() } catch { print(error); return 1 }
        guard !args.outputs.isEmpty else { print(usageText); return 2 }
        engine.setEnabled(true)
        if case .failed(let m) = engine.captureStatus { print("capture failed: \(m)"); return 1 }
        if let l = args.level { calibration.options.levelDb = l }
        calibration.options.verify = args.verify
        calibration.options.matchLevels = args.matchLevels
        if let d = args.dump { calibration.options.debugDumpDirectory = URL(fileURLWithPath: d) }
        try? await Task.sleep(nanoseconds: 800_000_000)
        print("Calibrating… (test sweeps will play on each output in turn)")
        do {
            let report = try await calibration.run(outputs: args.outputs.map(\.uid), microphoneUID: args.mic)
            print("\nMicrophone: \(report.microphoneName)")
            for m in report.measurements {
                print("Device: \(m.name)")
                if let l = m.latencyMs {
                    print("  Measured arrival: \(f(l, 2)) ms  (runs \(m.samplesMs.map { f($0, 2) }.joined(separator: ", ")))")
                    print("  Spread: \(f(m.spreadMs, 2)) ms, peak/noise \(f(m.peakToNoiseDb, 0)) dB, confidence \(m.confidence.rawValue)")
                    print("  Compensation: +\(f(m.compensationMs ?? 0, 1)) ms")
                    if let lv = m.relativeLevelDb { print("  Level at mic: \(f(lv, 1)) dB relative to the loudest output") }
                    if !m.correction.isEmpty {
                        print("  Tone correction: " + m.correction.map { "\($0.type.displayName) \(f($0.frequency, 0)) Hz \(f($0.gainDb, 1)) dB Q\(f($0.q, 2))" }.joined(separator: ", "))
                    }
                } else {
                    print("  FAILED: \(m.failure ?? "unknown")")
                }
                if let reported = engine.devices.outputDevice(uid: m.uid)?.reportedOutputLatencyMs {
                    print("  (driver-reported latency: \(f(reported)) ms)")
                }
            }
            if let b = report.differenceBeforeMs { print("Estimated difference before calibration: \(f(b, 1)) ms") }
            if !report.roomCorrection.isEmpty {
                print("Room resonances: " + report.roomCorrection.map { "\(f($0.frequency, 0)) Hz \(f($0.gainDb, 1)) dB" }.joined(separator: ", "))
            }
            if let v = report.verification {
                print("Verification (re-measured with compensation applied):")
                for (uid, a) in v.arrivalMs.sorted(by: { $0.key < $1.key }) {
                    print("  \(engine.devices.outputDevice(uid: uid)?.name ?? uid): arrival \(f(a, 2)) ms after capture")
                }
                print("Estimated remaining difference: \(f(v.remainingDifferenceMs, 2)) ms (repeatability \(f(v.repeatabilityMs, 2)) ms)")
            }
        } catch {
            print("Calibration failed: \(error.localizedDescription)")
            engine.shutdown()
            return 1
        }
        if args.hold > 0 {
            print("Playing system audio with the measured compensation for \(f(args.hold, 0)) s…")
            let start = Date()
            while Date().timeIntervalSince(start) < args.hold {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                printStatus(elapsed: Date().timeIntervalSince(start))
            }
        }
        engine.shutdown()
        return 0
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
let parsed: Arguments
do { parsed = try Arguments(CommandLine.arguments) } catch {
    print(error)
    exit(2)
}

let cli = MainActor.assumeIsolated { CLI(parsed) }
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
signal(SIGINT, SIG_IGN)
sigint.setEventHandler {
    MainActor.assumeIsolated { cli.engine?.shutdown() }
    print("\nStopped — normal audio restored.")
    exit(130)
}
sigint.resume()

Task { @MainActor in
    let code = await cli.run()
    exit(code)
}
RunLoop.main.run()
