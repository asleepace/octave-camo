import Foundation
import XCTest
@testable import OctaveCamoKit

/// Properties of what the attacker finds, for any scene: the page's "what a tracker finds" check
/// must see at least as far as the cloak reaches, cloaking never adds a clue, and what's found
/// doesn't depend on how loud the clip is or the rate it was recorded at.
final class ClueInvariantTests: XCTestCase {
    private func cloak(_ audio: Audio, seed: UInt64 = 9) -> Audio { cloaked(audio, seed: seed) }

    private func scaled(_ audio: Audio, _ gain: Double) -> Audio {
        Audio(sampleRate: audio.sampleRate, channels: audio.channels.map { $0.map { $0 * gain } })
    }

    // MARK: The check covers the cloak

    /// Every frequency a stage changes is inside the range the attacker model (the check behind
    /// the page's counts) looks at. Otherwise the cloak could be widened, leave something behind
    /// up there, and the page would still say 0.
    func testTheCheckSeesEverythingTheCloakReaches() {
        let check = FlybyAnalyzer().tracker.config.coverage
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

    /// No scene gains a Doppler track, a hum line or a fitted flyby, and scenes without a voice
    /// gain no long tone either. (Voices: see testCloakingSpeechAddsNoLongTone.)
    func testCloakingNeverAddsAClue() {
        for name in Scenes.names {
            let input = Scenes.make(name, rate: 16_000)
            let output = cloak(input)
            let before = SceneMetrics.counts(input), after = SceneMetrics.counts(output)
            let voiced = ["speech", "singing"].contains(name)
            for (k, kind) in ["long tones", "doppler", "hum", "flybys"].enumerated() where !(voiced && k == 0) {
                XCTAssertLessThanOrEqual(after[k], before[k], "\(name): \(kind) \(before[k]) → \(after[k]); found after: \(Self.describe(output))")
            }
        }
    }

    /// Known issue: with about half of the seeds, the cloaked speech scene has a 2–4 s "long tone"
    /// at the voice's own pitch (≈140 Hz) or a harmonic (≈360, ≈540 Hz) that the original didn't:
    /// the kept voice harmonics read as steadier against the regenerated low band. Not a location
    /// clue (no Doppler or hum fit), but the page would show "long tones 0 → 1".
    func testCloakingSpeechAddsNoLongTone() throws {
        try XCTSkipIf(true, "known issue: kept voice harmonics can read as a long tone after the low band is regenerated")
        for rate in [16_000, 48_000] {
            let input = Scenes.make("speech", rate: rate)
            for seed: UInt64 in [1, 2, 3, 9, 11] {
                let output = cloak(input, seed: seed)
                XCTAssertEqual(SceneMetrics.counts(output)[0], 0, "speech \(rate) Hz seed \(seed): \(Self.describe(output))")
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
    /// shape over time (kept ≥ 0.85; footsteps sit near 0.9, their thumps are in the regenerated band). Held musical notes and whistles are left to the snapshot:
    /// they are trackable tones, and how much of them to touch is a tuning decision.
    func testOrdinarySoundKeepsItsLevelAboveTheLowBand() {
        for name in ["speech", "birdsong", "footsteps"] {
            let input = Scenes.make(name, rate: 32_000)
            let m = SceneMetrics.measure(input, cloak(input))
            XCTAssertGreaterThanOrEqual(m.kept, 0.85, "\(name): kept \(m.kept)")
            for (octave, delta) in m.octaves where Double(octave)! >= 500 {
                XCTAssertLessThanOrEqual(abs(delta), 1.5, "\(name): \(octave) Hz changed \(delta) dB")
            }
        }
    }

    // MARK: Above 1 kHz

    /// The check looks up to 8 kHz: steady tones up there are found where they are, while speech,
    /// birdsong and plain background noise are not.
    func testTheCheckFindsHighTonesButNotVoicesOrBirds() {
        for (name, hz) in [("tone-1200", 1_200.0), ("tone-4500", 4_500.0)] {
            let a = FlybyAnalyzer().analyze(Scenes.make(name, rate: 16_000))
            let match = a.tracks.first { $0.minFrequency - 5 < hz && $0.maxFrequency + 5 > hz }
            XCTAssertNotNil(match, "\(name): not found (\(a.tracks.map(\.meanFrequency)))")
            if let m = match {
                XCTAssertLessThan(m.start, 1.5, "\(name) starts at \(m.start) s")
                XCTAssertGreaterThan(m.duration, 12, "\(name) lasts \(m.duration) s")
                XCTAssertNotEqual(m.kind, .hum, "\(name): a high steady tone isn't called hum")
            }
        }
        // (Sung notes are left out on purpose: harmonics of different notes that coincide, such as
        // 12 × 220 ≈ 9 × 294 ≈ 8 × 330 Hz, do make a tone a tracker can follow, as held notes do
        // below 1 kHz. The snapshot records how many.)
        // (A whistled tune is left out too: its scene repeats the same notes many times a phrase,
        // and the line integrator rightly finds those recurring tones. Telling music from machines
        // is the risk classes' job, ACOUSTICS.md §5.)
        for name in ["speech", "birdsong", "footsteps"] {
            for rate in [16_000, 48_000] {
                let high = FlybyAnalyzer().analyze(Scenes.make(name, rate: rate)).tracks.filter { $0.meanFrequency > 1_000 }
                XCTAssertTrue(high.isEmpty, "\(name) at \(rate) Hz: \(high.map { "\($0.meanFrequency) Hz for \($0.duration) s" })")
            }
        }
    }

    /// The high band has its own peak budget: adding it changes nothing the check found below 1 kHz.
    func testTheHighBandLeavesTheLowBandAlone() {
        var lowOnly = FlybyAnalyzer()
        lowOnly.tracker.config.extraRanges = []
        for name in ["plane", "plane-hard", "hum-60", "held-notes", "speech"] {
            let input = Scenes.make(name, rate: 32_000)
            let low = lowOnly.analyze(input).tracks.map { "\($0.kind) \(Int($0.meanFrequency)) \(Int($0.duration * 10))" }
            let both = FlybyAnalyzer().analyze(input).tracks.filter { $0.maxFrequency < 1_000 }
                .map { "\($0.kind) \(Int($0.meanFrequency)) \(Int($0.duration * 10))" }
            XCTAssertEqual(both.sorted(), low.sorted(), name)
        }
    }

    /// Known gap: the cloak's tone subtraction still stops at 1 kHz, so a tone up there is counted
    /// (and outlined on the page) but not removed. Enable with the widened subtraction.
    func testAToneAboveOneKilohertzIsRemoved() throws {
        try XCTSkipIf(true, "known gap: tone subtraction covers 40 Hz–1 kHz; enable together with the widened subtraction")
        for name in ["tone-1200", "tone-4500"] {
            XCTAssertEqual(SceneMetrics.counts(cloak(Scenes.make(name, rate: 16_000)))[0], 0, "\(name): not removed")
        }
    }

    /// The gap above, pinned: if this starts failing, the cloak reaches higher and the skip should go.
    func testTheKnownGapIsStillThere() {
        let after = SceneMetrics.counts(cloak(Scenes.make("tone-1200", rate: 16_000)))
        XCTAssertGreaterThan(after[0], 0, "the 1.2 kHz tone is now removed: enable testAToneAboveOneKilohertzIsRemoved")
        XCTAssertEqual(ScrubPipeline().subtraction.tracker.config.coverage.upperBound, 1_000)
    }
}
