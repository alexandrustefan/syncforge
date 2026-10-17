# SyncForge architecture

## Components

| Component (spec name) | Implementation |
|---|---|
| AudioDeviceManager | `HAL/AudioDeviceManager.swift`: enumerates devices, listens for list/default/alive/rate/stream/latency/volume changes and `ServiceRestarted` |
| SystemAudioCapture | `HAL/SystemAudioCapture.swift`: global process tap + tap-only private aggregate device, C IOProc `sf_capture_ioproc` |
| DelayBuffer / ring | `SyncForgeRT/sf_ring.c` + `HAL/SourceRing.swift`: interleaved stereo ring with a seqlock-published *program timeline* |
| AudioOutputRenderer | `SyncForgeRT/sf_renderer.c` + `HAL/OutputRenderer.swift`: one HAL IOProc per physical device |
| ClockDriftManager | inside the renderer: rate-scalar feed-forward + proportional position servo + windowed-sinc resampler |
| SynchronizationEngine | `Engine/SyncMath.swift` (compensation) + renderer timeline lock |
| AudioDSPProcessor / EqualizerEngine | `DSP/BiquadDesign.swift`, `DSP/EQModels.swift` (design, presets); filtering runs in the C renderer |
| MicrophoneCalibrationEngine / LatencyEstimator | `Calibration/CalibrationEngine.swift`, `Calibration/LatencyEstimator.swift`, `SyncForgeRT/sf_mic.c` |
| ProfileManager | `Profiles/ProfileStore.swift`, `Profiles/Models.swift` |
| AudioEngineCoordinator | `Engine/SyncEngine.swift` |
| SwiftUI frontend | `App/SyncForge/` |

## Signal path and timing model

1. **Capture.** A `CATapDescription(stereoGlobalTapButExcludeProcesses: [SyncForge])` with
   `muteBehavior = .mutedWhenTapped` and `isPrivate = true` is added to a private aggregate device that contains
   *only the tap* (verified on hardware: no sub-device is needed). The aggregate's IOProc (C) writes each buffer
   into the ring and publishes `(anchorFrame, anchorHost, framesPerTick)`. Gaps in host time (dropped cycles, a
   capture restart after a default-output change) are filled with silence, so the frame ↔ host-time mapping
   stays continuous and outputs keep their alignment across capture restarts.

2. **Render.** Each enabled output has its own IOProc on its own device and clock. For a cycle presented at
   `T_out` (the IOProc's output time stamp), the renderer wants program frame
   `F(T_out − delay)` from the timeline. Its read head advances by
   `step = (src frames/tick ÷ device frames/tick) · (1 + c)`, where the ratio comes from Core Audio rate
   scalars (feed-forward) and `c = Kp · error` (Kp = 2/s, |c| ≤ 0.2 % ≈ 3.5 cents). Errors above 2 ms (delay
   edits, capture discontinuities) trigger a 30 ms equal-power crossfade instead of slewing. Interpolation is a
   64-tap Kaiser-windowed sinc (512 phases, cut-off below the lower Nyquist), which also does the
   sample-rate conversion.

3. **Per-device DSP** (in order): channel mode → preamp → biquad cascade (HPF, EQ bands, LPF; TDF-II, double
   precision) → smoothed gain (master × device × linked system volume × mute) → fade → test-signal mix →
   linked-stereo limiter → hard safety clip → meters → channel mapping into the device's buffers.

4. **Delay.** `total = base + compensation`. Compensation for automatic outputs is
   `max(arrival of all outputs) − latency(this output)` (+ trim); manual outputs keep their value but count
   when finding the latest arrival. The slowest output gets zero compensation. Nothing tries to make an
   output faster than its physical latency.

Measured on hardware (2 outputs, wired + Bluetooth): position-lock error within ±5 µs, no underruns,
2.4 % of one core, 18 MB resident.

## Real-time rules

The audio threads only run C: no allocation, locks, syscalls or Objective-C/Swift runtime. Control → RT uses
single-writer seqlocks whose payloads are arrays of lock-free atomic words. Both speculative payload
reads and writes use atomics; the sequence counter alone would not make ordinary struct copies safe
under C11. Readers never spin; if a snapshot is mid-write they keep the previous one. RT →
control uses relaxed atomics. Test-signal buffers are freed only after the IO thread acknowledges it adopted
a replacement. Rings are reference-counted (`SourceRing`) and outlive every IOProc that can touch them.
`AudioDeviceDestroyIOProcID` is the barrier before C state is freed.

If every output fails to construct or start, the coordinator destroys the muting capture tap and
reports the failure. A failed output does not stop another output that started successfully.
Raw diagnostic snapshots are retained regardless of UI visibility; quantized UI meters remain gated.
Microphone window resets are applied by the IO thread at a callback boundary. While a reset is
pending, frame/anchor getters hide the previous window, including late publication by an old callback.

## Calibration

- Signal: 0.35 s exponential sweep 200 Hz–10 kHz, -18 dBFS (auto-raised by 6 dB steps if not detected).
  It is scheduled on the program timeline, so it passes through the same delay, timing and filters as music.
  Volume doesn't apply to it.
- Microphone: own HAL IOProc with per-buffer host time stamps. Bluetooth microphones are refused by default
  (they force the hands-free profile). Raw audio stays in memory.
- Estimation: cross-spectrum with PHAT-β (0.8) whitening × per-bin Wiener SNR weight from a room-noise
  recording; analytic correlation envelope; earliest local peak within 20 ms and −6 dB of the strongest
  (direct sound before reflections); parabolic sub-sample refinement.
- Procedure: coarse search (0–2.5 s), then 5 repetitions in a ±30 ms window; median of MAD-inliers;
  confidence from repeatability and peak-to-noise ratio. Then compensation, then a verification pass
  (3 repetitions per output with the new delays). If outputs moved, the most recent values are applied.

Hardware result (MacBook Pro mic, External Headphones + SRS-XB10): 60 dB peak-to-noise, 0.01 ms spread
(wired), 0.57 ms spread (Bluetooth). The Bluetooth latency itself moved ~7 ms between measurement and
verification.

## Adversarial review

1. **Can process taps capture system audio without a driver?** Yes. Verified on macOS 27: a global stereo tap
   in a tap-only private aggregate delivered 48 kHz Float32 program audio. No BlackHole needed.
2. **Several devices with independent clocks?** One IOProc per device, no aggregate output device. Each
   renderer resamples from the shared timeline to its own clock. A device that disappears doesn't stop the
   others (unlike an aggregate/Multi-Output device).
3. **Buffering without underruns?** A shared base latency (45 ms default) covers the capture cycle plus each
   device's IO lead (measured: ~11 ms capture age, ~12 ms output lead at 512-frame buffers). Renderers check
   availability before reading. Underruns produce silence plus a counter, and the engine raises the base
   latency in 10 ms steps.
4. **No double playback?** `mutedWhenTapped` silences the tapped processes' original output while
   SyncForge reads them. SyncForge's own process is excluded from the tap. When SyncForge is off or has no
   outputs, the tap is destroyed and macOS plays normally.
5. **Acoustic vs driver latency?** The microphone measures actual arrival. Driver metadata is used only as a
   labeled fallback before calibration. It was wrong by ~300 ms for the SRS-XB10 (reports 149 ms; measured
   ~420 ms more than the analog output).
6. **Bluetooth latency after reconnecting?** The device's profile is restored (fade-in over 2 s). Bluetooth
   outputs are flagged "recalibration recommended", as are outputs whose reported latency changed by >5 ms.
   Optional automatic recalibration of just that output.
7. **Direct sound vs reflections?** PHAT sharpening plus "earliest strong peak" selection (tested in
   simulation with a stronger desk reflection 1.4 ms later and a reverberant tail).
8. **Stable common reference across outputs?** Host time. Output presentation time stamps and microphone
   time stamps share the mach clock. Any constant microphone delay is common to all outputs and cancels.
   Measured wired repeatability was 0.01 ms. Residual error is dominated by Bluetooth wandering.
9. **Drift without audible artifacts?** Real drift is tens of ppm. The servo corrects it at microscopic rates
   (≤ 0.2 % slew, typically < 10 ppm), far below audibility. Large jumps crossfade.
10. **EQ without breaking sync?** IIR filters add no buffering. Their group delay is small and frequency
    dependent. Calibration sweeps run through the same filters, so the measured compensation includes it.
11. **Privacy/sandbox/signing?** Not sandboxed, hardened runtime, `com.apple.security.device.audio-input`,
    `NSAudioCaptureUsageDescription` + `NSMicrophoneUsageDescription`. TCC ties permissions to the signature,
    so use a stable signing identity (script provided). There is no public API to query the audio-capture
    permission: SyncForge uses the TCC preflight lookup that AudioCap uses, with a fallback.
12. **DRM?** Audio that macOS excludes from taps is not captured. SyncForge can't (and shouldn't) bypass this.
13. **Engine crash?** Private taps and aggregates are owned by the process. On exit or crash macOS removes
    them and the mute ends. A force-kill test was performed (`kill -9` mid-playback). On normal quit,
    `shutdown()` stops everything first.
14. **Virtual driver necessary?** No (see 1). The only things a driver would add are per-app routing to
    non-default devices and capture of DRM-excluded audio, and the latter is not desirable.
15. **Confirmed vs experimental?** Confirmed on hardware: capture, muting, dual-device playback, delay,
    calibration, kill recovery (tap cleanup). Simulation only: drift over long runs, EQ independence, delay
    crossfades, sample-rate conversion quality. Implemented but untested on hardware: reconnection, sleep/wake,
    service restart, more than two outputs, multichannel devices, USB/HDMI outputs.

## Interleaved calibration, level matching and auto-EQ (v1.1)

- After a coarse search per output, all outputs play sweeps in turn. Emission times are offset by each
  output's expected latency, so the sweeps *arrive* 0.8 s apart and never overlap. Each output is measured
  relative to a reference output (preferably wired), with the reference's latency interpolated to the same
  instant (`DriftCancellation`). This cancels slow drift of the microphone path, which matters for an
  iPhone over the air.
- Every sweep also yields the response at the microphone (`AutoEQ.response`: recording ÷ sweep, 1/12-octave
  grid, SNR-gated against the room-noise profile) and a band level (200 Hz–4 kHz). Before fitting,
  the known digital cascade is removed from spectral power at the output's sample rate. This includes
  previous automatic correction and deliberate system/output EQ. Deep digital nulls are excluded.
  Latency measurement still uses the actual filtered path. Changing the cascade during a measurement
  aborts calibration instead of fitting against an obsolete processing snapshot.
- `AutoEQ.plan`: each output's 1/6-octave-smoothed shape (level removed) is compared with the average shape
  of all outputs. The difference is fitted with ≤ 5 gentle bands (cuts ≤ 8 dB, boosts ≤ 3 dB, shelves for
  tilts), so the microphone's unknown response cancels. Bass peaks above the average's 1-octave trend
  (35–300 Hz) become ≤ 3 room cuts in the system EQ. The chain per output is: room correction → system EQ →
  speaker correction → speaker EQ → limiter.
- `LevelMatching.trims`: quieter outputs get up to +6 dB, louder ones are cut to match.

## Research and future work

- Live Sync monitors fresh three-second windows using anti-aliased 16 kHz analysis on its own actor.
  [Research](LIVE_SYNC_RESEARCH.md) proposes rolling windows, richer confidence tracking and calibrated
  path templates; those follow-up stages are not implemented.
- Ambient / rear-speaker mode (decorrelation, extra delay, level) and crossover-based bass management helper.
- Per-app capture (tap selected processes instead of global).
