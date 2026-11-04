import Foundation
import XCTest
@testable import OctaveCamoKit

/// The slow-line integrator: its threshold arithmetic, what it finds, and what it must ignore.
final class LineIntegratorTests: XCTestCase {
    private let integrator = LineIntegrator()

    private func lines(_ audio: Audio) -> [Track] { integrator.tracks(in: audio.mono, sampleRate: audio.sampleRate) }

    func testThresholdArithmetic() {
        XCTAssertEqual(LineIntegrator.logGamma(5), log(24), accuracy: 1e-9)
        XCTAssertEqual(LineIntegrator.logGamma(0.5), log(Double.pi.squareRoot()), accuracy: 1e-9)
        // One frame, "at least one above τ": P = e^−τ, so τ = −ln p.
        XCTAssertEqual(LineIntegrator.countThreshold(1, 1, 1e-6), -log(1e-6), accuracy: 1e-6)
        // The binomial tail is a probability, and falls as τ rises.
        let t1 = LineIntegrator.binomialTail(17, 9, exp(-2)), t2 = LineIntegrator.binomialTail(17, 9, exp(-3))
        XCTAssertTrue(t1 > t2 && t2 > 0 && t1 < 1)
        // More frames buy a lower threshold for the same false alarm probability.
        XCTAssertLessThan(LineIntegrator.countThreshold(17, 9, 1e-9), LineIntegrator.countThreshold(7, 4, 1e-9))
    }

    func testFindsAWeakSteadyToneWhereItIs() {
        for rate in [16_000, 48_000] {
            let found = lines(DetectionScenes.steady(hz: 1_200, snr: 12, rate: rate, seed: 4))
            let match = found.first { abs($0.meanFrequency - 1_200) < 2 }
            XCTAssertNotNil(match, "\(rate) Hz: \(found.map(\.meanFrequency))")
            if let m = match {
                XCTAssertLessThan(m.times.first!, 2, "\(rate) Hz starts at \(m.times.first!)")
                XCTAssertGreaterThan(m.times.last!, 17, "\(rate) Hz ends at \(m.times.last!)")
                XCTAssertLessThan(m.maxFrequency - m.minFrequency, 3, "\(rate) Hz: a steady tone stays put")
            }
            XCTAssertEqual(found.count, 1, "\(rate) Hz: one tone, one line (\(found.map(\.meanFrequency)))")
        }
    }

    func testNoLinesInNoise() {
        for rate in [16_000, 48_000] {
            for kind in ["white", "pink", "wind", "traffic"] {
                let found = lines(DetectionScenes.noise(kind, rate: rate, seed: 31))
                XCTAssertTrue(found.isEmpty, "\(kind) at \(rate) Hz: \(found.map { "\(Int($0.meanFrequency)) Hz" })")
            }
        }
    }

    /// The median test: one loud burst, or a sound that keeps coming back briefly, isn't a line.
    func testIgnoresBurstsAndBroadbandThumps() {
        let rate = 16_000
        var burst = DetectionScenes.white(rate * 15, seed: 5)
        let a = DetectionScenes.amplitude(snr: 30, rate: rate)
        for i in (rate * 7)..<(rate * 7 + rate / 5) { burst[i] += a * sin(2 * .pi * 900 * Double(i) / Double(rate)) }
        XCTAssertTrue(lines(Audio(sampleRate: rate, channels: [burst])).isEmpty, "a 0.2 s burst")
        let steps = lines(Scenes.make("footsteps", rate: rate))
        XCTAssertTrue(steps.isEmpty, "footsteps: \(steps.map(\.meanFrequency))")
        let birds = lines(Scenes.make("birdsong", rate: rate))
        XCTAssertTrue(birds.isEmpty, "birdsong: \(birds.map(\.meanFrequency))")
    }

    func testLevelDoesNotMatter() {
        let audio = DetectionScenes.steady(hz: 700, snr: 10, rate: 16_000, seed: 6)
        let quiet = Audio(sampleRate: 16_000, channels: audio.channels.map { $0.map { $0 * 0.01 } })
        XCTAssertEqual(lines(audio).map { Int($0.meanFrequency * 10) }, lines(quiet).map { Int($0.meanFrequency * 10) })
    }

    func testDegenerateInput() {
        XCTAssertTrue(integrator.tracks(in: [], sampleRate: 48_000).isEmpty)
        XCTAssertTrue(integrator.tracks(in: [Double](repeating: 0, count: 48_000 * 10), sampleRate: 48_000).isEmpty, "silence")
        XCTAssertTrue(integrator.tracks(in: [Double](repeating: 0.1, count: 1_000), sampleRate: 48_000).isEmpty, "shorter than a window")
        XCTAssertTrue(integrator.tracks(in: DetectionScenes.white(8_000 * 20, seed: 1), sampleRate: 8_000).isEmpty, "8 kHz noise")
    }

    /// Integrator lines are hum or steady: their drift is too slow for a Doppler fit to mean anything.
    func testTheCheckClassifiesIntegratorLinesAsHumOrSteady() {
        let analysis = FlybyAnalyzer().analyze(DetectionScenes.gridFamily(snr: 8, rate: 16_000, seed: 2))
        XCTAssertGreaterThan(analysis.hum.count, 0, "weak grid harmonics should be found as hum: \(analysis.tracks.map { "\($0.kind) \(Int($0.meanFrequency))" })")
        XCTAssertEqual(analysis.flybys.count, 0)
    }
}
