// Internal helpers shared by the SyncForgeRT translation units.
#ifndef SF_INTERNAL_H
#define SF_INTERNAL_H

#include <stdatomic.h>
#include <string.h>
#include <math.h>
#include "SyncForgeRT.h"

// MARK: - Seqlock (single writer, wait-free readers that may fail)

typedef struct { _Atomic uint32_t seq; } SFSeqLock;

// Only the sequence number being atomic is insufficient: rejected speculative copies still
// race with the writer under C11. Store every shared payload as lock-free atomic words. memcpy
// below only touches thread-local values, including the final partial word and struct padding.
#define SF_ATOMIC_WORDS(type) ((sizeof(type) + sizeof(uint64_t) - 1) / sizeof(uint64_t))
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2 && ATOMIC_LONG_LOCK_FREE == 2,
               "SyncForge requires lock-free 64-bit atomics on its audio threads");

static inline void sf_seq_write_begin(SFSeqLock *l) {
    uint32_t s = atomic_load_explicit(&l->seq, memory_order_relaxed);
    atomic_store_explicit(&l->seq, s + 1, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
}

static inline void sf_seq_write_end(SFSeqLock *l) {
    uint32_t s = atomic_load_explicit(&l->seq, memory_order_relaxed);
    atomic_store_explicit(&l->seq, s + 1, memory_order_release);
}

static inline uint32_t sf_seq_current(SFSeqLock *l) {
    return atomic_load_explicit(&l->seq, memory_order_acquire);
}

static inline void sf_seq_store(SFSeqLock *l, _Atomic uint64_t *dst, const void *src, size_t size) {
    sf_seq_write_begin(l);
    const unsigned char *bytes = src;
    for (size_t offset = 0; offset < size; offset += sizeof(uint64_t)) {
        size_t count = size - offset < sizeof(uint64_t) ? size - offset : sizeof(uint64_t);
        uint64_t word = 0;
        memcpy(&word, bytes + offset, count);
        atomic_store_explicit(&dst[offset / sizeof(uint64_t)], word, memory_order_relaxed);
    }
    sf_seq_write_end(l);
}

/// Copies `size` bytes from `src` if no write is in progress. Never spins.
/// Returns true and stores the sequence number in `outSeq` on success.
static inline bool sf_seq_try_read(SFSeqLock *l, void *dst, const _Atomic uint64_t *src, size_t size, uint32_t *outSeq) {
    uint32_t s1 = atomic_load_explicit(&l->seq, memory_order_acquire);
    if (s1 & 1u) return false;
    unsigned char *bytes = dst;
    for (size_t offset = 0; offset < size; offset += sizeof(uint64_t)) {
        size_t count = size - offset < sizeof(uint64_t) ? size - offset : sizeof(uint64_t);
        uint64_t word = atomic_load_explicit(&src[offset / sizeof(uint64_t)], memory_order_relaxed);
        memcpy(bytes + offset, &word, count);
    }
    atomic_thread_fence(memory_order_acquire);
    uint32_t s2 = atomic_load_explicit(&l->seq, memory_order_relaxed);
    if (s1 != s2) return false;
    if (outSeq) *outSeq = s1;
    return true;
}

// MARK: - Atomic float/double via bit patterns (statistics only)

static inline void sf_store_f32(_Atomic uint32_t *a, float v) {
    uint32_t u; memcpy(&u, &v, sizeof u);
    atomic_store_explicit(a, u, memory_order_relaxed);
}
static inline float sf_load_f32(_Atomic uint32_t *a) {
    uint32_t u = atomic_load_explicit(a, memory_order_relaxed);
    float v; memcpy(&v, &u, sizeof v); return v;
}
static inline float sf_exchange_f32(_Atomic uint32_t *a, float v) {
    uint32_t u; memcpy(&u, &v, sizeof u);
    uint32_t old = atomic_exchange_explicit(a, u, memory_order_relaxed);
    float r; memcpy(&r, &old, sizeof r); return r;
}
static inline void sf_store_f64(_Atomic uint64_t *a, double v) {
    uint64_t u; memcpy(&u, &v, sizeof u);
    atomic_store_explicit(a, u, memory_order_relaxed);
}
static inline double sf_load_f64(_Atomic uint64_t *a) {
    uint64_t u = atomic_load_explicit(a, memory_order_relaxed);
    double v; memcpy(&v, &u, sizeof v); return v;
}
static inline double sf_exchange_f64(_Atomic uint64_t *a, double v) {
    uint64_t u; memcpy(&u, &v, sizeof u);
    uint64_t old = atomic_exchange_explicit(a, u, memory_order_relaxed);
    double r; memcpy(&r, &old, sizeof r); return r;
}
static inline void sf_max_f32(_Atomic uint32_t *a, float v) {
    if (v > sf_load_f32(a)) sf_store_f32(a, v);
}

// MARK: - Windowed-sinc interpolator

typedef struct {
    float *table;   // (phases + 1) rows x taps
    int    taps;    // 2 * half
    int    half;
    int    phases;
} SFSinc;

SFSinc *sf_sinc_create(int half, int phases, double cutoff, double kaiserBeta);
void    sf_sinc_destroy(SFSinc *s);

/// Interpolates the interleaved-stereo ring `data` at absolute fractional frame `pos`.
/// Requires frames [floor(pos) - half + 1, floor(pos) + half] to be valid.
static inline void sf_sinc_read(const SFSinc *s, const float *data, uint32_t mask, double pos,
                                float *outL, float *outR) {
    double fl = floor(pos);
    int64_t i = (int64_t)fl;
    double ph = (pos - fl) * (double)s->phases;
    int row = (int)ph;
    if (row >= s->phases) row = s->phases - 1;
    float a = (float)(ph - (double)row);
    const float *h0 = s->table + (size_t)row * (size_t)s->taps;
    const float *h1 = h0 + s->taps;
    int64_t base = i - (s->half - 1);
    float accL = 0.0f, accR = 0.0f;
    for (int k = 0; k < s->taps; k++) {
        float h = h0[k] + a * (h1[k] - h0[k]);
        uint32_t idx = (uint32_t)((uint64_t)(base + k) & mask);
        accL += h * data[2u * idx];
        accR += h * data[2u * idx + 1u];
    }
    *outL = accL;
    *outR = accR;
}

// Ring internals used by the renderer.
const float *sf_ring_data_internal(const SFSourceRing *r);
uint32_t sf_ring_mask_internal(const SFSourceRing *r);

static inline void sf_zero_output(AudioBufferList *out) {
    if (!out) return;
    for (UInt32 b = 0; b < out->mNumberBuffers; b++) {
        if (out->mBuffers[b].mData) memset(out->mBuffers[b].mData, 0, out->mBuffers[b].mDataByteSize);
    }
}

#endif
