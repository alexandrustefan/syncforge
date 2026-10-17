#include "RTTestSupport.h"
#include "sf_internal.h"
#include <pthread.h>
#include <sched.h>
#include <stdlib.h>
#include <stddef.h>

typedef struct { uint64_t words[31]; unsigned char tail[3]; } Payload;
#define PAYLOAD_SIZE (offsetof(Payload, tail) + 3) // exercise a final partial atomic word
typedef struct {
    SFSeqLock lock;
    _Atomic uint64_t shared[SF_ATOMIC_WORDS(Payload)];
    _Atomic bool ready, done;
    uint32_t iterations;
} SnapshotTest;

static void *snapshot_writer(void *context) {
    SnapshotTest *test = context;
    while (!atomic_load_explicit(&test->ready, memory_order_acquire)) sched_yield();
    for (uint32_t k = 1; k <= test->iterations; k++) {
        Payload payload = {0};
        for (size_t j = 0; j < 31; j++) payload.words[j] = (uint64_t)k;
        memset(payload.tail, (unsigned char)k, sizeof payload.tail);
        sf_seq_store(&test->lock, test->shared, &payload, PAYLOAD_SIZE);
        if ((k & 15) == 0) sched_yield();
    }
    atomic_store_explicit(&test->done, true, memory_order_release);
    return NULL;
}

SFSnapshotStressResult sf_test_concurrent_snapshots(uint32_t iterations) {
    SnapshotTest test = { .iterations = iterations };
    SFSnapshotStressResult result = {0};
    pthread_t thread;
    if (pthread_create(&thread, NULL, snapshot_writer, &test) != 0) return result;
    atomic_store_explicit(&test.ready, true, memory_order_release);
    do {
        Payload payload;
        if (sf_seq_try_read(&test.lock, &payload, test.shared, PAYLOAD_SIZE, NULL)) {
            result.accepted++;
            bool coherent = true;
            for (size_t j = 1; j < 31; j++) coherent &= payload.words[j] == payload.words[0];
            for (size_t j = 0; j < sizeof payload.tail; j++) coherent &= payload.tail[j] == (unsigned char)payload.words[0];
            if (!coherent) result.inconsistent++;
        }
    } while (!atomic_load_explicit(&test.done, memory_order_acquire));
    pthread_join(thread, NULL);
    return result;
}

typedef struct {
    SFMicRecorder *mic;
    AudioBufferList input;
    AudioTimeStamp stamp;
    _Atomic bool done;
} MicTest;

static void *mic_callback(void *context) {
    MicTest *test = context;
    AudioBufferList output = {0};
    sf_mic_ioproc(0, &test->stamp, &test->input, &test->stamp, &output, &test->stamp, test->mic);
    atomic_store_explicit(&test->done, true, memory_order_release);
    return NULL;
}

bool sf_test_mic_reset_during_callback(void) {
    // Deliberately large synthetic cycle gives the control thread time to request a reset
    // after the callback has entered its recording generation, before it publishes frames.
    const uint32_t frames = 1u << 22;
    float *input = calloc(frames, sizeof(float));
    SFMicRecorder *mic = sf_mic_create(frames + 128, 16);
    if (!input || !mic) { free(input); sf_mic_destroy(mic); return false; }
    input[0] = 0.25f;
    sf_mic_set_armed(mic, true);
    MicTest test = {
        .mic = mic,
        .input = { .mNumberBuffers = 1, .mBuffers = {{ .mNumberChannels = 1,
                    .mDataByteSize = frames * sizeof(float), .mData = input }} },
        .stamp = { .mHostTime = 1000000, .mFlags = kAudioTimeStampHostTimeValid }
    };
    pthread_t thread;
    if (pthread_create(&thread, NULL, mic_callback, &test) != 0) {
        free(input); sf_mic_destroy(mic); return false;
    }
    while (sf_mic_callbacks(mic) == 0 && !atomic_load_explicit(&test.done, memory_order_acquire)) sched_yield();
    bool wasInFlight = !atomic_load_explicit(&test.done, memory_order_acquire);
    sf_mic_set_armed(mic, false);
    sf_mic_reset(mic);
    pthread_join(thread, NULL);
    bool oldWindowHidden = sf_mic_frames(mic) == 0 && sf_mic_anchor_count(mic) == 0;

    // A fresh callback acknowledges the reset and starts at frame zero, with a new timestamp.
    sf_mic_set_armed(mic, true);
    test.input.mBuffers[0].mDataByteSize = 64 * sizeof(float);
    test.stamp.mHostTime = 2000000;
    AudioBufferList output = {0};
    sf_mic_ioproc(0, &test.stamp, &test.input, &test.stamp, &output, &test.stamp, mic);
    bool freshWindow = sf_mic_frames(mic) == 64 && sf_mic_anchor_count(mic) == 1
        && sf_mic_anchors(mic)[0].frame == 0 && sf_mic_anchors(mic)[0].host == 2000000
        && sf_mic_data(mic)[0] == 0.25f;
    sf_mic_destroy(mic);
    free(input);
    return wasInFlight && oldWindowHidden && freshWindow;
}
