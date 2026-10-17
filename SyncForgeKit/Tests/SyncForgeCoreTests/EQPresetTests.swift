import XCTest
@testable import SyncForgeCore

final class EQPresetTests: XCTestCase {
    func testBuiltInCurvesHaveBoundedBoostAndSafeHeadroomAtDeviceRates() {
        for rate in [44100.0, 48000, 96000] {
            for preset in EQPresets.builtIn {
                let cascade = BiquadDesign.cascade(preset.settings, sampleRate: rate)
                let preamp = BiquadDesign.effectivePreampDb(preset.settings, sampleRate: rate)
                for frequency in BiquadDesign.logFrequencies(count: 2048) {
                    let db = BiquadDesign.responseDb(cascade, frequency: frequency, sampleRate: rate)
                    XCTAssertTrue(db.isFinite, preset.name)
                    XCTAssertLessThanOrEqual(db, 4.51, "\(preset.name) at \(frequency) Hz")
                    XCTAssertLessThanOrEqual(db + preamp, 0.01, "Headroom: \(preset.name) at \(frequency) Hz")
                }
                XCTAssertTrue(preset.settings.autoHeadroom)
                XCTAssertTrue(preset.settings.limiterEnabled)
            }
        }
    }

    func testBassShelfIsSmoothAndDoesNotFormSeveralGraphicEQHumps() throws {
        let preset = try XCTUnwrap(EQPresets.named("Bass Boost"))
        let frequencies = BiquadDesign.logFrequencies(count: 1024, from: 20, to: 2000)
        let curve = frequencies.map { response(preset, at: $0) }
        XCTAssertGreaterThan(curve[0], 4.4)
        XCTAssertLessThan(abs(curve.last!), 0.01)
        for i in 1..<curve.count {
            XCTAssertLessThanOrEqual(curve[i], curve[i - 1] + 0.0001)
        }
    }

    func testMusicKeepsMidrangeAndUsesModestToneShaping() throws {
        let preset = try XCTUnwrap(EQPresets.named("Music"))
        XCTAssertEqual(response(preset, at: 1000), 0, accuracy: 0.05)
        XCTAssertEqual(response(preset, at: 30), 2, accuracy: 0.1)
        XCTAssertEqual(response(preset, at: 16000), 1, accuracy: 0.1)
        XCTAssertEqual(BiquadDesign.cascade(preset.settings, sampleRate: 48000).count, 2)
    }

    func testPurposeSpecificPresetsMoveTheirIntendedRegions() throws {
        let vocal = try XCTUnwrap(EQPresets.named("Vocal Clarity"))
        XCTAssertLessThan(response(vocal, at: 60), -1.8)
        XCTAssertGreaterThan(response(vocal, at: 2200), 1.9)
        let soft = try XCTUnwrap(EQPresets.named("Soft Treble"))
        XCTAssertEqual(response(soft, at: 1000), 0, accuracy: 0.05)
        XCTAssertLessThan(response(soft, at: 12000), -2.8)
        let quiet = try XCTUnwrap(EQPresets.named("Low Volume"))
        XCTAssertGreaterThan(response(quiet, at: 30), 3.3)
        XCTAssertEqual(response(quiet, at: 1000), 0, accuracy: 0.05)
        let night = try XCTUnwrap(EQPresets.named("Night Mode"))
        XCTAssertLessThan(response(night, at: 40), -4.8)
        XCTAssertTrue(night.summary?.contains("not dynamic-range compression") == true)
        let small = try XCTUnwrap(EQPresets.named("Small Speakers"))
        XCTAssertLessThan(response(small, at: 20), -18)
        XCTAssertGreaterThan(response(small, at: 150), 1)
    }

    func testStackedPresetsStillHaveHeadroom() throws {
        let system = try XCTUnwrap(EQPresets.named("Music")).settings
        let device = try XCTUnwrap(EQPresets.named("Bass Boost")).settings
        let chain = BiquadDesign.chain(system: system, device: device, sampleRate: 44100)
        for frequency in BiquadDesign.logFrequencies(count: 2048) {
            let db = BiquadDesign.responseDb(chain.cascade, frequency: frequency, sampleRate: 44100)
            XCTAssertLessThanOrEqual(db + chain.preampDb, 0.01)
        }
    }

    func testOldCustomPresetsDecodeWithoutDescriptions() throws {
        let preset = EQPreset(name: "My Sound", settings: .flat)
        var data = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(preset)) as? [String: Any])
        data.removeValue(forKey: "summary")
        let decoded = try JSONDecoder().decode(EQPreset.self, from: JSONSerialization.data(withJSONObject: data))
        XCTAssertEqual(decoded.name, "My Sound")
        XCTAssertEqual(decoded.settings, preset.settings)
        XCTAssertNil(decoded.summary)
    }

    private func response(_ preset: EQPreset, at frequency: Double) -> Double {
        BiquadDesign.responseDb(BiquadDesign.cascade(preset.settings, sampleRate: 48000),
                               frequency: frequency, sampleRate: 48000)
    }
}
