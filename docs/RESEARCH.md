# Research notes

The reference projects were studied for approach only. **No code was copied** into SyncForge.

| Project | License | Relevance | Assessment | Reuse |
|---|---|---|---|---|
| Apple "Capturing system audio with Core Audio taps" / AudioCap (insidegui) | Apple sample / BSD-2 | Process tap + private aggregate recipe, TCC preflight | Small, authoritative, maintained | Studied (API usage pattern) |
| [In_Unison42](https://github.com/Okle42/In_Unison42) | MIT | Closest match: global tap, per-device delay, mic calibration, Bluetooth outside the aggregate, IOProc stream-usage to avoid opening HFP mics | Very new single-author project, large files, Chinese comments. Its notes on Bluetooth and earliest-arrival detection were useful. | Studied. SyncForge's timeline lock / resampler design was arrived at independently and confirmed by its notes |
| [Split](https://github.com/barongartner/Split) | MIT | Per-app taps routed to individual outputs with delay | Small, young | Studied (tap/aggregate keys) |
| [FineTune](https://github.com/ronitsingh10/FineTune) | GPL-3.0 | Per-app volume, multi-output, EQ UI, menu bar | Mature and popular; GPL-3.0 means no code reuse without relicensing | Not reused |
| [Fader](https://github.com/pantafive/fader) | MIT | Device enumeration, menu bar mixer | Small, clean | Studied |
| [BlackHole](https://github.com/ExistentialAudio/BlackHole) | GPL-3.0 | Virtual loopback driver | Mature, but a driver is exactly what we avoid | Not needed |
| [Background Music](https://github.com/kyleneideck/BackgroundMusic) | GPL-2.0+ | System-wide audio via a virtual device | Mature, pre-tap era architecture | Not needed |
| [AudioKit](https://github.com/AudioKit/AudioKit) | MIT | DSP building blocks | Large dependency, AVAudioEngine-centric | Not needed |

## Decisions

- **Driverless capture** with a global process tap (macOS 14.2+; 14.4 baseline for the fixed APIs).
- **No AVAudioEngine / AVAudioUnitEQ.** An AVAudioEngine graph binds to a single output device. Rendering
  each device through its own HAL IOProc is what makes independent clocks, sample rates and delays
  possible. AVAudioUnitEQ would need a graph per device. Our biquad cascade is ~30 lines of C and RT-safe.
- **No aggregate output device.** Aggregates force a common clock and sample rate, can open a Bluetooth
  device's mic (HFP), and fail as a whole when one member disconnects.
- **C for the real-time kernel**, Swift everywhere else. Swift doesn't guarantee freedom from allocation,
  locks or ARC traffic on the audio thread.

## Measurements that informed the design (this Mac)

- Output IO lead (output time stamp − now): 12.2 ms at 512 frames, for both wired and Bluetooth.
  Wired time stamps are within ±3 µs of a linear fit. The Bluetooth device runs a synthetic, perfectly linear
  clock at 44100.02 Hz.
- Tap capture age (now − input time stamp): 10.7 ms.
- SRS-XB10 driver-reported latency: 149 ms. Acoustically measured: ~420 ms later than the analog output.
- MacBook Pro microphone: reported input latency 50 ms (not a valid time stamp offset); the recorded band
  ends at ~5–6 kHz.
