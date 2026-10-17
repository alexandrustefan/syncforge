// SyncForgeRT — the real-time audio kernel of SyncForge.
//
// Everything in this module may run on Core Audio IO threads. Rules:
//   * no allocation, no locks, no syscalls, no Objective-C/Swift runtime on the render path;
//   * control threads communicate through seqlock-protected snapshots (single writer) and
//     relaxed atomics for statistics; real-time readers never spin — if a snapshot is being
//     written they keep using their previous copy.
//
// Time base: Core Audio host time (mach_absolute_time ticks). All scheduling in the kernel is
// expressed on the *program timeline*: a mapping between absolute source-frame indices of the
// captured program audio and host time, maintained by the capture side.

#ifndef SYNCFORGE_RT_H
#define SYNCFORGE_RT_H

#include <stdint.h>
#include <stdbool.h>
#include <CoreAudio/CoreAudio.h>

#ifdef __cplusplus
extern "C" {
#endif

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"

#define SF_MAX_BIQUADS 64

// MARK: - Source ring buffer + program timeline

typedef struct SFSourceRing SFSourceRing;

typedef struct {
    int64_t  anchorFrame;    // absolute source frame index ...
    uint64_t anchorHost;     // ... and the host time at which it was captured
    double   framesPerTick;  // smoothed source frames per host tick
    double   sampleRate;     // nominal source sample rate
    uint32_t epoch;          // incremented whenever the mapping is re-anchored discontinuously
    uint32_t valid;
} SFTimeline;

typedef struct {
    uint64_t callbacks;
    uint64_t framesWritten;
    uint64_t gapsFilled;
    uint64_t reanchors;
    float    peak;
} SFCaptureStats;

SFSourceRing *sf_ring_create(uint32_t minCapacityFrames, double sampleRate, double ticksPerSecond);
void     sf_ring_destroy(SFSourceRing *ring);
uint32_t sf_ring_capacity(const SFSourceRing *ring);
double   sf_ring_sample_rate(const SFSourceRing *ring);
int64_t  sf_ring_write_frame(SFSourceRing *ring);
bool     sf_ring_get_timeline(SFSourceRing *ring, SFTimeline *out);
void     sf_ring_get_stats(SFSourceRing *ring, SFCaptureStats *out, bool resetPeak);
/// Single writer. Appends `frames` stereo frames whose first frame was captured at `hostTime`.
/// `left`/`right` are read with `stride` floats between frames; `right` may be NULL (mono source).
/// Gaps in host time (capture restarts, dropped cycles) are filled with silence so the
/// frame <-> host time mapping stays continuous.
void     sf_ring_write(SFSourceRing *ring, const float *left, const float *right, uint32_t stride,
                       uint32_t frames, uint64_t hostTime, double rateScalar);
/// Forces the next write to re-anchor the timeline instead of gap-filling (e.g. after a long stop).
void     sf_ring_request_reanchor(SFSourceRing *ring);
/// Non-real-time reader: copies `count` frames starting at absolute frame `start` as mono (L+R)/2.
/// Returns false if any of them is not captured yet or may have been overwritten.
bool     sf_ring_copy_mono(SFSourceRing *ring, int64_t start, uint32_t count, float *out);

// MARK: - Capture IOProc (process tap via private aggregate device)

typedef struct SFCapture SFCapture;
SFCapture *sf_capture_create(SFSourceRing *ring, uint32_t tapChannels, bool nonInterleaved);
void       sf_capture_destroy(SFCapture *capture);
OSStatus sf_capture_ioproc(AudioObjectID device, const AudioTimeStamp *_Nonnull now,
    const AudioBufferList *_Nonnull input, const AudioTimeStamp *_Nonnull inputTime,
    AudioBufferList *_Nonnull output, const AudioTimeStamp *_Nonnull outputTime, void *_Nullable client);

// MARK: - Output renderer (one per physical output device)

typedef struct { double b0, b1, b2, a1, a2; } SFBiquadCoeffs;

enum {
    SFChannelModeStereo = 0,
    SFChannelModeMono   = 1,
    SFChannelModeLeft   = 2,
    SFChannelModeRight  = 3,
    SFChannelModeSwap   = 4,
};

typedef struct {
    double   delaySeconds;          // total program delay (base latency + compensation)
    float    gain;                  // linear output gain (master * device * mute)
    float    preampGain;            // linear, applied before the filter chain
    int32_t  channelMode;
    int32_t  outLeft;               // global output channel index for L (-1: none)
    int32_t  outRight;              // global output channel index for R (-1: none)
    int32_t  dspEnabled;
    int32_t  numBiquads;
    SFBiquadCoeffs biquads[SF_MAX_BIQUADS];
    int32_t  limiterEnabled;
    float    limiterCeiling;        // linear
    float    limiterReleaseSeconds;
    int32_t  programMuted;          // 1: suppress program audio (calibration / sync test)
    float    fadeInSeconds;         // fade-in after (re)start or loss of lock
    float    crossfadeSeconds;      // crossfade when the read position jumps
    float    jumpThresholdSeconds;  // errors larger than this jump (crossfade) instead of slewing
    float    maxSlewRatio;          // max |resampling correction| (e.g. 0.002 = 0.2 %)
} SFRendererParams;

typedef struct {
    const float *samples;           // mono signal at the device sample rate (owned by caller)
    uint32_t length;
    double   sampleRate;
    uint64_t startTimelineHost;     // program-timeline time of sample 0
    uint64_t periodTicks;           // 0: one-shot, otherwise repeat every periodTicks
    uint32_t repeatCount;           // 0: infinite (only with periodTicks)
    float    gain;
    uint32_t identifier;            // echoed back via sf_renderer_test_ack once adopted
    int32_t  active;
} SFTestSignal;

typedef struct {
    uint64_t callbacks;
    uint64_t framesRendered;
    uint64_t underruns;
    uint64_t overruns;
    uint64_t resyncs;
    uint64_t clippedFrames;
    uint64_t limitedFrames;
    uint64_t lastOutputHost;
    float    peakLeft;
    float    peakRight;
    double   servoErrorSeconds;     // target - actual read position, filtered
    double   correctionPPM;         // current resampling correction relative to feed-forward
    double   ratio;                 // current source frames per output frame
    double   minHeadroomSeconds;    // smallest captured-data margin since last reset
    uint32_t testAck;
    int32_t  locked;
    uint64_t clockJumps;            // output time stamps that jumped by more than 2 ms
    double   lastClockJumpSeconds;  // size of the most recent jump (positive: time skipped)
} SFRendererStats;

typedef struct SFRenderer SFRenderer;

SFRenderer *sf_renderer_create(SFSourceRing *ring, double deviceSampleRate, uint32_t maxFrames,
                               double ticksPerSecond);
void   sf_renderer_destroy(SFRenderer *renderer);
void   sf_params_init(SFRendererParams *params);
void   sf_params_set_biquad(SFRendererParams *params, int32_t index, double b0, double b1, double b2,
                            double a1, double a2);
void   sf_renderer_set_params(SFRenderer *renderer, const SFRendererParams *params);
void   sf_renderer_set_test_signal(SFRenderer *renderer, const SFTestSignal *signal);
uint32_t sf_renderer_test_ack(SFRenderer *renderer);
void   sf_renderer_get_stats(SFRenderer *renderer, SFRendererStats *out, bool resetPeaks);
/// Renders `frames` frames into `output` (Float32 buffers, any interleaving) for an IO cycle whose
/// first frame is presented at `outputHost`. Exposed for tests; the IOProc calls this.
void   sf_renderer_render(SFRenderer *renderer, AudioBufferList *output, uint32_t frames,
                          uint64_t outputHost, double rateScalar);
OSStatus sf_renderer_ioproc(AudioObjectID device, const AudioTimeStamp *_Nonnull now,
    const AudioBufferList *_Nonnull input, const AudioTimeStamp *_Nonnull inputTime,
    AudioBufferList *_Nonnull output, const AudioTimeStamp *_Nonnull outputTime, void *_Nullable client);

// MARK: - Microphone recorder (calibration)

typedef struct { uint64_t frame; uint64_t host; double rateScalar; } SFMicAnchor;
typedef struct SFMicRecorder SFMicRecorder;

SFMicRecorder *sf_mic_create(uint32_t capacityFrames, uint32_t maxAnchors);
void     sf_mic_destroy(SFMicRecorder *mic);
void     sf_mic_set_channel(SFMicRecorder *mic, int32_t channel); // -1: average all channels
void     sf_mic_set_armed(SFMicRecorder *mic, bool armed);
/// Requests a new recording window at the next IO callback boundary. The frame/anchor getters
/// return zero until the reset is acknowledged, so an in-flight old callback cannot revive it.
/// Only call while not armed; sample/anchor snapshots must finish before requesting a reset.
void     sf_mic_reset(SFMicRecorder *mic);
uint32_t sf_mic_frames(SFMicRecorder *mic);
const float *sf_mic_data(SFMicRecorder *mic);
uint32_t sf_mic_anchor_count(SFMicRecorder *mic);
const SFMicAnchor *sf_mic_anchors(SFMicRecorder *mic);
float    sf_mic_peak(SFMicRecorder *mic, bool reset);
uint64_t sf_mic_callbacks(SFMicRecorder *mic);
OSStatus sf_mic_ioproc(AudioObjectID device, const AudioTimeStamp *_Nonnull now,
    const AudioBufferList *_Nonnull input, const AudioTimeStamp *_Nonnull inputTime,
    AudioBufferList *_Nonnull output, const AudioTimeStamp *_Nonnull outputTime, void *_Nullable client);

#pragma clang diagnostic pop

#ifdef __cplusplus
}
#endif

#endif
