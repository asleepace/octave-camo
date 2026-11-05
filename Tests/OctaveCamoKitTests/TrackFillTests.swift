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
        let t = Array(stride(from: -5.0, through: seconds + 5, by: 0.1))
        return ExpectedPass(times: t, factors: g.received(at: t).frequency)
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

    /// A pass too faint for the blind path search (13 dB/Hz; at 16 kHz it needs ~16) is found
    /// along its predicted curve, once, at the right rest frequency and timing, and is gone
    /// afterwards.
    func testFindsAndRemovesAPassTheBlindCheckCantSee() {
        let audio = LineFillTests.fanTone(rate: Self.rate, snr: 13)
        let x = audio.mono
        XCTAssertTrue(PathSearch().tracks(in: x, sampleRate: Self.rate).isEmpty, "the blind search sees it: this test lost its point")
        let stage = Self.stage([Self.expected()])
        let found = stage.find(x, sampleRate: Self.rate)
        XCTAssertEqual(found.count, 1, "\(found)")
        if let tone = found.first {
            XCTAssertEqual(tone.rest, 1_234, accuracy: 1_234 * 0.01)
            XCTAssertLessThanOrEqual(abs(tone.offset), 1)
        }
        let r = stage.process(x, sampleRate: Self.rate)
        XCTAssertTrue(r.summary.contains("filled 1 "), r.summary)
        let after = stage.find(r.output, sampleRate: Self.rate)
        XCTAssertFalse(after.contains { abs($0.rest - 1_234) < 25 }, "\(after)")
    }

    /// A loud pass is one tone, filled once, with nothing left: no shoulders of it, no ghosts.
    /// (Masking found tones in the spectrogram, instead of filling and searching again, left
    /// shoulders at ±2–3 % and ghosts at 607 and 299 Hz on this clip at 40 dB.)
    func testALoudPassIsOneToneAndNothingIsLeft() {
        for snr in [30.0, 40] {
            let x = LineFillTests.fanTone(rate: Self.rate, snr: snr).mono
            let stage = Self.stage([Self.expected()])
            let r = stage.process(x, sampleRate: Self.rate)
            XCTAssertTrue(r.summary.contains("filled 1 "), "\(snr) dB: \(r.summary)")
            XCTAssertTrue(stage.find(r.output, sampleRate: Self.rate).isEmpty, "\(snr) dB")
        }
    }

    /// Only the strip along the found curve changes: every sample outside the searched window is
    /// identical, and the spectrum away from the swept range is unchanged.
    func testTouchesOnlyTheCurve() {
        let x = LineFillTests.fanTone(rate: Self.rate, snr: 16).mono
        let stage = Self.stage([Self.expected()])
        let y = stage.process(x, sampleRate: Self.rate).output
        XCTAssertNotEqual(x, y)
        let c = Self.expected().steepest, guardBand = stage.halfWindow + stage.maxOffset + 1
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

    /// Noise along a plausible curve: nothing stands out, nothing is filled (several seeds).
    func testNoiseAloneFillsNothing() {
        let stage = Self.stage([Self.expected()])
        for seed in 1...4 {
            let x = DetectionScenes.white(Self.rate * 60, seed: UInt64(seed))
            XCTAssertTrue(stage.find(x, sampleRate: Self.rate).isEmpty, "seed \(seed)")
        }
    }

    /// The tone is there, but not when the tracks say: nothing is filled (it removes what the
    /// tracks predict, not whatever moves).
    func testAPassAtTheWrongTimeFillsNothing() {
        let x = LineFillTests.fanTone(rate: Self.rate, seconds: 120, snr: 20).mono
        let stage = Self.stage([Self.expected(seconds: 120, shift: 45)])
        XCTAssertFalse(stage.find(x, sampleRate: Self.rate).contains { abs($0.rest - 1_234) < 25 })
    }

    /// Speech under a predicted pass: its harmonics don't follow the curve, so it's untouched.
    func testSpeechIsLeftAlone() {
        let speech = Scenes.make("speech", rate: Self.rate).mono
        let x = Array([speech, speech, speech, speech].joined())
        let r = Self.stage([Self.expected()]).process(x, sampleRate: Self.rate)
        XCTAssertEqual(r.output, x, r.summary)
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
