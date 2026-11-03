import Foundation
import XCTest
@testable import OctaveCamoKit

final class ModelAndIOTests: XCTestCase {
    let flyby = FlybyGeometry(f0: 120, speed: 75, t0: 30, distance: 1_500)

    func testClosestApproachIsUnshiftedAndRangeIsDistance() {
        let r = flyby.received(at: [flyby.t0])
        XCTAssertEqual(r.frequency[0], flyby.f0, accuracy: 1e-9)
        XCTAssertEqual(r.range[0], flyby.distance, accuracy: 1e-6)
    }

    func testApproachIsHigherAndRecedeIsLower() {
        let r = flyby.received(at: [0, 60])
        XCTAssertGreaterThan(r.frequency[0], flyby.f0)
        XCTAssertLessThan(r.frequency[1], flyby.f0)
    }

    func testWarmStartMatchesColdStart() {
        // Same answer whether the times arrive in order (warm-started) or one at a time (cold).
        let t = Array(stride(from: 0.0, through: 60, by: 0.37))
        let batch = flyby.received(at: t).frequency
        for (i, ti) in t.enumerated() {
            XCTAssertEqual(batch[i], flyby.received(at: [ti]).frequency[0], accuracy: 1e-9)
        }
    }

    func testWAVRoundTrip() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("roundtrip-\(UUID()).wav").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let audio = Audio(sampleRate: 44_100, channels: [[0, 0.5, -0.25, 1], [0.1, -0.1, 0.2, -1]])
        try WAV.write(audio, to: path)
        let back = try WAV.read(from: path)
        XCTAssertEqual(back.sampleRate, 44_100)
        XCTAssertEqual(back.channels.count, 2)
        for c in 0..<2 {
            for i in 0..<4 { XCTAssertEqual(back.channels[c][i], audio.channels[c][i], accuracy: 1e-7) }
        }
    }

    func testScrubStepNamesMatchCLI() {
        XCTAssertEqual(ScrubStep.allCases.map(\.rawValue), ["mono", "hum", "subtract", "wobble"])
    }
}
