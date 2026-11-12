import Foundation
import XCTest
@testable import OctaveCamoKit

/// The `lines` stage: whatever the check finds, at any frequency it looks at, is filled with noise.
final class LineFillTests: XCTestCase {
    private let check = FlybyAnalyzer()

    /// A jet's fan tone as it was heard on a real indoor recording: a tone near 1.2 kHz at rest,
    /// swept by the Doppler shift of a 141 m/s climb out passing 2 km away (sound travel time
    /// included), over steady noise. Received, it falls from about 1.7 to 0.9 kHz.
    static func fanTone(rate: Int, seconds: Double = 60, snr: Double = 20, seed: UInt64 = 21, f0: Double = 1_234) -> Audio {
        let c = 343.0, v = 141.0, d = 2_000.0, tc = seconds / 2 - 6
        var x = DetectionScenes.white(Int(Double(rate) * seconds), seed: seed)
        let a = DetectionScenes.amplitude(snr: snr, rate: rate)
        var phase = 0.0
        for i in x.indices {
            let t = Double(i) / Double(rate)
            var te = t - d / c                                    // emission time: te = t − r(te)/c
            for _ in 0..<6 { te = t - hypot(d, v * (te - tc)) / c }
            let along = v * (te - tc), r = hypot(d, along)
            phase += 2 * Double.pi * f0 / (1 + v * along / (c * r)) / Double(rate)
            x[i] += a * (d / r) * sin(phase)
        }
        return Audio(sampleRate: rate, channels: [x])
    }

    private func found(_ audio: Audio, from lo: Double, to hi: Double) -> [TrackReport] {
        check.analyze(audio).tracks.filter { $0.maxFrequency >= lo && $0.minFrequency <= hi }
    }

    private func fill(_ audio: Audio, seed: UInt64 = 1) -> (audio: Audio, summary: String) {
        var stage = LineFill()
        stage.seed = seed
        let r = stage.process(audio.mono, sampleRate: audio.sampleRate)
        return (Audio(sampleRate: audio.sampleRate, channels: [r.output]), r.summary)
    }

    /// RMS in [lo, hi] Hz via one big FFT.
    private func bandRMS(_ x: [Double], _ lo: Double, _ hi: Double, rate: Int) -> Double {
        var n = 1
        while n * 2 <= x.count { n *= 2 }
        var re = Array(x.prefix(n)), im = [Double](repeating: 0, count: n)
        FFT(size: n).forward(&re, &im)
        var e = 0.0
        for k in Int((lo * Double(n) / Double(rate)).rounded(.up))...Int(hi * Double(n) / Double(rate)) { e += re[k] * re[k] + im[k] * im[k] }
        return (2 * e / Double(n * n)).squareRoot()
    }

    private func db(_ a: Double, _ b: Double) -> Double { 20 * log10(a / b) }

    // MARK: The check's lines

    /// `lines(in:)` is exactly what `analyze` classifies (the refactor behind this stage).
    func testTheCheckClassifiesExactlyItsLines() {
        for name in ["plane", "hum-60", "tone-1200", "held-notes", "speech"] {
            let input = Scenes.make(name, rate: 16_000), l = check.lines(in: input)
            XCTAssertEqual(l.tracked.count + l.integrated.count, check.analyze(input).tracks.count, name)
        }
    }

    // MARK: Removal

    func testFillsASteadyHighToneAndNothingElse() {
        for rate in [16_000, 48_000] {
            let input = DetectionScenes.steady(hz: 1_200, snr: 12, rate: rate, seed: 4)
            XCTAssertFalse(found(input, from: 1_190, to: 1_210).isEmpty, "\(rate) Hz: the check should find the tone first")
            let (output, summary) = fill(input)
            XCTAssertTrue(found(output, from: 1_190, to: 1_210).isEmpty, "\(rate) Hz: still found after \(summary)")
            let x = input.mono, y = output.mono
            // Away from the strip nothing changes...
            XCTAssertLessThan(abs(db(bandRMS(y, 300, 1_100, rate: rate), bandRMS(x, 300, 1_100, rate: rate))), 0.05, "\(rate) Hz")
            XCTAssertLessThan(abs(db(bandRMS(y, 1_300, 4_000, rate: rate), bandRMS(x, 1_300, 4_000, rate: rate))), 0.05, "\(rate) Hz")
            // ...and the strip is noise at the level beside it: no tone, and no hole.
            let strip = bandRMS(y, 1_190, 1_210, rate: rate), beside = bandRMS(y, 1_240, 1_260, rate: rate)
            XCTAssertLessThan(abs(db(strip, beside)), 2.5, "\(rate) Hz: strip vs beside")
        }
    }

    /// The real-world case: a fan tone sweeping 1.7 → 0.9 kHz. The frame tracker's 1 s windows smear
    /// a sweep this fast (alone, it follows the tone only up to ~1.15 kHz even at 30–40 dB); the
    /// path search follows the whole sweep (PathSearchTests). What the check sees, `lines` removes.
    func testRemovesAJetFanToneAboveOneKilohertz() {
        let input = Self.fanTone(rate: 16_000, snr: 35)
        let seen = found(input, from: 1_100, to: 1_700)
        XCTAssertFalse(seen.isEmpty, "the check should see the fan tone above 1.1 kHz at 35 dB")
        let full = seededPipeline(seed: 3).run(input)
        print("lines: fan tone at 35 dB after Full: \(found(full.audio, from: 1_100, to: 1_700).count) line(s) left in 1.1–1.7 kHz")
        let experimental = seededPipeline(ScrubPipeline.defaultSteps.union([.lines]), seed: 3).run(input)
        let left = found(experimental.audio, from: 1_100, to: 1_700)
        XCTAssertTrue(left.isEmpty, "left: \(left.map { "\($0.kind) \(Int($0.minFrequency))–\(Int($0.maxFrequency)) Hz for \($0.duration) s" }); \(experimental.log.last ?? "")")
    }

    func testWhenTheCheckFindsNothingNothingChanges() {
        let input = DetectionScenes.noise("pink", rate: 16_000, seconds: 20, seed: 31)
        guard check.analyze(input).tracks.isEmpty else { return }       // only meaningful if the check is quiet here
        XCTAssertEqual(fill(input).audio.mono, input.mono)
    }

    /// Speech stays: the check finds a few long tones in a voice (its harmonics, when the same pitch
    /// recurs), but lines that follow the tracked pitch's harmonics are left alone.
    func testSpeechIsKept() {
        let input = Scenes.make("speech", rate: 16_000), output = fill(input)
        let kept = Spectra.kept(input.mono, output.audio.mono, rate: 16_000)
        print("lines: speech kept \(kept); \(output.summary)")
        XCTAssertGreaterThan(kept, 0.97, output.summary)
        XCTAssertTrue(output.summary.contains("follow a voice"), output.summary)
        // Without the voice rule they'd be filled (the speech scene's harmonics read as long tones).
        var stage = LineFill()
        stage.seed = 1
        stage.keepVoice = false
        let plain = stage.process(input.mono, sampleRate: 16_000)
        XCTAssertLessThan(Spectra.kept(input.mono, plain.output, rate: 16_000), kept, plain.summary)
    }

    func testTheSameSeedGivesTheSameOutput() {
        let input = DetectionScenes.steady(hz: 2_500, snr: 15, rate: 16_000, seconds: 10, seed: 6)
        XCTAssertEqual(fill(input, seed: 4).audio.mono, fill(input, seed: 4).audio.mono)
        XCTAssertNotEqual(fill(input, seed: 4).audio.mono, fill(input, seed: 5).audio.mono)
    }

    func testOffByDefault() {
        XCTAssertFalse(ScrubPipeline.defaultSteps.contains(.lines))
        XCTAssertFalse(ScrubPipeline().steps.contains(.lines))
    }

    /// Power along a moving line: frames of 4,096, the bins within ±`half` Hz of `f(t)`, over [t0, t1].
    private func alongPower(_ x: [Double], rate: Int, f: (Double) -> Double, half: Double, from t0: Double, to t1: Double) -> Double {
        let n = 4_096, fft = RealFFT(size: n), w = DSP.hann(n)
        var re = [Double](repeating: 0, count: n / 2 + 1), im = re, total = 0.0
        for start in stride(from: Int(t0 * Double(rate)), to: Int(t1 * Double(rate)) - n, by: n / 2) {
            fft.forward((0..<n).map { x[start + $0] * w[$0] }, &re, &im)
            let fc = f((Double(start) + Double(n) / 2) / Double(rate))
            for k in Int(((fc - half) * Double(n) / Double(rate)).rounded(.up))...Int((fc + half) * Double(n) / Double(rate)) {
                total += re[k] * re[k] + im[k] * im[k]
            }
        }
        return total
    }

    /// Every fill level leaves plain noise about plain: in white noise, a strip filled along a
    /// sweeping line (900 → 1,100 Hz over 20 s) keeps its power along the line, averaged over six
    /// seeds, within 0.6 dB, and nothing away from it changes. One seed alone swings ±0.5 dB; the
    /// mean for the median fill was +0.4 dB (OPEN_QUESTIONS.md, "Is the fill neutral?"), so this
    /// guards against a gross bias, not a fine one.
    func testEveryLevelKeepsNoiseAtItsLevel() {
        let rate = 16_000
        let times = Array(stride(from: 5.0, through: 25.0, by: 0.05))
        let sweep = { (t: Double) in 900 + 10 * (min(max(t, 5), 25) - 5) }
        let line = Track(times: times, frequencies: times.map(sweep), levels: times.map { _ in 0 })
        for level in [LineFill.Level.median, .logMean, .binTime, .shift] {
            var along: [Double] = []
            for seed in 1...6 {
                let x = DetectionScenes.white(rate * 30, seed: UInt64(40 + seed))
                var f = LineFill()
                f.level = level
                var y = x, rng = SeededRNG(seed: UInt64(seed))
                XCTAssertTrue(f.fill(&y, line, sampleRate: rate, rng: &rng), "\(level)")
                along.append(db(alongPower(y, rate: rate, f: sweep, half: 8, from: 7, to: 23).squareRoot(),
                                alongPower(x, rate: rate, f: sweep, half: 8, from: 7, to: 23).squareRoot()))
                XCTAssertLessThan(abs(db(bandRMS(y, 300, 800, rate: rate), bandRMS(x, 300, 800, rate: rate))), 0.05, "\(level)")
                XCTAssertLessThan(abs(db(bandRMS(y, 1_300, 4_000, rate: rate), bandRMS(x, 1_300, 4_000, rate: rate))), 0.05, "\(level)")
            }
            let mean = along.reduce(0, +) / Double(along.count)
            XCTAssertLessThan(abs(mean), 0.6, "\(level): along the line \(along)")
        }
    }

    /// `.shift` removes a sweeping tone: it copies the same bins from another moment, never from
    /// inside the strip, so the tone isn't copied back in.
    func testShiftRemovesASweepingTone() {
        let rate = 16_000
        let times = Array(stride(from: 5.0, through: 25.0, by: 0.05))
        let sweep = { (t: Double) in 900 + 10 * (min(max(t, 5), 25) - 5) }
        let line = Track(times: times, frequencies: times.map(sweep), levels: times.map { _ in 0 })
        let noise = DetectionScenes.white(rate * 30, seed: 9)
        var phase = 0.0
        let x = noise.enumerated().map { i, v -> Double in
            phase += 2 * Double.pi * sweep(Double(i) / Double(rate)) / Double(rate)
            return v + 0.05 * sin(phase)
        }
        var f = LineFill()
        f.level = .shift
        var y = x, rng = SeededRNG(seed: 3)
        XCTAssertTrue(f.fill(&y, line, sampleRate: rate, rng: &rng))
        let before = db(alongPower(x, rate: rate, f: sweep, half: 8, from: 7, to: 23).squareRoot(),
                        alongPower(noise, rate: rate, f: sweep, half: 8, from: 7, to: 23).squareRoot())
        let after = db(alongPower(y, rate: rate, f: sweep, half: 8, from: 7, to: 23).squareRoot(),
                       alongPower(noise, rate: rate, f: sweep, half: 8, from: 7, to: 23).squareRoot())
        XCTAssertGreaterThan(before, 6, "the tone should stand out first")
        XCTAssertLessThan(abs(after), 1, "after: \(after) dB over the noise")
    }

    /// A line exactly on a bin centre (1,000 Hz is bin 256 at 16 kHz) is filled: the band starts
    /// `side` bins below it, so its centre sits at exactly `side` (a strict test there skipped
    /// every frame).
    func testALineOnABinCentreIsFilled() {
        let rate = 16_000
        let x = DetectionScenes.steady(hz: 1_000, snr: 12, rate: rate, seed: 4).mono
        let times = Array(stride(from: 2.0, through: 18.0, by: 0.05))
        let line = Track(times: times, frequencies: times.map { _ in 1_000 }, levels: times.map { _ in 0 })
        var y = x, rng = SeededRNG(seed: 2)
        XCTAssertTrue(LineFill().fill(&y, line, sampleRate: rate, rng: &rng))
        // The tone (12 dB over a hertz of noise) was 4 dB over the noise in these 10 Hz; gone, the
        // strip is the noise beside it.
        let seg = Array(y[(4 * rate)..<(16 * rate)]), orig = Array(x[(4 * rate)..<(16 * rate)])
        XCTAssertLessThan(db(bandRMS(seg, 995, 1_005, rate: rate), bandRMS(orig, 995, 1_005, rate: rate)), -3, "the tone should be gone")
        XCTAssertLessThan(abs(db(bandRMS(seg, 995, 1_005, rate: rate), bandRMS(seg, 1_095, 1_105, rate: rate))), 1.5, "strip vs beside")
    }

    /// The same-bin level copies only from outside the strip, and never more than its cap.
    func testSameBinCopiesOnlyFromOutsideTheStripAndUnderTheCap() {
        let W = 20, F = 200, half = 3
        var power = [Double](repeating: 1, count: W * F)
        for m in 0..<F where m % 7 == 0 { for k in 0..<W { power[m * W + k] = 50 } }   // loud frames: over the cap
        let centre = (0..<F).map { m in m >= 80 && m < 120 ? 10.0 : Double.nan }         // the strip, bins 6–14
        for m in 0..<F { for k in 0..<W where abs(Double(k) - centre[m]) <= Double(half + 1) { power[m * W + k] = 999 } }
        var rng = SeededRNG(seed: 1)
        for _ in 0..<2_000 {
            let k = Int(rng.uniform(0...1) * Double(W - 1)), m = 80 + Int(rng.uniform(0...1) * 39)
            if let p = LineFill.sameBin(k, m, power: power, W: W, F: F, centre: centre, half: half, median: 1, reach: 60, cap: 10, rng: &rng) {
                XCTAssertNotEqual(p, 999, "copied from inside the strip")
                XCTAssertLessThanOrEqual(p, 10)
            }
        }
    }

    func testFFTSizeAndInterpolation() {
        XCTAssertEqual(LineFill.fftSize(sampleRate: 48_000), 8_192)
        XCTAssertEqual(LineFill.fftSize(sampleRate: 16_000), 4_096)
        XCTAssertEqual(LineFill.fftSize(sampleRate: 8_000), 2_048)
        var t = Track(times: [0, 1, 2], frequencies: [100, 110, 90], levels: [0, 0, 0])
        XCTAssertEqual(LineFill.interpolate(t, at: 0.5), 105, accuracy: 1e-9)
        XCTAssertEqual(LineFill.interpolate(t, at: 1.5), 100, accuracy: 1e-9)
        XCTAssertEqual(LineFill.interpolate(t, at: 2), 90, accuracy: 1e-9)
        t = Track(times: [3], frequencies: [440], levels: [0])
        XCTAssertEqual(LineFill.interpolate(t, at: 3), 440)
    }

    /// BandSTFT: an untouched band changes nothing; a band zeroed removes a tone inside it only.
    func testBandSTFTChangesOnlyItsBand() {
        let rate = 16_000, n = rate * 3
        var x = DetectionScenes.white(n, seed: 2)
        for i in 0..<n { x[i] += 0.5 * sin(2 * Double.pi * 1_000 * Double(i) / Double(rate)) }
        let size = 4_096, band = BandSTFT(x[4_000..<40_000], size: size, hop: size / 4, lo: 240, hi: 272)
        XCTAssertTrue(band.change(re: band.re, im: band.im).allSatisfy { $0 == 0 })
        let zero = [Double](repeating: 0, count: band.re.count)
        var y = x
        let delta = band.change(re: zero, im: zero)
        for i in delta.indices { y[4_000 + i] += delta[i] }
        let middle = Array(y[12_000..<32_000]), before = Array(x[12_000..<32_000])
        XCTAssertLessThan(bandRMS(middle, 990, 1_010, rate: rate), 0.01 * bandRMS(before, 990, 1_010, rate: rate))
        XCTAssertLessThan(abs(db(bandRMS(middle, 300, 800, rate: rate), bandRMS(before, 300, 800, rate: rate))), 0.05)
    }
}
