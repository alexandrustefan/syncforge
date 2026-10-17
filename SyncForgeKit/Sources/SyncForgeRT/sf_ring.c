// Source ring buffer, program timeline and the capture IOProc.
#include <stdlib.h>
#include "sf_internal.h"

struct SFSourceRing {
    float   *data;            // interleaved stereo
    uint32_t capacity;        // frames, power of two
    uint32_t mask;
    double   sampleRate;
    double   tps;             // host ticks per second

    _Atomic int64_t writeFrame;   // end (exclusive) of valid data, published with release

    SFSeqLock  tlLock;
    _Atomic uint64_t tlShared[SF_ATOMIC_WORDS(SFTimeline)];

    // Writer-private state.
    SFTimeline wtl;
    bool       hasTiming;
    double     fptSmoothed;
    _Atomic uint32_t reanchorRequested;

    _Atomic uint64_t callbacks;
    _Atomic uint64_t gaps;
    _Atomic uint64_t reanchors;
    _Atomic uint32_t peakBits;
};

static uint32_t next_pow2(uint32_t v) {
    uint32_t p = 1;
    while (p < v && p < (1u << 30)) p <<= 1;
    return p;
}

SFSourceRing *sf_ring_create(uint32_t minCapacityFrames, double sampleRate, double ticksPerSecond) {
    SFSourceRing *r = calloc(1, sizeof *r);
    if (!r) return NULL;
    r->capacity = next_pow2(minCapacityFrames < 4096 ? 4096 : minCapacityFrames);
    r->mask = r->capacity - 1;
    r->data = calloc((size_t)r->capacity * 2u, sizeof(float));
    if (!r->data) { free(r); return NULL; }
    r->sampleRate = sampleRate;
    r->tps = ticksPerSecond;
    r->wtl.sampleRate = sampleRate;
    atomic_init(&r->writeFrame, 0);
    return r;
}

void sf_ring_destroy(SFSourceRing *r) {
    if (!r) return;
    free(r->data);
    free(r);
}

uint32_t sf_ring_capacity(const SFSourceRing *r) { return r->capacity; }
double sf_ring_sample_rate(const SFSourceRing *r) { return r->sampleRate; }
int64_t sf_ring_write_frame(SFSourceRing *r) { return atomic_load_explicit(&r->writeFrame, memory_order_acquire); }

const float *sf_ring_data_internal(const SFSourceRing *r) { return r->data; }
uint32_t sf_ring_mask_internal(const SFSourceRing *r) { return r->mask; }

bool sf_ring_get_timeline(SFSourceRing *r, SFTimeline *out) {
    for (int attempt = 0; attempt < 3; attempt++) {
        if (sf_seq_try_read(&r->tlLock, out, r->tlShared, sizeof *out, NULL)) return true;
    }
    return false;
}

void sf_ring_get_stats(SFSourceRing *r, SFCaptureStats *out, bool resetPeak) {
    out->callbacks = atomic_load_explicit(&r->callbacks, memory_order_relaxed);
    out->framesWritten = (uint64_t)atomic_load_explicit(&r->writeFrame, memory_order_relaxed);
    out->gapsFilled = atomic_load_explicit(&r->gaps, memory_order_relaxed);
    out->reanchors = atomic_load_explicit(&r->reanchors, memory_order_relaxed);
    out->peak = resetPeak ? sf_exchange_f32(&r->peakBits, 0.0f) : sf_load_f32(&r->peakBits);
}

void sf_ring_request_reanchor(SFSourceRing *r) {
    atomic_store_explicit(&r->reanchorRequested, 1u, memory_order_relaxed);
}

static void write_silence(SFSourceRing *r, int64_t from, int64_t count) {
    for (int64_t i = 0; i < count; i++) {
        uint32_t idx = (uint32_t)((uint64_t)(from + i) & r->mask);
        r->data[2u * idx] = 0.0f;
        r->data[2u * idx + 1u] = 0.0f;
    }
}

void sf_ring_write(SFSourceRing *r, const float *left, const float *right, uint32_t stride,
                   uint32_t frames, uint64_t hostTime, double rateScalar) {
    atomic_fetch_add_explicit(&r->callbacks, 1, memory_order_relaxed);
    if (frames == 0) return;
    if (stride == 0) stride = 1;

    int64_t wf = atomic_load_explicit(&r->writeFrame, memory_order_relaxed);
    double rs = (rateScalar > 0.5 && rateScalar < 2.0) ? rateScalar : 1.0;
    double fptInst = r->sampleRate / (r->tps * rs);

    bool reanchor = !r->hasTiming
        || atomic_exchange_explicit(&r->reanchorRequested, 0u, memory_order_relaxed) != 0u;
    if (!reanchor) {
        // Where should this buffer start according to the current mapping?
        double expected = (double)r->wtl.anchorFrame
            + (double)(int64_t)(hostTime - r->wtl.anchorHost) * r->wtl.framesPerTick;
        double diff = expected - (double)wf;
        double tolerance = r->sampleRate * 0.002;
        if (diff > tolerance && diff < (double)(r->capacity / 4u)) {
            // Time passed without data (dropped cycles / capture restart): keep the mapping
            // continuous by inserting silence.
            int64_t gap = (int64_t)llround(diff);
            write_silence(r, wf, gap);
            wf += gap;
            atomic_fetch_add_explicit(&r->gaps, 1, memory_order_relaxed);
        } else if (fabs(diff) > tolerance) {
            reanchor = true;
            atomic_fetch_add_explicit(&r->reanchors, 1, memory_order_relaxed);
        }
    }
    if (reanchor) {
        r->wtl.epoch++;
        r->fptSmoothed = fptInst;
        r->hasTiming = true;
    } else {
        r->fptSmoothed += (fptInst - r->fptSmoothed) * 0.01;
    }

    float peak = 0.0f;
    float *d = r->data;
    for (uint32_t i = 0; i < frames; i++) {
        uint32_t idx = (uint32_t)((uint64_t)(wf + i) & r->mask);
        float l = left ? left[(size_t)i * stride] : 0.0f;
        float rr = right ? right[(size_t)i * stride] : l;
        d[2u * idx] = l;
        d[2u * idx + 1u] = rr;
        float a = fabsf(l) > fabsf(rr) ? fabsf(l) : fabsf(rr);
        if (a > peak) peak = a;
    }

    r->wtl.anchorFrame = wf;
    r->wtl.anchorHost = hostTime;
    r->wtl.framesPerTick = r->fptSmoothed;
    r->wtl.sampleRate = r->sampleRate;
    r->wtl.valid = 1;

    sf_seq_store(&r->tlLock, r->tlShared, &r->wtl, sizeof r->wtl);

    atomic_store_explicit(&r->writeFrame, wf + frames, memory_order_release);
    sf_max_f32(&r->peakBits, peak);
}

bool sf_ring_copy_mono(SFSourceRing *r, int64_t start, uint32_t count, float *out) {
    int64_t guard = 8192;
    int64_t wf = atomic_load_explicit(&r->writeFrame, memory_order_acquire);
    if (start < 0 || start + (int64_t)count > wf || start < wf - (int64_t)r->capacity + guard) return false;
    for (uint32_t i = 0; i < count; i++) {
        uint32_t idx = (uint32_t)((uint64_t)(start + i) & r->mask);
        out[i] = 0.5f * (r->data[2u * idx] + r->data[2u * idx + 1u]);
    }
    int64_t wf2 = atomic_load_explicit(&r->writeFrame, memory_order_acquire);
    return start >= wf2 - (int64_t)r->capacity + guard;
}

// MARK: - Capture IOProc

struct SFCapture {
    SFSourceRing *ring;
    uint32_t tapChannels;
    bool nonInterleaved;
};

SFCapture *sf_capture_create(SFSourceRing *ring, uint32_t tapChannels, bool nonInterleaved) {
    SFCapture *c = calloc(1, sizeof *c);
    if (!c) return NULL;
    c->ring = ring;
    c->tapChannels = tapChannels == 0 ? 2 : tapChannels;
    c->nonInterleaved = nonInterleaved;
    return c;
}

void sf_capture_destroy(SFCapture *c) { free(c); }

OSStatus sf_capture_ioproc(AudioObjectID device, const AudioTimeStamp *now,
                           const AudioBufferList *input, const AudioTimeStamp *inputTime,
                           AudioBufferList *output, const AudioTimeStamp *outputTime, void *client) {
    (void)device; (void)outputTime;
    SFCapture *c = (SFCapture *)client;
    sf_zero_output(output);
    if (!c || !input || input->mNumberBuffers == 0 || !inputTime) return noErr;

    // Taps are appended after any sub-device streams, so the tap occupies the last buffer(s).
    const float *L = NULL, *R = NULL;
    uint32_t stride = 1, frames = 0;
    UInt32 nb = input->mNumberBuffers;
    if (!c->nonInterleaved) {
        const AudioBuffer *b = &input->mBuffers[nb - 1];
        uint32_t ch = b->mNumberChannels ? b->mNumberChannels : 1;
        frames = b->mDataByteSize / (uint32_t)(sizeof(float) * ch);
        L = (const float *)b->mData;
        R = (ch > 1 && L) ? L + 1 : L;
        stride = ch;
    } else {
        uint32_t need = c->tapChannels > 1 ? 2 : 1;
        UInt32 first = nb >= need ? nb - need : 0;
        const AudioBuffer *bl = &input->mBuffers[first];
        const AudioBuffer *br = (need > 1 && first + 1 < nb) ? &input->mBuffers[first + 1] : bl;
        frames = bl->mDataByteSize / (uint32_t)sizeof(float);
        L = (const float *)bl->mData;
        R = (const float *)br->mData;
    }
    if (!L || frames == 0) return noErr;

    uint64_t host = (inputTime->mFlags & kAudioTimeStampHostTimeValid) ? inputTime->mHostTime
                    : (now ? now->mHostTime : 0);
    double rs = (inputTime->mFlags & kAudioTimeStampRateScalarValid) ? inputTime->mRateScalar : 1.0;
    sf_ring_write(c->ring, L, R, stride, frames, host, rs);
    return noErr;
}
