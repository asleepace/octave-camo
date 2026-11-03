import Foundation
import XCTest
@testable import OctaveCamoKit

/// Properties of what the attacker finds, for any scene: the page's "what a tracker finds" check
/// must see at least as far as the cloak reaches, cloaking never adds a clue, and what's found
/// doesn't depend on how loud the clip is or the rate it was recorded at.
final class ClueInvariantTests: XCTestCase {
    private func cloak(_ audio: Audio, seed: UInt64 = 9) -> Audio {
        var p = ScrubPipeline()
        p.hum.seed = seed
        p.lowband.seed = seed
        p.wobble.seed = seed
        return p.run(audio).audio
    }

    private func scaled(_ audio: Audio, _ gain: Double) -> Audio {
        Audio(sampleRate: audio.sampleRate, channels: audio.channels.map { $0.map { $0 * gain } })
    }

    // MARK: The check covers the cloak

    /// Every frequency a stage changes is inside the range the attacker model (the check behind
    /// the page's counts) looks at. Otherwise the cloak could be widened, leave something behind
    /// up there, and the page would still say 0.
    func testTheCheckSeesEverythingTheCloakReaches() {
        let check = FlybyAnalyzer().tracker.config.frequencyRange
        let p = ScrubPipeline()
        let reach: [(String, ClosedRange<Double>)] = [
            ("tone subtraction", p.subtraction.tracker.config.frequencyRange),
            ("S-curve search (f0)", p.scurve.f0Min...p.scurve.f0Max),
            ("hum notches", p.hum.mains.min()!...p.hum.maxFrequency),
            ("low-band regeneration", check.lowerBound...p.lowband.cutoff),
        ]
        for (stage, range) in reach {
            XCTAssertLessThanOrEqual(check.lowerBound, range.lowerBound, "\(stage) starts below what the check looks at")
            XCTAssertGreaterThanOrEqual(check.upperBound, range.upperBound, "\(stage) reaches above what the check looks at")
        }
    }

    // MARK: Never adds a clue

    func testCloakingNeverAddsAClue() {
        for name in Scenes.names {
            let input = Scenes.make(name, rate: 16_000)
            let output = cloak(input)
            let before = SceneMetrics.counts(input), after = SceneMetrics.counts(output)
            for (k, kind) in ["long tones", "doppler", "hum", "flybys"].enumerated() {
                XCTAssertLessThanOrEqual(after[k], before[k], "\(name): \(kind) \(before[k]) → \(after[k]); found after: \(Self.describe(output))")
            }
        }
    }

    /// Diagnostic (prints only): which tones a cloak adds to speech, over seeds and rates.
    func testWhatACloakAddsToSpeech() {
        for rate in [16_000, 32_000, 48_000] {
            let input = Scenes.make("speech", rate: rate)
            for seed: UInt64 in [1, 2, 3, 7, 9, 11] {
                let tracks = FlybyAnalyzer().analyze(cloak(input, seed: seed)).tracks
                if !tracks.isEmpty { print("ADDED speech \(rate) Hz seed \(seed): \(Self.describe(cloak(input, seed: seed)))") }
            }
        }
    }

    static func describe(_ audio: Audio) -> String {
        FlybyAnalyzer().analyze(audio).tracks.map { t in
            "\(t.kind) " + String(format: "%.1f Hz (%.1f–%.1f) for %.1f s", t.meanFrequency, t.minFrequency, t.maxFrequency, t.duration)
        }.joined(separator: "; ")
    }

    func testASecondCloakFindsNothingTheFirstLeft() {
        for name in ["plane", "hum-60", "speech"] {
            let once = cloak(Scenes.make(name, rate: 16_000))
            let twice = cloak(once, seed: 10)
            let a = SceneMetrics.counts(once), b = SceneMetrics.counts(twice)
            for k in a.indices { XCTAssertLessThanOrEqual(b[k], a[k], "\(name): a second cloak found more (\(a) → \(b))") }
            // And it doesn't keep eating the sound: the second pass is close to the first.
            XCTAssertGreaterThan(Spectra.kept(once.channels[0], twice.channels[0], rate: 16_000), 0.9, name)
        }
    }

    // MARK: Level and rate

    /// The attacker's thresholds are relative: the same scene 30 dB quieter (or 6 dB louder)
    /// finds the same things, and the cloak removes them just the same.
    func testLevelDoesNotChangeWhatIsFound() {
        for name in ["plane", "hum-60", "held-notes"] {
            let input = Scenes.make(name, rate: 16_000)
            let reference = SceneMetrics.counts(input)
            for gain in [0.03, 2.0] {
                XCTAssertEqual(SceneMetrics.counts(scaled(input, gain)), reference, "\(name) × \(gain)")
                let after = SceneMetrics.counts(cloak(scaled(input, gain))), afterReference = SceneMetrics.counts(cloak(input))
                XCTAssertEqual(after.map { $0 == 0 }, afterReference.map { $0 == 0 }, "\(name) × \(gain): cloaked \(afterReference) vs \(after)")
            }
        }
    }

    /// A clue found at one common rate is found at all of them, and gone after the cloak at all of them.
    func testRateDoesNotChangeWhetherAClueIsFound() {
        for name in ["plane", "hum-60"] {
            var found: [Int: [Bool]] = [:]
            for rate in [16_000, 32_000, 44_100, 48_000] {
                let input = Scenes.make(name, rate: rate)
                found[rate] = SceneMetrics.counts(input).map { $0 > 0 }
                let after = SceneMetrics.counts(cloak(input))
                XCTAssertEqual(after[1], 0, "\(name) at \(rate) Hz: Doppler track left")
                XCTAssertEqual(after[2], 0, "\(name) at \(rate) Hz: hum left")
            }
            XCTAssertEqual(Set(found.values).count, 1, "\(name): found differs by rate \(found)")
        }
    }

    // MARK: Leaves ordinary sound alone

    /// Sounds with no clue keep their level above the low band (±1.5 dB per octave) and their
    /// shape over time (kept ≥ 0.9). Held musical notes and whistles are left to the snapshot:
    /// they are trackable tones, and how much of them to touch is a tuning decision.
    func testOrdinarySoundKeepsItsLevelAboveTheLowBand() {
        for name in ["speech", "birdsong", "footsteps"] {
            let input = Scenes.make(name, rate: 32_000)
            let m = SceneMetrics.measure(input, cloak(input))
            XCTAssertGreaterThanOrEqual(m.kept, 0.9, "\(name): kept \(m.kept)")
            for (octave, delta) in m.octaves where Double(octave)! >= 500 {
                XCTAssertLessThanOrEqual(abs(delta), 1.5, "\(name): \(octave) Hz changed \(delta) dB")
            }
        }
    }

    // MARK: Known gap (enable with the widened tracker)

    /// A steady 1.2 kHz tone (a jet's fan whine is up there) is a long tone an attacker could
    /// follow. Today both the check and the cloak stop at 1 kHz, so it is neither counted nor removed.
    func testAToneAboveOneKilohertzIsFoundAndRemoved() throws {
        try XCTSkipIf(true, "known gap: the tone tracker covers 40 Hz–1 kHz; enable together with the widened tracker")
        for name in ["tone-1200", "tone-4500"] {
            let input = Scenes.make(name, rate: 16_000)
            XCTAssertGreaterThan(SceneMetrics.counts(input)[0], 0, "\(name): not found")
            XCTAssertEqual(SceneMetrics.counts(cloak(input))[0], 0, "\(name): not removed")
        }
    }

    /// The gap above, pinned: if this starts failing, the range changed and the skip above should go.
    func testTheKnownGapIsStillThere() {
        let input = Scenes.make("tone-1200", rate: 16_000)
        XCTAssertEqual(SceneMetrics.counts(input)[0], 0, "the 1.2 kHz tone is now found: enable testAToneAboveOneKilohertzIsFoundAndRemoved")
        XCTAssertEqual(FlybyAnalyzer().tracker.config.frequencyRange.upperBound, 1_000)
    }
}
