# EQ preset refresh

The original bank used overlapping 10-band peaking curves with undocumented voicing. It also
boosted very deep bass on every output, including speakers that cannot reproduce it. The new bank
uses a few broad shelves and modest presence bands, with automatic headroom and the output limiter.
Tone controls cannot provide universal speaker/room correction or guarantee a preferred sound.

## Sources and design choices

- [RME ADI-2/4 Pro SE manual](https://rme-audio.de/downloads/adi24pro_e.pdf), Bass/Treble plots:
  published tone-control turnover examples at 85 Hz and 6.5 kHz. SyncForge uses these frequencies
  for Music and its bass control, with monotonic Q = 1/sqrt(2) shelves and its own modest gains.
- [CamillaDSP loudness documentation](https://github.com/HEnquist/camilladsp#loudness): low/high
  shelving contours around 70 Hz and 3.5 kHz. Low Volume uses these turnover frequencies with
  smaller fixed boosts; it does not implement CamillaDSP's volume-dependent compensation.
- [Audacity Bass and Treble manual](https://manual.audacityteam.org/man/bass_and_treble.html):
  broad shelving tone controls and the need to account for gain when changing tonal balance.
- [Sonos Night Sound](https://support.sonos.com/en-ie/article/reduce-loud-tv-audio-with-night-sound):
  true night modes can include dynamic-range processing. SyncForge's Night Mode is explicitly
  bass-reducing EQ only; it does not claim to compress dynamics.

These are independently implemented tone choices informed by documented controls. The bank does
not copy manufacturer presets or label generic speaker curves as headphone correction profiles.
The gain values below are SyncForge choices and need listening evaluation on the actual setup.

## Curves

Shelves use Q = 0.7071. Peaking filters list their Q explicitly. Gains exclude automatic headroom;
the engine attenuates the combined chain by its maximum boost before playback.

| Preset | Filters | Purpose |
|---|---|---|
| Flat | No tone filters | Neutral tone; separate calibration corrections can still be active |
| Music | Low shelf 85 Hz +2 dB; high shelf 6.5 kHz +1 dB | Mild warmth/air without a scooped midrange |
| Warm | Low shelf 150 Hz +2 dB; high shelf 4.5 kHz -1.5 dB | More body, softer highs |
| Bass Boost | Low shelf 85 Hz +4.5 dB | Smooth low-end lift, without multiple peaking humps |
| Vocal Clarity | Low shelf 180 Hz -2 dB; peak 2.2 kHz +2 dB Q 0.7 | Reduce low-end masking and add presence |
| Soft Treble | High shelf 4.5 kHz -3 dB | Reduce a bright top end |
| Low Volume | Low shelf 70 Hz +3.5 dB; high shelf 3.5 kHz +1.5 dB | Fixed contour for quiet listening |
| Night Mode | Low shelf 140 Hz -5 dB; high shelf 5 kHz -1.5 dB | Reduce bass transmission; no compression |
| Small Speakers | Butterworth high-pass 65 Hz, 12 dB/oct; peak 150 Hz +1.5 dB Q 0.8 | Remove deep rumble, retain upper-bass body |

The refreshed bank is used when selecting a preset. Loading an existing saved EQ or setup does
not silently overwrite its stored filters. Custom presets, calibration records, delays and volume
settings remain saved. Reselect Music (or another preset) to load its refreshed curve.

## Verification

`EQPresetTests` checks the complete filter response at 44.1, 48 and 96 kHz, maximum boost no greater
than 4.51 dB, automatic headroom, a monotonic bass shelf, intended response regions, safe headroom
when presets are stacked, and backwards-compatible custom preset decoding. These are electrical
DSP checks, not an acoustic or subjective listening verdict.
