// Output renderer: timestamp-locked delay line + adaptive resampler + per-device DSP.
//
// For an IO cycle presented at host time T_out, the renderer plays the program frame that was
// captured at T_out - delay. The ideal (fractional) source position is derived from the capture
// timeline; the actual read head advances by a resampling step that is
//   step = feedForward * (1 + correction)
// where feedForward is the ratio of the two clocks measured from Core Audio timestamps and the
// correction comes from a proportional servo on the position error. Errors larger than the jump
// threshold (delay changes, capture restarts) are handled by an equal-power crossfade to the new
// position instead of slewing.
#include <stdlib.h>
#include "sf_internal.h"

#define SF_SINC_HALF   32
#define SF_SINC_PHASES 512
// Proportional servo. The feed-forward ratio (from Core Audio rate scalars) carries the clock
// ratio, so the loop only removes residual position error. Steady-state error = ratio bias / KP,
// i.e. 50 us even if a driver reported no rate scalar at all and the clocks differed by 100 ppm.
#define SF_SERVO_KP    2.0      // 1/s   (error time constant ~0.5 s)
#define SF_SERVO_ERR_TC 0.05    // s, low-pass on the measured position error

struct SFRenderer {
    SFSourceRing *ring;
    double   devRate;
    double   srcRate;
    double   tps;
    uint32_t maxFrames;
    SFSinc  *sinc;

    // Control -> RT.
    SFSeqLock        pLock;
    _Atomic uint64_t pShared[SF_ATOMIC_WORDS(SFRendererParams)];
    SFSeqLock        tLock;
    _Atomic uint64_t tShared[SF_ATOMIC_WORDS(SFTestSignal)];

    // RT-private state.
    SFRendererParams p;
    uint32_t pSeq;
    bool     hasParams;
    SFTestSignal t;
    uint32_t tSeq;
    SFTimeline tl;
    bool     hasTimeline;

    bool     locked;
    bool     lastHadProgram;  // previous cycle produced program audio (old head is readable)
    double   pos;
    double   oldPos;
    uint32_t xfRemain;
    uint32_t xfLen;
    double   step;
    double   errFiltered;
    double   devFPT;          // smoothed device frames per host tick

    float    progGain;
    float    outGain;
    float    fadeGain;
    float    fadeStep;
    float    limGain;

    int32_t  nbq;
    double   bq[SF_MAX_BIQUADS][2][2];
    double   bqT[SF_MAX_BIQUADS][2];

    float   *bufL;
    float   *bufR;
    float   *bufT;

    // RT -> control statistics.
    _Atomic uint64_t callbacks, frames, underruns, overruns, resyncs, clipped, limited, lastHost;
    _Atomic uint32_t peakL, peakR;
    _Atomic uint64_t errBits, ppmBits, ratioBits, headroomBits;
    _Atomic uint32_t testAck;
    _Atomic int32_t  lockedFlag;
    _Atomic uint64_t clockJumps;
    _Atomic uint64_t lastJumpBits;
    uint64_t prevHost;
    uint32_t prevFrames;
};

void sf_params_init(SFRendererParams *p) {
    memset(p, 0, sizeof *p);
    p->delaySeconds = 0.05;
    p->gain = 1.0f;
    p->preampGain = 1.0f;
    p->channelMode = SFChannelModeStereo;
    p->outLeft = 0;
    p->outRight = 1;
    p->dspEnabled = 0;
    p->limiterEnabled = 1;
    p->limiterCeiling = 0.97f;
    p->limiterReleaseSeconds = 0.15f;
    p->fadeInSeconds = 0.3f;
    p->crossfadeSeconds = 0.03f;
    p->jumpThresholdSeconds = 0.002f;
    p->maxSlewRatio = 0.002f;
}

void sf_params_set_biquad(SFRendererParams *p, int32_t index, double b0, double b1, double b2,
                          double a1, double a2) {
    if (index < 0 || index >= SF_MAX_BIQUADS) return;
    p->biquads[index] = (SFBiquadCoeffs){ b0, b1, b2, a1, a2 };
}

SFRenderer *sf_renderer_create(SFSourceRing *ring, double deviceSampleRate, uint32_t maxFrames,
                               double ticksPerSecond) {
    if (!ring || deviceSampleRate <= 0 || maxFrames == 0) return NULL;
    SFRenderer *r = calloc(1, sizeof *r);
    if (!r) return NULL;
    r->ring = ring;
    r->devRate = deviceSampleRate;
    r->srcRate = sf_ring_sample_rate(ring);
    r->tps = ticksPerSecond;
    r->maxFrames = maxFrames;
    // Cut-off below the lower of the two Nyquist frequencies, leaving room for the transition band.
    double ratio = deviceSampleRate / r->srcRate;
    double cutoff = 0.92 * (ratio < 1.0 ? ratio : 1.0);
    r->sinc = sf_sinc_create(SF_SINC_HALF, SF_SINC_PHASES, cutoff, 8.0);
    r->bufL = calloc(maxFrames, sizeof(float));
    r->bufR = calloc(maxFrames, sizeof(float));
    r->bufT = calloc(maxFrames, sizeof(float));
    if (!r->sinc || !r->bufL || !r->bufR || !r->bufT) { sf_renderer_destroy(r); return NULL; }
    SFRendererParams defaults;
    sf_params_init(&defaults);
    sf_seq_store(&r->pLock, r->pShared, &defaults, sizeof defaults);
    r->limGain = 1.0f;
    sf_store_f64(&r->headroomBits, INFINITY);
    return r;
}

void sf_renderer_destroy(SFRenderer *r) {
    if (!r) return;
    sf_sinc_destroy(r->sinc);
    free(r->bufL);
    free(r->bufR);
    free(r->bufT);
    free(r);
}

void sf_renderer_set_params(SFRenderer *r, const SFRendererParams *params) {
    sf_seq_store(&r->pLock, r->pShared, params, sizeof *params);
}

void sf_renderer_set_test_signal(SFRenderer *r, const SFTestSignal *signal) {
    sf_seq_store(&r->tLock, r->tShared, signal, sizeof *signal);
}

uint32_t sf_renderer_test_ack(SFRenderer *r) {
    return atomic_load_explicit(&r->testAck, memory_order_acquire);
}

void sf_renderer_get_stats(SFRenderer *r, SFRendererStats *o, bool reset) {
    o->callbacks = atomic_load_explicit(&r->callbacks, memory_order_relaxed);
    o->framesRendered = atomic_load_explicit(&r->frames, memory_order_relaxed);
    o->underruns = atomic_load_explicit(&r->underruns, memory_order_relaxed);
    o->overruns = atomic_load_explicit(&r->overruns, memory_order_relaxed);
    o->resyncs = atomic_load_explicit(&r->resyncs, memory_order_relaxed);
    o->clippedFrames = atomic_load_explicit(&r->clipped, memory_order_relaxed);
    o->limitedFrames = atomic_load_explicit(&r->limited, memory_order_relaxed);
    o->lastOutputHost = atomic_load_explicit(&r->lastHost, memory_order_relaxed);
    o->servoErrorSeconds = sf_load_f64(&r->errBits);
    o->correctionPPM = sf_load_f64(&r->ppmBits);
    o->ratio = sf_load_f64(&r->ratioBits);
    o->testAck = atomic_load_explicit(&r->testAck, memory_order_relaxed);
    o->locked = atomic_load_explicit(&r->lockedFlag, memory_order_relaxed);
    o->clockJumps = atomic_load_explicit(&r->clockJumps, memory_order_relaxed);
    o->lastClockJumpSeconds = sf_load_f64(&r->lastJumpBits);
    if (reset) {
        o->peakLeft = sf_exchange_f32(&r->peakL, 0.0f);
        o->peakRight = sf_exchange_f32(&r->peakR, 0.0f);
        o->minHeadroomSeconds = sf_exchange_f64(&r->headroomBits, INFINITY);
    } else {
        o->peakLeft = sf_load_f32(&r->peakL);
        o->peakRight = sf_load_f32(&r->peakR);
        o->minHeadroomSeconds = sf_load_f64(&r->headroomBits);
    }
}

static inline void biquad_block(const SFBiquadCoeffs *c, double *s, float *x, uint32_t n) {
    double b0 = c->b0, b1 = c->b1, b2 = c->b2, a1 = c->a1, a2 = c->a2;
    double s1 = s[0], s2 = s[1];
    for (uint32_t j = 0; j < n; j++) {
        double in = (double)x[j];
        double y = b0 * in + s1;
        s1 = b1 * in - a1 * y + s2;
        s2 = b2 * in - a2 * y;
        x[j] = (float)y;
    }
    // Flush denormals.
    if (fabs(s1) < 1e-30) s1 = 0.0;
    if (fabs(s2) < 1e-30) s2 = 0.0;
    s[0] = s1;
    s[1] = s2;
}

static void write_output(AudioBufferList *out, const float *L, const float *R, uint32_t n,
                         int32_t outLeft, int32_t outRight) {
    int32_t base = 0;
    for (UInt32 b = 0; b < out->mNumberBuffers; b++) {
        AudioBuffer *buf = &out->mBuffers[b];
        int32_t nch = (int32_t)(buf->mNumberChannels ? buf->mNumberChannels : 1);
        float *d = (float *)buf->mData;
        if (d) {
            uint32_t avail = buf->mDataByteSize / (uint32_t)(sizeof(float) * (uint32_t)nch);
            uint32_t m = avail < n ? avail : n;
            for (int32_t c = 0; c < nch; c++) {
                int32_t g = base + c;
                const float *src = (g == outLeft) ? L : (g == outRight) ? R : NULL;
                if (src) {
                    for (uint32_t j = 0; j < m; j++) d[(size_t)j * (size_t)nch + (size_t)c] = src[j];
                } else {
                    for (uint32_t j = 0; j < m; j++) d[(size_t)j * (size_t)nch + (size_t)c] = 0.0f;
                }
            }
        }
        base += nch;
    }
}

static void poll_control(SFRenderer *r) {
    uint32_t s = sf_seq_current(&r->pLock);
    if (s != r->pSeq || !r->hasParams) {
        SFRendererParams tmp;
        uint32_t seq;
        if (sf_seq_try_read(&r->pLock, &tmp, r->pShared, sizeof tmp, &seq)) {
            int32_t nb = tmp.numBiquads < 0 ? 0 : (tmp.numBiquads > SF_MAX_BIQUADS ? SF_MAX_BIQUADS : tmp.numBiquads);
            tmp.numBiquads = nb;
            if (nb != r->nbq) {
                memset(r->bq, 0, sizeof r->bq);
                memset(r->bqT, 0, sizeof r->bqT);
                r->nbq = nb;
            }
            r->p = tmp;
            r->pSeq = seq;
            if (!r->hasParams) r->outGain = tmp.gain;
            r->hasParams = true;
        }
    }
    s = sf_seq_current(&r->tLock);
    if (s != r->tSeq) {
        SFTestSignal tmp;
        uint32_t seq;
        if (sf_seq_try_read(&r->tLock, &tmp, r->tShared, sizeof tmp, &seq)) {
            r->t = tmp;
            r->tSeq = seq;
            memset(r->bqT, 0, sizeof r->bqT);
            atomic_store_explicit(&r->testAck, tmp.identifier, memory_order_release);
        }
    }
    SFTimeline tl;
    if (sf_ring_get_timeline(r->ring, &tl)) {
        r->tl = tl;
        r->hasTimeline = tl.valid != 0;
    }
}

static void lose_lock(SFRenderer *r) {
    r->locked = false;
    r->lastHadProgram = false;
    r->xfRemain = 0;
    atomic_store_explicit(&r->lockedFlag, 0, memory_order_relaxed);
}

void sf_renderer_render(SFRenderer *r, AudioBufferList *out, uint32_t n, uint64_t outputHost,
                        double rateScalar) {
    atomic_fetch_add_explicit(&r->callbacks, 1, memory_order_relaxed);
    atomic_store_explicit(&r->lastHost, outputHost, memory_order_relaxed);
    poll_control(r);

    if (!out || n == 0) return;
    if (!r->hasParams || n > r->maxFrames) { sf_zero_output(out); return; }

    const SFRendererParams *p = &r->p;
    double tps = r->tps;
    double rs = (rateScalar > 0.5 && rateScalar < 2.0) ? rateScalar : 1.0;
    double fptInst = r->devRate / (tps * rs);
    r->devFPT = r->devFPT == 0.0 ? fptInst : r->devFPT + (fptInst - r->devFPT) * 0.02;
    double delayTicks = p->delaySeconds * tps;

    // Diagnostics: did the device's time line jump (dropped or repeated IO cycles)?
    if (r->prevHost != 0 && r->prevFrames > 0) {
        double expected = (double)r->prevHost + (double)r->prevFrames / r->devFPT;
        double jump = ((double)outputHost - expected) / tps;
        if (fabs(jump) > 0.002) {
            atomic_fetch_add_explicit(&r->clockJumps, 1, memory_order_relaxed);
            sf_store_f64(&r->lastJumpBits, jump);
        }
    }
    r->prevHost = outputHost;
    r->prevFrames = n;

    float *L = r->bufL, *R = r->bufR, *T = r->bufT;
    bool haveProgram = false;

    if (r->hasTimeline) {
        const SFTimeline *tl = &r->tl;
        double srcRate = tl->sampleRate > 0 ? tl->sampleRate : r->srcRate;
        double ff = tl->framesPerTick / r->devFPT;
        double rel = (double)(int64_t)(outputHost - tl->anchorHost) - delayTicks;
        double target = (double)tl->anchorFrame + rel * tl->framesPerTick;

        if (!r->locked) {
            r->pos = target;
            r->step = ff;
            r->errFiltered = 0.0;
            r->locked = true;
            r->fadeGain = 0.0f;
            float fade = p->fadeInSeconds > 0.001f ? p->fadeInSeconds : 0.001f;
            r->fadeStep = (float)(1.0 / (fade * r->devRate));
            atomic_store_explicit(&r->lockedFlag, 1, memory_order_relaxed);
        } else {
            double err = target - r->pos;
            double errSec = err / srcRate;
            if (fabs(errSec) > (double)p->jumpThresholdSeconds) {
                // Large jump (delay change / capture discontinuity): crossfade to the new position,
                // but only from a position that is actually playing. Otherwise just fade in.
                r->oldPos = r->pos;
                r->pos = target;
                uint32_t len = (uint32_t)(p->crossfadeSeconds * r->devRate);
                r->xfLen = len < 16 ? 16 : len;
                r->xfRemain = r->lastHadProgram ? r->xfLen : 0;
                    r->errFiltered = 0.0;
                r->step = ff;
                atomic_fetch_add_explicit(&r->resyncs, 1, memory_order_relaxed);
            } else {
                double dt = (double)n / r->devRate;
                double maxSlew = p->maxSlewRatio > 0 ? (double)p->maxSlewRatio : 0.002;
                // Light filtering of the position error (timestamp jitter must not become pitch jitter).
                double a = dt / (dt + SF_SERVO_ERR_TC);
                r->errFiltered += (errSec - r->errFiltered) * a;
                double corr = SF_SERVO_KP * r->errFiltered;
                if (corr > maxSlew) corr = maxSlew;
                if (corr < -maxSlew) corr = -maxSlew;
                r->step = ff * (1.0 + corr);
                sf_store_f64(&r->ppmBits, corr * 1e6);
            }
            sf_store_f64(&r->errBits, errSec);
        }
        sf_store_f64(&r->ratioBits, r->step);

        // Check that every frame the interpolator needs has been captured and not yet overwritten.
        int64_t wf = sf_ring_write_frame(r->ring);
        double span = (double)n * r->step;
        int64_t cap = (int64_t)sf_ring_capacity(r->ring);
        int64_t guard = (int64_t)(2 * r->maxFrames) + 256;
        if (r->xfRemain > 0) {
            // Drop the old head if it is no longer readable; the new head fades in instead.
            int64_t oFrom = (int64_t)floor(r->oldPos) - (SF_SINC_HALF - 1);
            int64_t oTo = (int64_t)floor(r->oldPos + span) + SF_SINC_HALF + 1;
            if (oTo > wf || oFrom < wf - cap + guard) {
                r->xfRemain = 0;
                r->fadeGain = 0.0f;
                r->fadeStep = (float)(1.0 / (0.01 * r->devRate));
            }
        }
        double lo = r->pos, hi = r->pos + span;
        if (r->xfRemain > 0) {
            if (r->oldPos < lo) lo = r->oldPos;
            if (r->oldPos + span > hi) hi = r->oldPos + span;
        }
        int64_t needFrom = (int64_t)floor(lo) - (SF_SINC_HALF - 1);
        int64_t needTo = (int64_t)floor(hi) + SF_SINC_HALF + 1;
        double headroom = (double)(wf - needTo) / srcRate;
        if (headroom < sf_load_f64(&r->headroomBits)) sf_store_f64(&r->headroomBits, headroom);

        if (needTo > wf) {
            atomic_fetch_add_explicit(&r->underruns, 1, memory_order_relaxed);
        } else if (needFrom < wf - cap + guard) {
            atomic_fetch_add_explicit(&r->overruns, 1, memory_order_relaxed);
        } else {
            haveProgram = true;
            const float *data = sf_ring_data_internal(r->ring);
            uint32_t mask = sf_ring_mask_internal(r->ring);
            double ps = r->pos, step = r->step;
            for (uint32_t j = 0; j < n; j++) {
                sf_sinc_read(r->sinc, data, mask, ps, &L[j], &R[j]);
                ps += step;
            }
            if (r->xfRemain > 0) {
                double po = r->oldPos;
                for (uint32_t j = 0; j < n; j++) {
                    float ol, orr;
                    sf_sinc_read(r->sinc, data, mask, po, &ol, &orr);
                    po += step;
                    if (r->xfRemain > 0) {
                        float x = (float)(r->xfLen - r->xfRemain) / (float)r->xfLen; // 0 -> 1
                        float gNew = sinf(x * (float)M_PI_2);
                        float gOld = cosf(x * (float)M_PI_2);
                        L[j] = L[j] * gNew + ol * gOld;
                        R[j] = R[j] * gNew + orr * gOld;
                        r->xfRemain--;
                    }
                }
                r->oldPos = po;
            }
            // Re-validate: if the writer lapped us while reading, the data may be torn.
            int64_t wf2 = sf_ring_write_frame(r->ring);
            if (needFrom < wf2 - cap + 256) {
                haveProgram = false;
                atomic_fetch_add_explicit(&r->overruns, 1, memory_order_relaxed);
            }
        }
        r->pos += span;
        r->lastHadProgram = haveProgram;
        if (!haveProgram) {
            if (r->xfRemain > 0) { r->oldPos += span; }
            // Restart with a short fade once data is available again.
            r->fadeGain = 0.0f;
            r->fadeStep = (float)(1.0 / (0.01 * r->devRate));
        }
    } else {
        lose_lock(r);
    }

    if (!haveProgram) {
        memset(L, 0, n * sizeof(float));
        memset(R, 0, n * sizeof(float));
    } else {
        switch (p->channelMode) {
            case SFChannelModeMono:
                for (uint32_t j = 0; j < n; j++) { float m = 0.5f * (L[j] + R[j]); L[j] = m; R[j] = m; }
                break;
            case SFChannelModeLeft:
                memcpy(R, L, n * sizeof(float));
                break;
            case SFChannelModeRight:
                memcpy(L, R, n * sizeof(float));
                break;
            case SFChannelModeSwap:
                for (uint32_t j = 0; j < n; j++) { float x = L[j]; L[j] = R[j]; R[j] = x; }
                break;
            default:
                break;
        }
    }

    // Program path: preamp -> filter chain.
    if (haveProgram && p->dspEnabled) {
        float pre = p->preampGain;
        if (pre != 1.0f) {
            for (uint32_t j = 0; j < n; j++) { L[j] *= pre; R[j] *= pre; }
        }
        for (int32_t k = 0; k < r->nbq; k++) {
            biquad_block(&p->biquads[k], r->bq[k][0], L, n);
            biquad_block(&p->biquads[k], r->bq[k][1], R, n);
        }
    }

    // Gain stage (smoothed), program mute, fade-in.
    float gCoef = (float)(1.0 - exp(-1.0 / (0.02 * r->devRate)));
    float gTarget = p->gain;
    float pTarget = p->programMuted ? 0.0f : 1.0f;
    for (uint32_t j = 0; j < n; j++) {
        r->outGain += (gTarget - r->outGain) * gCoef;
        r->progGain += (pTarget - r->progGain) * gCoef;
        if (r->fadeGain < 1.0f) {
            r->fadeGain += r->fadeStep;
            if (r->fadeGain > 1.0f) r->fadeGain = 1.0f;
        }
        float g = r->outGain * r->progGain * r->fadeGain;
        L[j] *= g;
        R[j] *= g;
    }

    // Test signal (calibration / sync clicks): same timeline mapping and same filter chain as the
    // program, independent of the volume setting.
    if (r->t.active && r->t.samples && r->t.length > 0) {
        const SFTestSignal *t = &r->t;
        double ticksPerFrame = 1.0 / r->devFPT;
        double samplesPerTick = t->sampleRate / tps;
        // Position in signal samples (+0.5: round to the nearest sample) of this cycle's first frame.
        double x0 = ((double)(int64_t)(outputHost - t->startTimelineHost) - delayTicks) * samplesPerTick + 0.5;
        double dx = ticksPerFrame * samplesPerTick;
        double periodSamples = (double)t->periodTicks * samplesPerTick;
        bool any = false;
        for (uint32_t j = 0; j < n; j++) {
            double x = x0 + (double)j * dx;
            float v = 0.0f;
            if (x >= 0.0) {
                if (periodSamples > 0.0) {
                    double k = floor(x / periodSamples);
                    if (t->repeatCount == 0 || k < (double)t->repeatCount) x -= k * periodSamples;
                    else x = -1.0;
                }
                if (x >= 0.0) {
                    int64_t idx = (int64_t)x;
                    if (idx < (int64_t)t->length) { v = t->samples[idx] * t->gain; any = true; }
                }
            }
            T[j] = v;
        }
        if (any || r->nbq > 0) {
            if (p->dspEnabled) {
                for (int32_t k = 0; k < r->nbq; k++) {
                    double st[2] = { r->bqT[k][0], r->bqT[k][1] };
                    biquad_block(&p->biquads[k], st, T, n);
                    r->bqT[k][0] = st[0];
                    r->bqT[k][1] = st[1];
                }
            }
            for (uint32_t j = 0; j < n; j++) { L[j] += T[j]; R[j] += T[j]; }
        }
    }

    // Limiter (linked stereo, instant attack) + hard safety clip + meters.
    float pkL = 0.0f, pkR = 0.0f;
    uint64_t clippedCount = 0, limitedCount = 0;
    float ceil = p->limiterCeiling > 0.05f ? p->limiterCeiling : 0.97f;
    float rel = (float)exp(-1.0 / ((p->limiterReleaseSeconds > 0.001f ? p->limiterReleaseSeconds : 0.15f) * r->devRate));
    for (uint32_t j = 0; j < n; j++) {
        float l = L[j], rr = R[j];
        if (p->limiterEnabled) {
            float pk = fabsf(l) > fabsf(rr) ? fabsf(l) : fabsf(rr);
            if (pk * r->limGain > ceil) r->limGain = ceil / pk;
            else r->limGain = 1.0f - (1.0f - r->limGain) * rel;
            if (r->limGain < 0.999f) limitedCount++;
            l *= r->limGain;
            rr *= r->limGain;
        }
        if (l > 1.0f || l < -1.0f || rr > 1.0f || rr < -1.0f) {
            clippedCount++;
            l = l > 1.0f ? 1.0f : (l < -1.0f ? -1.0f : l);
            rr = rr > 1.0f ? 1.0f : (rr < -1.0f ? -1.0f : rr);
        }
        L[j] = l;
        R[j] = rr;
        if (fabsf(l) > pkL) pkL = fabsf(l);
        if (fabsf(rr) > pkR) pkR = fabsf(rr);
    }
    if (clippedCount) atomic_fetch_add_explicit(&r->clipped, clippedCount, memory_order_relaxed);
    if (limitedCount) atomic_fetch_add_explicit(&r->limited, limitedCount, memory_order_relaxed);
    sf_max_f32(&r->peakL, pkL);
    sf_max_f32(&r->peakR, pkR);
    atomic_fetch_add_explicit(&r->frames, n, memory_order_relaxed);

    write_output(out, L, R, n, p->outLeft, p->outRight);
}

OSStatus sf_renderer_ioproc(AudioObjectID device, const AudioTimeStamp *now,
                            const AudioBufferList *input, const AudioTimeStamp *inputTime,
                            AudioBufferList *output, const AudioTimeStamp *outputTime, void *client) {
    (void)device; (void)input; (void)inputTime;
    SFRenderer *r = (SFRenderer *)client;
    if (!r || !output || output->mNumberBuffers == 0) return noErr;
    const AudioBuffer *b0 = &output->mBuffers[0];
    uint32_t ch = b0->mNumberChannels ? b0->mNumberChannels : 1;
    uint32_t frames = b0->mDataByteSize / (uint32_t)(sizeof(float) * ch);
    uint64_t host;
    double rs = 1.0;
    if (outputTime && (outputTime->mFlags & kAudioTimeStampHostTimeValid)) {
        host = outputTime->mHostTime;
        if (outputTime->mFlags & kAudioTimeStampRateScalarValid) rs = outputTime->mRateScalar;
    } else {
        host = now ? now->mHostTime : 0;
    }
    sf_renderer_render(r, output, frames, host, rs);
    return noErr;
}
