# Development notes

These notes describe early development on one speaker setup. Historical measurements are not
current performance guarantees; see [validation](VALIDATION.md) for the evidence and open work.


The whole project was developed in one long session against the real speakers, with every step tested on
hardware where possible. In order:

1. **Research and probes.** Studied Apple's process-tap sample, In_Unison42, Split, FineTune, Fader,
   BlackHole, Background Music and AudioKit (approach only, no code copied; see
   [docs/RESEARCH.md](RESEARCH.md)). Small probes on this Mac confirmed that:
   - a tap-only aggregate captures audio without a driver,
   - output timestamps are clean (±3 µs),
   - the SRS-XB10 driver *reports* only 149 ms of latency, so metadata can't be trusted, and calibration is
     essential.

   (One probe briefly muted the music that was playing. Lesson learned: ask before anything audible.)
2. **Architecture.** One IOProc per device (no aggregate output device), a timestamp-locked delay line, and
   a C11 real-time kernel with a Swift engine around it.
3. **Kernel + simulation tests.** A clock simulator drives the real C kernel with synthetic timestamps.
   It found and fixed a servo windup overshoot (switched to a proportional loop with feed-forward) and an
   off-by-half-sample in test-signal timing.
4. **First hardware success.** Pebbles + Sony played together with 0 underruns, ±5 µs lock, 2.4 % CPU.
   Then the first calibration was applied, and the verdict was *"now it sounds amazing… only a very small
   little difference."*
5. **Calibration on real data.** Raw recordings showed that the MacBook mic cuts everything above ~5–6 kHz.
   PHAT gave those empty bins full weight (17 dB peak-to-noise, 10 ms scatter). **Noise-aware weighting** gave
   60 dB and 0.01 ms repeatability. The mic's reported 50 ms latency produced *negative* latencies, so it's no
   longer subtracted.
6. **Polish.** App icon, stable signing, idle CPU fixed from 40 % to ~3 % (hidden panels kept re-rendering).
   Driver estimates were put on the same scale as measurements (the MacBook speakers had been 32 ms late).
7. **A real bug from use.** With three outputs, the Sony went permanently silent until toggled. A delay jump
   from an unreadable position started a crossfade that could never finish. Fixed, with a regression test,
   a silent-output watchdog and a persistent activity log.
8. **v1.1 features.** System EQ, interleaved drift-cancelling calibration (iPhone support), level matching,
   auto-EQ.
9. **The big discovery.** *"No matter how many calibrations I do, they get desynced after a while."* The log
   showed the Sony pair's latency moving on its own: **457 → 626 → 646 ms in 17 minutes**, +30 ms within
   15 s, drops of ~120 ms. A one-off calibration can't hold that, so **Live Sync** was built.
10. **Live Sync in the real room.** It worked at once (a clear wired peak in every check) and corrected real
    drifts (−77 ms, +17.6 ms). Problems found:
    - Sony jitter was too large for a fixed agreement tolerance, so the tolerance became proportional;
    - rhythmic music could fake peaks, so a self-similarity check was added;
    - calibration and Live Sync could use different mics, so one microphone setting now drives both;
    - Live Sync looked "on" but was off after rebuilds removed the mic permission, so it now always starts
      and asks, and stable signing ends the permission resets.
11. **Smooth meters.** Canvas meters with real ballistics (fast rise, 24 dB/s fall, peak hold) at display rate,
    pausing when silent.

The detailed engineering notes are in [docs/ARCHITECTURE.md](ARCHITECTURE.md), including the
15-question adversarial review. The full test record is in [docs/VALIDATION.md](VALIDATION.md).
