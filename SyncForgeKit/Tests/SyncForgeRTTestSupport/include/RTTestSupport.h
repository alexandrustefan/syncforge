#ifndef SF_RT_TEST_SUPPORT_H
#define SF_RT_TEST_SUPPORT_H
#include <stdbool.h>
#include <stdint.h>

typedef struct { uint64_t accepted; uint64_t inconsistent; } SFSnapshotStressResult;
SFSnapshotStressResult sf_test_concurrent_snapshots(uint32_t iterations);
/// Exercises a reset while a real mic IOProc is processing a synthetic buffer. No HAL devices.
bool sf_test_mic_reset_during_callback(void);
#endif
