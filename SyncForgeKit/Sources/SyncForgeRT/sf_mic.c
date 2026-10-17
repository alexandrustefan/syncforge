// Microphone recorder: copies one (or the average of all) input channel(s) into a preallocated
// linear buffer together with Core Audio timestamps, for offline latency analysis.
#include <stdlib.h>
#include "sf_internal.h"

struct SFMicRecorder {
    float       *data;
    uint32_t     capacity;
    SFMicAnchor *anchors;
    uint32_t     anchorCap;
    _Atomic uint32_t frames;
    _Atomic uint32_t anchorCount;
    _Atomic int32_t  armed;
    _Atomic int32_t  channel;
    _Atomic uint32_t peakBits;
    _Atomic uint64_t callbacks;
    _Atomic uint32_t resetRequested;
    _Atomic uint32_t resetAck;
    uint32_t appliedReset;  // IO-thread only
};

SFMicRecorder *sf_mic_create(uint32_t capacityFrames, uint32_t maxAnchors) {
    SFMicRecorder *m = calloc(1, sizeof *m);
    if (!m) return NULL;
    m->data = calloc(capacityFrames, sizeof(float));
    m->anchors = calloc(maxAnchors, sizeof(SFMicAnchor));
    if (!m->data || !m->anchors) { sf_mic_destroy(m); return NULL; }
    m->capacity = capacityFrames;
    m->anchorCap = maxAnchors;
    atomic_init(&m->channel, -1);
    return m;
}

void sf_mic_destroy(SFMicRecorder *m) {
    if (!m) return;
    free(m->data);
    free(m->anchors);
    free(m);
}

void sf_mic_set_channel(SFMicRecorder *m, int32_t channel) { atomic_store(&m->channel, channel); }
void sf_mic_set_armed(SFMicRecorder *m, bool armed) { atomic_store(&m->armed, armed ? 1 : 0); }
void sf_mic_reset(SFMicRecorder *m) {
    // The control thread never resets counters while an old callback can still publish them.
    // Hide the old window immediately; the IO thread resets it at its next callback boundary.
    atomic_fetch_add_explicit(&m->resetRequested, 1, memory_order_release);
}
uint32_t sf_mic_frames(SFMicRecorder *m) {
    uint32_t requested = atomic_load_explicit(&m->resetRequested, memory_order_acquire);
    if (atomic_load_explicit(&m->resetAck, memory_order_acquire) != requested) return 0;
    uint32_t count = atomic_load_explicit(&m->frames, memory_order_acquire);
    return atomic_load_explicit(&m->resetRequested, memory_order_acquire) == requested ? count : 0;
}
const float *sf_mic_data(SFMicRecorder *m) { return m->data; }
uint32_t sf_mic_anchor_count(SFMicRecorder *m) {
    uint32_t requested = atomic_load_explicit(&m->resetRequested, memory_order_acquire);
    if (atomic_load_explicit(&m->resetAck, memory_order_acquire) != requested) return 0;
    uint32_t count = atomic_load_explicit(&m->anchorCount, memory_order_acquire);
    return atomic_load_explicit(&m->resetRequested, memory_order_acquire) == requested ? count : 0;
}
const SFMicAnchor *sf_mic_anchors(SFMicRecorder *m) { return m->anchors; }
float sf_mic_peak(SFMicRecorder *m, bool reset) { return reset ? sf_exchange_f32(&m->peakBits, 0.0f) : sf_load_f32(&m->peakBits); }
uint64_t sf_mic_callbacks(SFMicRecorder *m) { return atomic_load_explicit(&m->callbacks, memory_order_acquire); }

OSStatus sf_mic_ioproc(AudioObjectID device, const AudioTimeStamp *now,
                       const AudioBufferList *input, const AudioTimeStamp *inputTime,
                       AudioBufferList *output, const AudioTimeStamp *outputTime, void *client) {
    (void)device; (void)outputTime;
    SFMicRecorder *m = (SFMicRecorder *)client;
    sf_zero_output(output);
    if (!m || !input || input->mNumberBuffers == 0 || !inputTime) return noErr;
    uint32_t requested = atomic_load_explicit(&m->resetRequested, memory_order_acquire);
    if (requested != m->appliedReset) {
        atomic_store_explicit(&m->frames, 0, memory_order_relaxed);
        atomic_store_explicit(&m->anchorCount, 0, memory_order_relaxed);
        m->appliedReset = requested;
        atomic_store_explicit(&m->resetAck, requested, memory_order_release);
    }
    const AudioBuffer *b0 = &input->mBuffers[0];
    uint32_t ch0 = b0->mNumberChannels ? b0->mNumberChannels : 1;
    uint32_t n = b0->mDataByteSize / (uint32_t)(sizeof(float) * ch0);
    if (n == 0) return noErr;

    int32_t want = atomic_load_explicit(&m->channel, memory_order_relaxed);
    int32_t armed = atomic_load_explicit(&m->armed, memory_order_relaxed);
    uint32_t written = atomic_load_explicit(&m->frames, memory_order_relaxed);
    bool record = armed && written + n <= m->capacity;
    float *dst = record ? m->data + written : NULL;
    // A counted callback has latched its generation and recording destination. It may still be
    // writing samples; frame/anchor publication below is the completion boundary for readers.
    atomic_fetch_add_explicit(&m->callbacks, 1, memory_order_release);
    float peak = 0.0f;

    // Count total channels to compute an average if requested.
    uint32_t total = 0;
    for (UInt32 b = 0; b < input->mNumberBuffers; b++) total += input->mBuffers[b].mNumberChannels ? input->mBuffers[b].mNumberChannels : 1;
    if (want >= (int32_t)total) want = -1;

    for (uint32_t j = 0; j < n; j++) {
        float acc = 0.0f;
        int32_t base = 0;
        for (UInt32 b = 0; b < input->mNumberBuffers; b++) {
            const AudioBuffer *buf = &input->mBuffers[b];
            int32_t nch = (int32_t)(buf->mNumberChannels ? buf->mNumberChannels : 1);
            const float *s = (const float *)buf->mData;
            uint32_t avail = buf->mDataByteSize / (uint32_t)(sizeof(float) * (uint32_t)nch);
            if (s && j < avail) {
                if (want < 0) {
                    for (int32_t c = 0; c < nch; c++) acc += s[(size_t)j * (size_t)nch + (size_t)c];
                } else if (want >= base && want < base + nch) {
                    acc = s[(size_t)j * (size_t)nch + (size_t)(want - base)];
                }
            }
            base += nch;
        }
        if (want < 0 && total > 0) acc /= (float)total;
        float a = fabsf(acc);
        if (a > peak) peak = a;
        if (dst) dst[j] = acc;
    }
    sf_max_f32(&m->peakBits, peak);

    if (record) {
        uint32_t ac = atomic_load_explicit(&m->anchorCount, memory_order_relaxed);
        if (ac < m->anchorCap) {
            uint64_t host = (inputTime->mFlags & kAudioTimeStampHostTimeValid) ? inputTime->mHostTime : (now ? now->mHostTime : 0);
            double rs = (inputTime->mFlags & kAudioTimeStampRateScalarValid) ? inputTime->mRateScalar : 1.0;
            m->anchors[ac] = (SFMicAnchor){ written, host, rs };
            atomic_store_explicit(&m->anchorCount, ac + 1, memory_order_release);
        }
        atomic_store_explicit(&m->frames, written + n, memory_order_release);
    }
    return noErr;
}
