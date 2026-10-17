import XCTest
import SyncForgeRT
import SyncForgeRTTestSupport

final class ConcurrencyTests: XCTestCase {
    func testConcurrentSnapshotsNeverAcceptMixedPayloads() {
        let result = sf_test_concurrent_snapshots(100_000)
        XCTAssertGreaterThan(result.accepted, 0)
        XCTAssertEqual(result.inconsistent, 0)
    }

    func testMicResetCannotBeOverwrittenByInFlightCallback() {
        XCTAssertTrue(sf_test_mic_reset_during_callback())
    }

    func testQueuedMicResetHidesOldFramesUntilNextCallback() throws {
        let mic = try XCTUnwrap(sf_mic_create(1024, 16))
        defer { sf_mic_destroy(mic) }
        var samples = [Float](repeating: 0.5, count: 64)
        func cycle(host: UInt64) {
            samples.withUnsafeMutableBufferPointer { buffer in
                var input = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 1, mDataByteSize: 64 * 4, mData: buffer.baseAddress))
                var stamp = AudioTimeStamp()
                stamp.mHostTime = host
                stamp.mFlags = .hostTimeValid
                var output = AudioBufferList(mNumberBuffers: 0, mBuffers: AudioBuffer())
                sf_mic_ioproc(0, &stamp, &input, &stamp, &output, &stamp, UnsafeMutableRawPointer(mic))
            }
        }
        sf_mic_set_armed(mic, true)
        cycle(host: 1000)
        XCTAssertEqual(sf_mic_frames(mic), 64)
        sf_mic_set_armed(mic, false)
        sf_mic_reset(mic)
        XCTAssertEqual(sf_mic_frames(mic), 0)
        XCTAssertEqual(sf_mic_anchor_count(mic), 0)
        // Multiple resets before an IO cycle must collapse to a single clean new window.
        sf_mic_reset(mic)
        sf_mic_set_armed(mic, true)
        cycle(host: 2000)
        XCTAssertEqual(sf_mic_frames(mic), 64)
        XCTAssertEqual(sf_mic_anchor_count(mic), 1)
        XCTAssertEqual(sf_mic_anchors(mic)?.pointee.host, 2000)
        XCTAssertEqual(sf_mic_anchors(mic)?.pointee.frame, 0)
    }
}
