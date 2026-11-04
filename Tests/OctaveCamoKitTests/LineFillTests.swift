import Foundation
import XCTest
@testable import OctaveCamoKit

/// The `lines` stage: whatever the check finds, at any frequency it looks at, is filled with noise.
final class LineFillTests: XCTestCase {
    private let check = FlybyAnalyzer()

    /// A jet's fan tone as it was heard on a real indoor recording: a tone near 1.2 kHz at rest,
    /// swept by the Doppler shift of a 141 m/s climb out passing 2 km away (sound travel time
    /// included), over steady noise. Received, it falls from about 1.7 to 0.9 kHz.
    static func fanTone(rate: Int, seconds: Double = 60, snr: Double = 20, seed: UInt64 = 21) -> Audio {
        let c = 343.0, v = 141.0, d = 2_000.0, tc = seconds / 2 - 6, f0 = 1_234.0
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

    /// The real-world case Full misses: a fan tone sweeping 1.7 → 0.9 kHz. Full leaves it (its tone
    /// subtraction stops at 1 kHz and its flyby search at ~600 Hz); with `lines`, it's gone.
    func testRemovesAJetFanToneThatFullLeaves() {
        let input = Self.fanTone(rate: 16_000)
        XCTAssertFalse(found(input, from: 1_000, to: 1_800).isEmpty, "the check should find the fan tone")
        let full = seededPipeline(seed: 3).run(input).audio
        XCTAssertFalse(found(full, from: 1_000, to: 1_800).isEmpty, "Full now removes the fan tone: update this test and the docs")
        let experimental = seededPipeline(ScrubPipeline.defaultSteps.union([.lines]), seed: 3).run(input)
        let left = found(experimental.audio, from: 1_000, to: 1_800)
        XCTAssertTrue(left.isEmpty, "left: \(left.map { "\($0.kind) \(Int($0.minFrequency))–\(Int($0.maxFrequency)) Hz for \($0.duration) s" }); \(experimental.log.last ?? "")")
    }

    func testWhenTheCheckFindsNothingNothingChanges() {
        let input = DetectionScenes.noise("pink", rate: 16_000, seconds: 20, seed: 31)
        guard check.analyze(input).tracks.isEmpty else { return }       // only meaningful if the check is quiet here
        XCTAssertEqual(fill(input).audio.mono, input.mono)
    }

    func testSpeechIsLeftAlmostUntouched() {
        let input = Scenes.make("speech", rate: 16_000), output = fill(input).audio
        XCTAssertGreaterThan(Spectra.kept(input.mono, output.mono, rate: 16_000), 0.95)
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
