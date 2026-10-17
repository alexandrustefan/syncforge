# Live Sync research

Research date: 2026-10-17. Conducted by a GPT-6 Astra subagent at xhigh, as requested by the user.
This records the design research and the bounded first implementation below. Offline checks do not
validate real-room speaker identification. No hardware capture or playback was performed for this work.

## Implemented first stage and measured cost

The first stage preserves complete **3 s, nonoverlapping recordings** and the existing GCC/rhythm
estimator. It reduces the idle interval from 6 s to 0.5 s, converts the microphone and program to a
common 16 kHz analysis rate with a centred anti-aliasing sinc filter, and moves resampling, correlation
and rhythm checking to a dedicated actor. Microphone/renderer objects remain on the main actor;
only copied sample arrays and value settings cross to the worker. This adds no playback buffering.

The nominal check cycle changes from 9.15 s to 3.65 s, plus analysis. Two fresh qualifying checks
therefore take about 7.3 s from starting the cycle instead of 18.3 s, plus analysis. A real latency
change can still require longer or remain unobservable. This is not the more aggressive rolling
1 s-window proposal, whose reliability has not been established.

Confirmation now rejects overlapping/replayed windows, expires old evidence, and resets on unclear,
rhythmic, interrupted or changed playback contexts. Results returning from the worker are discarded
after cancellation, restart or playback/profile changes. An unresolved secondary path clears the
displayed offset rather than displaying a measured zero. The prior microphone reset/atomic hardening
is unchanged. A pending rollback records the exact playback context **after** our correction and is
discarded if a later calibration, EQ, setting or output change makes it stale. Existing reflection
rollback remains a heuristic; speaker identity is not solved.

Reproduce the opt-in offline benchmark (opens no audio devices):

```sh
cd SyncForgeKit
SYNCFORGE_LIVE_SYNC_BENCHMARK=1 swift test -c release --filter LiveSyncAnalysisTests/testOfflineBenchmark
```

Measured 2026-10-17 on Apple M3 Max (14 logical processors), macOS 27.0 build 26A428, Apple Swift
6.3.1, release build. Each case uses 30 old/new iterations with alternating order after warmup.
The baseline reproduces the previous full-rate numerical path, including linear cross-rate resampling when needed.
Both paths include correlation, peak assessment and rhythm checking; fixture generation is excluded.
CPU time uses `CLOCK_PROCESS_CPUTIME_ID`, wall time uses the monotonic uptime clock.

| Synthetic case | Old CPU/check | New CPU/check | Old projected one-core use | New projected one-core use | New median / p95 wall |
|---|---:|---:|---:|---:|---:|
| Music-like, 48 kHz | 55.651 ms | 19.626 ms | 0.608% | 0.538% | 19.581 / 19.929 ms |
| Rhythmic, 48 kHz | 56.303 ms | 19.793 ms | 0.615% | 0.542% | 19.856 / 20.163 ms |
| Music-like, program 48 kHz / mic 44.1 kHz | 56.659 ms | 19.922 ms | 0.619% | 0.546% | 19.930 / 20.498 ms |

Projected use is `CPU seconds per check / nominal cycle seconds * 100`, where **100% means one
fully occupied CPU core**, not the whole machine. Using the nominal cycle excludes computation from
the denominator and is slightly conservative. These are analysis costs, not whole-app CPU readings;
the benchmark excludes capture callbacks, UI, output rendering and main-actor snapshot copying.
First-use CPU including coefficient-table construction measured 19.915–21.651 ms across these cases.
The faster cadence therefore slightly lowers analysis CPU in this corpus. It does not establish a
global optimum or guarantee the same cost on other machines or sample-rate configurations.

Resampler coefficient tables are bounded and cached. FFT workspaces are not cached in this stage:
the measured cost already meets the intended budget without changing the shared calibration FFT.
Regression tests cover positive/negative offsets at 44.1/48/96 kHz and mixed input rates, silent and
aligned cases, rhythmic rejection, fresh-window confirmation, passband phase/timing and rejection of
12 kHz energy that would otherwise alias into the 4 kHz analysis band. The synthetic offset cases
must remain within 0.5 ms; this tolerance is a test requirement, not a real-room accuracy claim.
The worker checks its own executor with `preconditionIsolated()` before entering synchronous DSP;
the async regression calls it from the main actor. This verifies actor isolation, not a particular
thread assignment. A focused rollback regression covers the unchanged post-correction context and
external calibration, EQ and output changes.

## Recommendation

Keep correlation as the first estimator, but replace the record/wait cycle with rolling analysis,
explicit confidence and multiple-candidate tracking. The substantive next improvement is retaining
per-output acoustic response templates from calibration and using them to attribute changes.
Changing the peak finder alone does not resolve speaker identity.

The original loop slept 6 s, recorded 3.15 s, then analyzed. Checks were therefore roughly 9.15 s
apart plus computation. Two confirming checks can require about 18 s from the beginning of a cycle.
Eliminating the blind wait is the clearest opportunity for faster response.

## Fundamental limit

With identical program material `x`, a microphone approximately observes:

`y = x * (wired room response + delayed wireless room response) + noise`.

It identifies the combined acoustic response. Without prior knowledge or independent excitation,
a wireless arrival and a wired reflection can yield the same observation. An adaptive filter or
Kalman tracker cannot universally recover the missing identity information. This is related to the
nonuniqueness problem in multichannel acoustic echo cancellation.

Sources: [Benesty, Morgan and Sondhi, ICASSP 1997](https://www2.spsc.tugraz.at/people/franklyn/ICASSP97/pdf/scan/ic970303.pdf),
[Valin, stereo decorrelation research](https://arxiv.org/html/1603.03364).

Consequences for SyncForge:

- A second correlation peak is a candidate path, not proof of wireless drift. PHAT peaks do not
  provide a guaranteed one-to-one inventory of physical paths.
- No secondary peak can mean alignment, masking, insufficient excitation, destructive interference,
  microphone processing or merged arrivals. It should not establish verified alignment.
- Reflections from the wireless speaker move with it. A fixed offset blacklist cannot fully classify paths.
- A genuine delay can coincide with a rhythmic subdivision. Rhythm rejection means uncertainty.
- A small delay between coherent speakers can change frequency response through comb filtering;
  a 2.5 ms detection threshold is not a universal audibility threshold.

## Candidate approaches

| Approach | Benefit | Limitation | Role |
|---|---|---|---|
| Rolling short/long-window GCC | Fresh candidates without idle waiting | Does not establish speaker identity | First implementation stage |
| Multiple-candidate tracking and change detection | Less peak switching; separate slow drift and sudden jumps | Can still track the wrong path | Implement alongside rolling analysis |
| Calibrated per-output acoustic templates | Uses speaker-specific direct and reflected path patterns | Sensitive to microphone, room and EQ changes | Best substantive follow-up |
| NLMS or frequency-domain adaptive filter | Tracks the aggregate response and model mismatch | Identical inputs do not identify two independent filters | Supporting model |
| Independent coded probes or tags | Adds information that can establish output identity | Alters playback; audibility and codec survival need qualification | Optional research/fallback |
| Core Audio/Bluetooth metadata | Cheap timing and event hints | Does not prove acoustic arrival at the listening position | Supporting evidence |

WebRTC AEC3 provides a useful implementation reference: continuous downsampled matched filters,
excitation and saturation gates, prediction-error checks, and confidence-based lag aggregation.
It primarily estimates an echo delay; its strongest-path selection cannot simply be copied to
identify SyncForge's two simultaneous outputs.

Sources: [delay estimator](https://webrtc.googlesource.com/src/+/refs/heads/main/modules/audio_processing/aec3/echo_path_delay_estimator.cc),
[matched filter](https://webrtc.googlesource.com/src/+/refs/heads/main/modules/audio_processing/aec3/matched_filter.cc),
[lag aggregation](https://webrtc.googlesource.com/src/+/refs/heads/main/modules/audio_processing/aec3/matched_filter_lag_aggregator.cc).

## Implementation stages to evaluate

1. Continuously retain timestamped microphone audio in a rolling buffer. Analyze away from the main
   actor. Benchmark a 1 s window at 250–500 ms hops, with a 3 s window for difficult passages. These
   are starting parameters, not measured detection times.
2. Use an anti-aliased 16 kHz analysis copy for the existing roughly 150–5000 Hz band. Cache FFT
   plans and scratch space. Today's 48 kHz, 3 s microphone window and 0.7 s program padding require
   a 524,288-point FFT in `envelope`. At 16 kHz the corresponding 1 s and 3 s configurations need
   65,536 and 131,072 points. These sizes follow from the code; they do not establish CPU savings
   when the analysis cadence also increases.
3. Return explicit aligned, offset-candidate and unobservable assessments. Gate decisions on useful
   excitation, SNR, clipping, subband agreement and agreement across window lengths. Compare partial
   whitening against full PHAT. Noise weighting can reuse the calibration estimator's SNR approach.
   If using coherence, estimate spectra over several frames rather than one periodogram.
4. Track several delay hypotheses plus a common microphone timing shift. Use slow tracking and an
   explicit jump/reacquisition mode. Association must precede smoothing. Overlapping windows must
   accrue enough fresh informative samples before counting as independent confirmations.
5. Verify a correction against its predicted effect on relative arrival and residual error. Do not
   treat the controller's own corrected log as ground truth.
6. Preserve a complex transfer function or impulse response for each output from the final
   calibration verification, after the intended EQ is applied. The current `responseDb` curve lacks
   phase and timing. Compare a common microphone shift model against a common shift plus wireless
   delay change, allowing constrained gain changes. A shifted speaker should move its whole path
   pattern. This proposed attribution method is an inference from the model, not validated SyncForge behavior.

Templates need enough post-sweep tail and should be invalidated or requalified after microphone
movement, significant EQ/channel changes, output changes or major room changes. Unrestricted
adaptation of both speaker templates would recreate the nonuniqueness problem.

A decision after 1–3 s of informative fresh audio is a reasonable experiment, not an accuracy or
responsiveness promise. Some material and geometries can remain unobservable indefinitely.

## Platform and microphone considerations

Sample-clock drift and Bluetooth buffering changes are separate. The renderer already resamples
between clock rates. Apple's `mRateScalar` describes a clock relationship, not acoustic latency.
Clock jumps are reasons to inspect sooner, not prerequisites for inspection.
[Apple AudioTimeStamp](https://developer.apple.com/documentation/CoreAudioTypes/AudioTimeStamp).

A constant common microphone delay cancels between simultaneous arrivals. Delay varying within a
window can smear paths, and nonlinear microphone processing can change their relative visibility.
Apple documents differing microphone modes, but that does not establish exactly which processing
a particular HAL/Continuity route applies. Qualify actual routes and modes; begin with built-in or
wired USB microphones.
[Apple microphone modes](https://support.apple.com/en-gb/guide/mac-help/mchle82b42f0/27/mac/27).

A2DP supports conditional delay reporting. No documented public macOS API was found that guarantees
accurate continuously updated remote acoustic delay. LE Audio presentation-delay concepts do not
retrofit an A2DP device. Metadata remains supporting evidence.
[BlueZ A2DP documentation](https://github.com/bluez/bluez/blob/master/doc/btmon-a2dp.rst),
[Bluetooth Basic Audio Profile](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/16212-BAP-html5/out/en/index-en.html).

Independent pseudorandom tags would add identity information. Any claim that they are inaudible
requires testing across quiet and tonal passages, volume settings, microphone routes and codecs.
Fixed EQ or an all-pass filter alone does not supply independent excitation. Ultrasound is a poor
baseline for the microphone bandwidth reported in this repository.

## Evaluation before automatic control

Build an offline replay harness that runs the current estimator and candidates on the same
timestamped source and microphone data. Include real music, speech, sparse and tonal material,
rhythmic loops, stereo phase cancellation, silence, unequal levels, different EQ, clipping, background
speech, stronger reflections and microphone bandwidth limits.

Exercise positive and negative delay steps, slow rate errors, common microphone delay changes,
capture gaps, and offsets beyond the search range. Hard negatives should include unchanged sync
with moving people, a muted output, new reflections, rhythmic peaks and changed EQ. Run sequential
episodes with control enabled to expose rollback oscillation and false corrections.

Report false corrections per hour, delay-error distributions, detection-to-correction time, time
unobservable, wrong-path assignments, recovery, CPU, memory and underruns. Split evaluation by
unseen room and track. [BUT ReverbDB](https://speech.fit.vut.cz/software/but-speech-fit-reverb-database)
offers measured room responses, noise and geometry under CC-BY 4.0; use owned or appropriately
licensed program audio.

For hardware acceptance, establish ground truth with an independent synchronous recorder and
close microphones at each speaker. Test injected software delays separately from naturally
occurring Bluetooth drift, then vary microphone route, EQ, volume, reconnection and duration.
Start in observation-only mode. Automatic control should meet an agreed false-correction budget
and improve on the existing algorithm using independent timing evidence.
