# Validation report

Test machine: MacBook Pro (Apple Silicon), macOS 27.0, Xcode 26.4.1. Outputs: Creative Pebble V2 on the
headphone jack ("External Headphones", 48 kHz) and a Sony SRS-XB10 stereo pair over Bluetooth A2DP
(44.1 kHz). Microphone: built-in MacBook Pro microphone.

**Legend:** HW = verified on real hardware; SIM = automated simulation driving the real C kernel with
synthetic clocks; — = not yet tested.

| # | Test | Result | How |
|---|---|---|---|
| A | Single device plays normally, no echo/feedback | SIM ✅, HW partial | The tap excludes SyncForge (no feedback by construction); SIM delay test >70 dB SNR. HW was exercised with two outputs, not one alone. |
| B | Two wired outputs, identical audio, independent volume, manual delay | SIM ✅ | `testIndependentDelaysAndVolumes`. No second wired device was available for HW. |
| C | Wired + Bluetooth, delay compensation aligns them | **HW ✅** | `sfctl run` and `sfctl calibrate --hold`: both played system audio, 0 underruns, servo lock ±5 µs. The user confirmed by ear: "only a very small little difference". |
| D | Microphone calibration: signals, recording, latency, apply, re-measure | **HW ✅** | Final run: wired 34.12 ms (spread 0.01 ms, 60 dB), Bluetooth 452.9 ms (spread 0.57 ms, 60 dB), compensation +418.8 ms. Verification: the Bluetooth latency moved ~7 ms within ~15 s. Values refined from the verification runs. |
| E | Clock drift does not accumulate | SIM ✅, HW short | SIM: source +150 ppm, outputs +250 / −300 ppm (incl. 48→44.1 kHz), 4.5 simulated minutes: lock error < 20 µs, no resyncs, SNR unchanged. HW: 20 s runs with ±5 µs lock error. A long HW run was not done. |
| F | Bluetooth disconnect/reconnect, recovery, recalibration | — | Implemented (profile restore, 2 s fade-in, recalibration flag, optional auto-recalibration). Not exercised on HW yet. |
| G | Independent EQ per output | SIM ✅ | `testEqualizerIsIndependentPerOutput`: +6.0 dB at 1 kHz on one output, the other output unchanged within 0.05 dB. Not verified acoustically. |
| H | 30-minute stability (glitches, underruns, leaks, CPU, drift) | — | `sfctl soak --seconds 1800` exists and reports CPU/RSS. Not run yet. 20 s runs: 2.4 % of one core, 18 MB resident. |
| I | Force-stop restores normal audio | **HW ✅ (tap cleanup)** | `kill -9` during playback. macOS removes private taps and aggregates with the process; the user should confirm by ear that normal playback returned. |

## Automated suite

`cd SyncForgeKit && swift test -c release` runs the release suite. The current count and deployment
checks are recorded below; the opt-in CPU benchmark is skipped during ordinary runs.

- Kernel (SIM): delayed playback SNR > 70 dB; two outputs with different delays and gain; 48 → 44.1 kHz
  conversion SNR > 60 dB; drift; click-free 363 ms delay change (max sample step < 3× natural); 1.5 ms fine
  slew (< 50 µs after 2 s, then full convergence, slew ≤ 0.2 %); underrun detection; 150 ms capture gap
  bridged without resync; EQ independence; limiter ceiling; test-signal timing exact to one sample.
- DSP: peak/shelf gains, Butterworth −3 dB and slopes for 12–48 dB/oct, Nyquist guard, flat neutrality,
  auto-headroom.
- Calibration: direct sound found within 0.3 ms despite a stronger reflection, reverb, noise and speaker
  coloration; mic path band-limited at 5 kHz handled with a noise profile; pure noise rejected; robust
  statistics; mic timeline mapping.
- Persistence: round trip and forward-compatible decoding of older/partial files.
- Integration: all-output construction/start failure releases the capture tap, partial failure
  preserves healthy playback, retries rebuild capture, no selected outputs starts no capture, and
  headless diagnostics retain real counters and full timing precision without visible UI.
- Calibration feedback: real C-rendered sweeps preserve physical speaker response while removing
  existing digital EQ, repeated correction fitting remains stable, 44.1 kHz output filters are
  evaluated correctly for a 48 kHz microphone, and deep digital stopbands remain unobservable.
- Concurrency: atomic snapshots reject mixed generations, and mic resets hide an in-flight old
  callback's publication until a new recording window is acknowledged.
- Presets: response and combined headroom at 44.1/48/96 kHz, a monotonic bass shelf, intended tone
  regions, and older custom presets without descriptions.
- Live Sync analysis: synthetic offsets at native and mixed rates, rhythm rejection, sinc-resampler
  timing and alias suppression, consecutive fresh windows without reusing overlapping evidence,
  rollback invalidation after calibration/EQ/output changes, and the worker's actor executor.

### Reliability hardening (2026-10-17)

These checks use injected audio backends and synthetic IO buffers; they open no real audio devices.
They do not qualify hardware reconnect, sleep/wake, long-run stability or real-room Live Sync accuracy.
The CLI now reads raw snapshots independently of visibility-gated meters and fails a run with no
locked timing measurements. Earlier hardware measurements predate that diagnostic publication
regression; the repaired tool still needs an actual hardware soak.

Results for this hardening pass:

- Release package suite: 47 tests passed, zero failures.
- Thread Sanitizer: all 3 concurrency tests passed, with no sanitizer reports. Command:
  `swift test --scratch-path /tmp/syncforge-tsan-build --sanitize=thread --filter ConcurrencyTests`.
- Unsigned Release app build: succeeded with `CODE_SIGNING_ALLOWED=NO`; the app was not installed or launched.
- Auto-EQ de-embedding models linear digital filters. Limiting/clipping and changes in microphone or
  room response remain measurement limitations requiring hardware evaluation.

### Live Sync and EQ refresh (2026-10-17)

The Live Sync worker uses anti-aliased 16 kHz analysis off the main actor. Complete fresh 3 s
recordings remain; the idle interval falls from 6 s to 0.5 s. This reduces the nominal check cycle
from 9.15 s to 3.65 s, plus computation, without adding playback buffering. Candidate identity and
reflection handling still need independent real-room evaluation.

On an Apple M3 Max, the complete offline pipeline measured 19.6–19.9 ms CPU per check versus
55.7–56.7 ms before. At each version's nominal cadence, this projects to 0.54–0.55% versus
0.61–0.62% of one core. It excludes audio callbacks, rendering, UI and sample extraction. See
[research and reproducible benchmark](LIVE_SYNC_RESEARCH.md) for conditions and limitations.

The new EQ bank uses broad tone controls informed by published RME and CamillaDSP controls;
the gains are SyncForge choices. [Preset definitions and sources](EQ_PRESETS.md) document their
limits. Electrical response tests do not establish a subjective or acoustic improvement.

- Release suite: 61 tests executed, one opt-in benchmark skipped, zero failures. The CPU benchmark
  was run separately and passed before the subsequent rollback-context guard (which does not alter DSP).
- Signed Release app built and installed in `~/Applications/SyncForge.app`, then relaunched through
  the native UI. The installed executable SHA-256 matched the build. Its designated requirement
  retained the existing local signing certificate, so the existing audio permissions remained usable.
- Native UI showed capture at 48 kHz, three enabled outputs with active meters, and Live Sync using
  the MacBook microphone. The activity log showed monitoring resume, waiting when music stopped,
  and monitoring resume again. No calibration or test signal was started.
- Reselected the refreshed Music preset in the native UI: 85 Hz +2 dB and 6.5 kHz +1 dB shelves,
  automatic headroom, initially 0 dB manual preamp. A saved-state comparison immediately afterwards
  showed identical output profiles and master volume; existing calibration/corrections were retained.
  Later manual preamp adjustments were observed and left in place.
- A 20.01 s live process sample consumed 2.76 CPU seconds, or 13.79% of one core. A later native UI
  inspection found the equalizer window open again, and the log showed music/monitoring resume.
  Window visibility and program level were not controlled; this is not a clean background benchmark
  and is not directly comparable with the earlier 4.75% short sample. A separate stack sample showed
  substantial AppKit/SwiftUI drawing work alongside audio processing. No 30-minute soak was run.

### Public source preparation (2026-10-17)

- `SYNCFORGE_SIGN_IDENTITY=- scripts/build.sh --test`: succeeded. Release package suite executed
  61 tests with one opt-in benchmark skipped and zero failures; the app built with ad-hoc signing.
- Shell syntax, GitHub configuration YAML, and 36 local Markdown/HTML links checked successfully.
- Publication changes cover documentation, screenshots, licensing and repository configuration;
  the only test-source change is a comment describing the preserved numerical baseline.
- Screenshots were captured from the running app or supplied by the owner. No calibration, test
  signal, output selection or DSP-setting changes were made for the screenshots.
- The GitHub workflow also runs the C handoff regression tests under Thread Sanitizer. CI results
  are available from the repository's Actions tab; local validation alone does not establish CI success.

### Setup recall and control improvements (2026-10-18)

- `SYNCFORGE_SIGN_IDENTITY=- scripts/build.sh --test`: succeeded. The release suite executed
  73 tests, with one opt-in benchmark skipped and zero failures. The ad-hoc signed Release app
  built and passed signature verification; it was not installed.
- Twelve new tests cover legacy setup decoding, playback-setting recall, selected-setup
  persistence, temporary solo, grouped undo/redo, calibration restoration and reset, and stopping
  sync-test clicks before calibration. Audio backends are mocks; no real devices are opened.
- Undo regressions include background timing updates and device discovery both after an edit and
  between updates during a slider drag. Those changes survive undo/redo.
- Native UI checks used an isolated preview with in-memory settings and the audio engine off.
  Exact volume entry, invalid-value rejection, Escape cancellation, setup recall and undo,
  text-field undo/redo, and one-step undo of a complete volume drag were exercised. Output cards
  and the EQ toolbar were inspected at the default window size.
- This pass does not qualify audible solo transitions, microphone calibration timing, Live Sync
  accuracy, reconnect behavior or acoustic alignment. No audio capture or calibration was started
  during the UI checks.

## Issues found on hardware and fixed

1. PHAT weighting gave noise-only bins (above the mic's ~5–6 kHz cut-off) full weight. Result: 17 dB
   peak-to-noise and peaks jumping by ~10 ms. **Fix:** per-bin Wiener SNR weighting from a room-noise
   profile. Result: 60 dB and 0.01 ms spread.
2. Subtracting the driver-reported mic latency (50 ms) produced negative latencies. **Fix:** arrivals are
   measured at the mic's time stamp; the common mic delay cancels.
3. Servo integrator windup caused a 0.24 ms overshoot with a minute-long tail (found in SIM). **Fix:**
   proportional servo with clock-ratio feed-forward.
4. Test-signal rounding could skip a one-sample impulse (SIM). **Fix:** correct nearest-sample indexing.

5. App idle CPU was 30–40 % (CLI: 2.4 %). The hidden menu bar panel kept SwiftUI re-rendering animated
   10 Hz meters. **Fix:** meters are published only while a view is visible, values are quantized, and the
   meters no longer animate. Result: ~2.7 % of one core with two outputs.
6. Uncalibrated outputs mixed with calibrated ones were ~32 ms late: measured values include the mic's
   delay, driver estimates don't. **Fix:** driver estimates are offset by the mic delay estimated from
   calibrated wired outputs.

7. Reported by the user: with three outputs, the Bluetooth output went permanently silent until it was
   toggled. Cause: a delay jump while the old read position was unreadable started a crossfade that could
   never finish. **Fix:** crossfade only from a playing position, and drop the old head if it becomes
   unreadable (regression test `testRecoversWhenJumpingFromUnreadablePosition`). Also added: a watchdog that
   rebuilds an output that stays silent while audio plays, and a persistent log at
   `~/Library/Logs/SyncForge/activity.log`.

8. Reported by the user: outputs drift apart minutes after any calibration. The activity log showed the
   SRS-XB10's latency changing on its own: 457 → 626 → 646 ms over 17 minutes, +30 ms within 15 s,
   then a ~120 ms drop. The wired output repeated at 34.1 ms throughout. macOS exposes nothing about the
   Bluetooth buffer, so static calibration can't hold. **Added:** *Live Sync*, an opt-in mode that
   cross-correlates the microphone with the program while music plays, measures the wireless output's
   offset from its separate correlation peak and corrects it. A correction is undone if the peak doesn't
   move, which identifies reflections. Also added: logging of output clock jumps. Unit-tested on
   synthetic music; real-room performance not yet verified.

9. First real Live Sync runs: a clear wired peak in every check; it detected and corrected a −77 ms
   Sony drift. Problems found and fixed:
   - consecutive Bluetooth readings disagree by up to ~10 ms, so the agreement tolerance is now
     proportional to the drift;
   - rhythmic music resembles itself at beat subdivisions, so candidates the program's own self-similarity
     explains are ignored;
   - calibration and Live Sync could use different microphones, so one microphone setting now drives both;
   - Live Sync silently stayed off when the microphone permission had been lost after an ad-hoc-signed
     rebuild. It now always starts and asks for permission. Use `scripts/create-signing-identity.sh`
     to keep permissions across rebuilds.

## Not claimed

- Sub-2 ms synchronization with Bluetooth is **not** claimed. The measurement repeats to ±0.3 ms, but the
  Bluetooth latency itself wandered by ~7 ms during a session.
- Behaviour with USB, HDMI/DisplayPort, multichannel devices, or more than two simultaneous outputs has not
  been tested on hardware.
