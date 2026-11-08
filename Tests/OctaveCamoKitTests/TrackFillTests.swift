import XCTest
@testable import OctaveCamoKit

/// Removal driven by flight tracks: given an aircraft's predicted Doppler curve, find its tones and
/// fill them, and touch nothing else.
final class TrackFillTests: XCTestCase {
    static let rate = 16_000

    /// The predicted curve for `LineFillTests.fanTone` (f0 1,234 Hz, 141 m/s, 2 km, closest
    /// emission at seconds/2 − 6), as flight data would give it; `shift` moves it in time.
    static func expected(seconds: Double = 60, shift: Double = 0) -> ExpectedPass {
        let heardClosest = seconds / 2 - 6 + 2_000 / FlybyGeometry.speedOfSound + shift
        let g = FlybyGeometry(f0: 1, speed: 141, t0: heardClosest, distance: 2_000)
        // Two minutes either side: the test moves the curve up to a minute for its null.
        let t = Array(stride(from: -120.0, through: seconds + 120, by: 0.1))
        return ExpectedPass(times: t, factors: g.received(at: t).frequency, closest: heardClosest)
    }

    static func stage(_ passes: [ExpectedPass]) -> TrackFill {
        var s = TrackFill()
        s.expected = passes
        s.seed = 5
        return s
    }

    // MARK: The passes themselves

    func testExpectedPassInterpolatesAndFindsTheSteepestFall() throws {
        let p = Self.expected()
        XCTAssertTrue(p.isValid)
        let t = 20.05, i = p.times.firstIndex { $0 > t }!
        XCTAssertEqual(p.factor(at: t)!, 0.5 * (p.factors[i - 1] + p.factors[i]), accuracy: 1e-9)
        XCTAssertNil(p.factor(at: 1_000))
        // The steepest fall is heard before the closest approach (29.8 s): the approach's sound
        // arrives compressed in time.
        let heardClosest = 24 + 2_000 / FlybyGeometry.speedOfSound
        XCTAssertTrue((heardClosest - 8)...heardClosest ~= p.steepest, "\(p.steepest)")
        let round = try JSONDecoder().decode(ExpectedPass.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(round, p)
    }

    func testUnusablePassesAreRefused() {
        XCTAssertFalse(ExpectedPass(times: [0], factors: [1]).isValid)
        XCTAssertFalse(ExpectedPass(times: [0, 1], factors: [1]).isValid)
        XCTAssertFalse(ExpectedPass(times: [1, 0], factors: [1, 1]).isValid)
        XCTAssertFalse(ExpectedPass(times: [0, 1], factors: [1, .nan]).isValid)
        XCTAssertFalse(ExpectedPass(times: [0, 1], factors: [1, 3]).isValid)
        let x = DetectionScenes.white(Self.rate * 30, seed: 1)
        let r = Self.stage([ExpectedPass(times: [0, 1], factors: [1, .nan])]).process(x, sampleRate: Self.rate)
        XCTAssertEqual(r.output, x)
        XCTAssertTrue(r.summary.contains("no usable"), r.summary)
    }

    // MARK: Finding and removing

    /// The attacker's verdict on the clip's one pass.
    static func verdict(_ x: [Double], _ stage: TrackFill) -> TrackFill.Tone? {
        stage.verdicts(x, sampleRate: rate).first ?? nil
    }

    /// A pass too faint for the blind path search (13 dB/Hz; at 16 kHz it needs ~16) stands out
    /// to an attacker who has the track, at the right rest frequency and timing; after removal
    /// it doesn't.
    func testFindsAndRemovesAPassTheBlindCheckCantSee() {
        let x = LineFillTests.fanTone(rate: Self.rate, snr: 13).mono
        XCTAssertTrue(PathSearch().tracks(in: x, sampleRate: Self.rate).isEmpty, "the blind search sees it: this test lost its point")
        let stage = Self.stage([Self.expected()])
        guard let before = Self.verdict(x, stage) else { return XCTFail("no verdict") }
        XCTAssertGreaterThan(before.z, stage.stopZ + 2)
        XCTAssertEqual(before.rest, 1_234, accuracy: 1_234 * 0.015)
        XCTAssertLessThanOrEqual(abs(before.offset), 1.5)
        let r = stage.process(x, sampleRate: Self.rate)
        XCTAssertFalse(r.summary.contains("filled 0 "), r.summary)
        XCTAssertLessThan(Self.verdict(r.output, stage)?.z ?? 0, stage.stopZ, r.summary)
    }

    /// A loud pass ends below the bar too, in a few fills, not one per shoulder (at the z-1 stop a
    /// 30 dB pass takes four: 20.1 → 1.0).
    func testALoudPassEndsBelowTheBar() {
        for snr in [30.0, 40] {
            let x = LineFillTests.fanTone(rate: Self.rate, snr: snr).mono
            let stage = Self.stage([Self.expected()])
            let r = stage.process(x, sampleRate: Self.rate)
            XCTAssertLessThan(Self.verdict(r.output, stage)?.z ?? 0, stage.stopZ, "\(snr) dB: \(r.summary)")
            XCTAssertTrue(["filled 1 ", "filled 2 ", "filled 3 ", "filled 4 "].contains { r.summary.contains($0) }, "\(snr) dB: \(r.summary)")
        }
    }

    /// Only the strip along the found curve changes: every sample outside the searched window is
    /// identical, and the spectrum away from the swept range is unchanged.
    func testTouchesOnlyTheCurve() {
        let x = LineFillTests.fanTone(rate: Self.rate, snr: 16).mono
        let stage = Self.stage([Self.expected()])
        let y = stage.process(x, sampleRate: Self.rate).output
        XCTAssertNotEqual(x, y)
        let c = Self.expected().center, guardBand = stage.fillHalfWindow + stage.maxOffset + 1
        for i in x.indices where abs(Double(i) / Double(Self.rate) - c) > guardBand {
            if x[i] != y[i] { return XCTFail("sample at \(Double(i) / Double(Self.rate)) s changed") }
        }
        // Below 700 Hz and above 2.5 kHz (the curve sweeps ~0.9–1.7 kHz): no change.
        for band in [(100.0, 700.0), (2_500.0, 6_000.0)] {
            let a = Self.bandPower(x, band), b = Self.bandPower(y, band)
            XCTAssertEqual(10 * log10(b / a), 0, accuracy: 0.05, "\(band)")
        }
    }

    // MARK: Leaving things alone

    func testNoPassesIsANoOp() {
        let x = DetectionScenes.white(Self.rate * 30, seed: 2)
        let r = Self.stage([]).process(x, sampleRate: Self.rate)
        XCTAssertEqual(r.output, x)
    }

    /// Noise along a plausible curve: nothing stands out, so little is filled, and what is filled
    /// leaves the attacker's z below the stopping point without raising it (several seeds). With
    /// the stop at z 1, noise alone sometimes crosses it; filling noise must not create evidence.
    func testNoiseAloneStaysBelowTheStop() {
        let stage = Self.stage([Self.expected()])
        for seed in 1...4 {
            let x = DetectionScenes.white(Self.rate * 60, seed: UInt64(seed))
            let before = Self.verdict(x, stage)?.z ?? 0
            XCTAssertLessThan(before, 3, "seed \(seed): noise shouldn't look like a pass")
            let r = stage.process(x, sampleRate: Self.rate)
            let after = Self.verdict(r.output, stage)?.z ?? 0
            XCTAssertLessThan(after, max(stage.stopZ, before) + 0.5, "seed \(seed): \(r.summary)")
        }
    }

    /// The tone is there, but not when the tracks say: a wrong track doesn't remove the real pass
    /// (the right track still finds it afterwards), and works only around its own closest
    /// approach. (Its curve, at some rest frequencies, lies along the real tone's tail, which an
    /// attacker holding that track would score too, z 4.2 here; it fills those and stops.)
    func testAPassAtTheWrongTimeLeavesTheRealOne() {
        let x = LineFillTests.fanTone(rate: Self.rate, seconds: 120, snr: 20).mono
        let wrong = Self.stage([Self.expected(seconds: 120, shift: 45)]), right = Self.stage([Self.expected(seconds: 120)])
        let r = wrong.process(x, sampleRate: Self.rate)
        XCTAssertGreaterThan(Self.verdict(r.output, right)?.z ?? 0, right.stopZ + 2, r.summary)
        let c = wrong.expected[0].center, guardBand = wrong.fillHalfWindow + wrong.maxOffset + 1
        XCTAssertFalse(x.indices.contains { abs(Double($0) / Double(Self.rate) - c) > guardBand && x[$0] != r.output[$0] })
    }

    /// Speech under a predicted pass: its harmonics don't follow the curve, so it's untouched.
    func testSpeechIsLeftAlone() {
        let speech = Scenes.make("speech", rate: Self.rate).mono
        let x = Array([speech, speech, speech, speech].joined())
        let r = Self.stage([Self.expected()]).process(x, sampleRate: Self.rate)
        XCTAssertEqual(r.output, x, r.summary)
    }

    // MARK: Aiming at a draw from the null

    /// (score before, after, target) from a null-target summary's "a → b (target t)".
    static func aimed(_ summary: String) -> (Double, Double, Double)? {
        guard let r = summary.range(of: #"(-?[0-9.]+) → (-?[0-9.]+) \(target (-?[0-9.]+)\)"#, options: .regularExpression) else { return nil }
        let n = summary[r].split(whereSeparator: { " →()target".contains($0) }).compactMap { Double($0) }
        return n.count == 3 ? (n[0], n[1], n[2]) : nil
    }

    /// Noise along a curve, the target drawn above its score: the strip is raised (the sound already
    /// there, louder) until the score is near the target, and nothing is filled.
    func testNullTargetRaisesAQuietPassTowardItsTarget() {
        var lifted = 0
        for seed in 1...6 {
            var stage = Self.stage([Self.expected()])
            stage.target = .null
            stage.seed = UInt64(seed)
            let x = DetectionScenes.white(Self.rate * 60, seed: UInt64(seed))
            let r = stage.process(x, sampleRate: Self.rate)
            guard let (before, after, aim) = Self.aimed(r.summary) else { return XCTFail(r.summary) }
            let check = Self.verdict(r.output, stage)?.z ?? .nan
            XCTAssertEqual(check, after, accuracy: 0.11, r.summary)
            if aim > before + stage.targetTolerance {
                lifted += 1
                XCTAssertTrue(r.summary.contains("filled 0 ") && r.summary.contains("raised 1 "), r.summary)
                XCTAssertEqual(after, aim, accuracy: 0.6, r.summary)
            }
        }
        XCTAssertGreaterThan(lifted, 0, "no target fell above its score: this test lost its point")
    }

    /// A loud pass under a null target: removed down to around its target (a draw from the null,
    /// so a few at most), not left standing.
    func testNullTargetStillRemovesALoudPass() {
        let x = LineFillTests.fanTone(rate: Self.rate, snr: 30).mono
        var stage = Self.stage([Self.expected()])
        stage.target = .null
        let r = stage.process(x, sampleRate: Self.rate)
        guard let (before, after, aim) = Self.aimed(r.summary) else { return XCTFail(r.summary) }
        XCTAssertGreaterThan(before, 10, r.summary)
        XCTAssertLessThan(after, max(aim, stage.stopZ) + 1, r.summary)
    }

    // MARK: In the pipeline

    func testRunsAfterTheLowBandAndBeforeLinesOnlyWhenGivenPasses() {
        let audio = LineFillTests.fanTone(rate: Self.rate, seconds: 60, snr: 16)
        var p = ScrubPipeline()
        p.steps = [.mono, .lowband, .lines]
        p.lowband.seed = 1
        p.lines.seed = 1
        let plain = p.run(audio).log
        XCTAssertFalse(plain.contains { $0.hasPrefix("tracks:") })
        p.tracks = Self.stage([Self.expected()])
        let log = p.run(audio).log
        let order = ["lowband", "tracks:", "lines:"].map { key in log.firstIndex { $0.hasPrefix(key) } ?? -1 }
        XCTAssertTrue(order.allSatisfy { $0 >= 0 } && order == order.sorted(), "\(log)")
    }

    // MARK: Helpers

    static func bandPower(_ x: [Double], _ band: (Double, Double)) -> Double {
        let n = 4_096, fft = RealFFT(size: n), w = DSP.hann(n)
        var re = [Double](repeating: 0, count: n / 2 + 1), im = re, total = 0.0
        let lo = Int(band.0 * Double(n) / Double(rate)), hi = Int(band.1 * Double(n) / Double(rate))
        for start in stride(from: 0, to: x.count - n, by: n / 2) {
            fft.forward((0..<n).map { x[start + $0] * w[$0] }, &re, &im)
            for k in lo..<hi { total += re[k] * re[k] + im[k] * im[k] }
        }
        return total
    }
}
