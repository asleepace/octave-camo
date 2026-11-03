import XCTest
@testable import OctaveCamoKit

/// Attacker vs. defense on a known-truth clip. Run with `swift test -c release` for speed.
final class EndToEndTests: XCTestCase {
    private func clip(hard: Bool = false) -> (audio: Audio, truth: FlybyGeometry) {
        var synth = FlybySynth()
        synth.duration = 30
        synth.flyby.t0 = 15
        synth.hard = hard
        return (synth.render(), synth.flyby)
    }

    func testAnalyzerRecoversFlybyGeometry() throws {
        let (audio, truth) = clip()
        let analysis = FlybyAnalyzer().analyze(audio)
        let estimate = try XCTUnwrap(analysis.consensus, "no flyby found in the original clip")
        XCTAssertEqual(estimate.distance, truth.distance, accuracy: 0.03 * truth.distance)
        XCTAssertEqual(estimate.speed, truth.speed, accuracy: 0.03 * truth.speed)
        XCTAssertEqual(estimate.t0, truth.t0, accuracy: 0.5)
        XCTAssertEqual(estimate.f0, truth.f0, accuracy: 0.02 * truth.f0, "consensus f0 should be the fundamental")
        XCTAssertFalse(analysis.hum.isEmpty, "mains hum should be detected")
    }

    func testScrubLeavesNoFlybyOrHum() {
        var pipeline = ScrubPipeline()
        pipeline.wobble.seed = 7
        pipeline.lowband.seed = 7
        let scrubbed = pipeline.run(clip().audio).audio
        let analysis = FlybyAnalyzer().analyze(scrubbed)
        XCTAssertNil(analysis.consensus, "flyby still recoverable after scrubbing")
        XCTAssertTrue(analysis.hum.isEmpty, "hum still present after scrubbing")
    }

    func testScrubDefeatsSensitiveAttackerOnHardClip() {
        let (audio, truth) = clip(hard: true)
        var pipeline = ScrubPipeline()
        pipeline.wobble.seed = 7
        pipeline.lowband.seed = 7
        let scrubbed = pipeline.run(audio).audio
        var attacker = FlybyAnalyzer()
        attacker.tracker.config.thresholdDB = 6
        // Distance is what locates the recorder: no surviving fit may land near the true value.
        // (With the wobble stopped at 400 Hz, 1 of 3 prototype seeds failed this; at 600, 0 of 3.)
        for fit in attacker.analyze(scrubbed).flybys.compactMap(\.fit) {
            let g = fit.geometry
            XCTAssertGreaterThan(abs(g.distance - truth.distance), 0.1 * truth.distance,
                                 "attacker recovered the true distance: \(g)")
        }
    }

    func testZeroDepthWobbleIsIdentity() {
        var rng = SeededRNG(seed: 9)
        let x = rng.normals(48_000 * 3)
        var wobble = BandWobble()
        wobble.depth = 0
        let y = wobble.process(x, sampleRate: 48_000).output
        let maxError = zip(x, y).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThan(maxError, 1e-9)
    }

    func testZeroPassesDisablesSubtraction() {
        var subtraction = ToneSubtraction()
        subtraction.passes = 0
        let x = clip().audio.mono
        XCTAssertEqual(subtraction.process(x, sampleRate: 48_000).output, x)
    }

    func testStepsCanBeSwitchedOff() {
        var pipeline = ScrubPipeline()
        pipeline.steps = [.mono]
        let audio = clip().audio
        let out = pipeline.run(audio)
        XCTAssertEqual(out.log.count, 1)
        let expected = audio.mono
        let scale = min(1, pipeline.peakCeiling / DSP.peakMagnitude(expected))
        XCTAssertEqual(out.audio.channels[0][1_000], expected[1_000] * scale, accuracy: 1e-12)
    }
}
