import Foundation
import XCTest
@testable import OctaveCamoKit

/// Mirrors the harness's lowband / pitch / signal tests (harness/test/defense.test.ts, signal.test.ts).
final class LowBandTests: XCTestCase {
    private let sr = 16_000

    private func noise(_ n: Int, rms: Double, seed: UInt64 = 3) -> [Double] {
        var rng = SeededRNG(seed: seed)
        return rng.normals(n).map { $0 * rms }
    }

    private func addTone(_ x: inout [Double], _ freq: (Int) -> Double, amplitude: Double) {
        var phase = 0.0
        for i in x.indices {
            phase += 2 * Double.pi * freq(i) / Double(sr)
            x[i] += amplitude * sin(phase)
        }
    }

    /// Amplitude of a tone with known instantaneous frequency (coherent projection).
    private func toneAmplitude(_ x: [Double], _ freq: (Int) -> Double) -> Double {
        var phase = 0.0, s = 0.0, c = 0.0
        for i in x.indices {
            phase += 2 * Double.pi * freq(i) / Double(sr)
            s += x[i] * sin(phase); c += x[i] * cos(phase)
        }
        return 2 * (s * s + c * c).squareRoot() / Double(x.count)
    }

    /// RMS in [lo, hi] Hz via one big FFT.
    private func bandRMS(_ x: [Double], _ lo: Double, _ hi: Double) -> Double {
        var n = 1
        while n * 2 <= x.count { n *= 2 }
        var re = Array(x.prefix(n)), im = [Double](repeating: 0, count: n)
        FFT(size: n).forward(&re, &im)
        var e = 0.0
        for k in Int((lo * Double(n) / Double(sr)).rounded(.up))...Int(hi * Double(n) / Double(sr)) { e += re[k] * re[k] + im[k] * im[k] }
        return (2 * e / Double(n * n)).squareRoot()
    }

    private func db(_ a: Double, _ b: Double) -> Double { 20 * log10(a / b) }

    // MARK: STFT and helpers

    func testUnchangedBinsReconstructExactly() {
        let x = noise(sr * 3, rms: 0.1)
        let stft = LowBandSTFT(x, size: 2048, hop: 512, bins: 40)
        let y = stft.render(re: stft.re, im: stft.im)
        XCTAssertLessThan(zip(x, y).map { abs($0 - $1) }.max()!, 1e-9)
    }

    func testERBMatchesGlasbergMoore() {
        XCTAssertEqual(ERB.bandwidth(100), 35.5, accuracy: 0.1)
        XCTAssertEqual(ERB.bandwidth(1000), 132.6, accuracy: 0.1)
        for f in [20.0, 100, 300, 1000, 8000] { XCTAssertEqual(ERB.frequency(ERB.number(f)), f, accuracy: 1e-6) }
        let edges = ERB.bands(from: 20, to: 300)
        XCTAssertEqual(edges.first!, 20, accuracy: 1e-9)
        XCTAssertEqual(edges.last!, 300)
        for i in 1..<(edges.count - 1) {
            let width = edges[i] - edges[i - 1], center = (edges[i] + edges[i - 1]) / 2
            XCTAssertEqual(width / ERB.bandwidth(center), 1, accuracy: 0.1)
        }
    }

    func testDecimateKeepsInBandAndRejectsAliases() {
        let fs = 48_000.0
        let x = (0..<96_000).map { i -> Double in
            let t = Double(i) / fs
            return 0.1 * sin(2 * Double.pi * 300 * t) + 0.1 * sin(2 * Double.pi * 3_000 * t)
        }
        let (y, rate) = DSP.decimate(x, sampleRate: fs, to: 4_000)
        XCTAssertEqual(rate, 4_000)
        let mid = Array(y[400..<(y.count - 400)])
        func amp(_ f: Double) -> Double {
            var s = 0.0, c = 0.0
            for (i, v) in mid.enumerated() { let p = 2 * Double.pi * f * Double(i) / rate; s += v * sin(p); c += v * cos(p) }
            return 2 * (s * s + c * c).squareRoot() / Double(mid.count)
        }
        XCTAssertEqual(amp(300), 0.1, accuracy: 0.002)
        XCTAssertLessThan(amp(1_000), 0.001)   // 3 kHz would alias to 1 kHz
    }

    func testSmoothAveragesAndHandlesEdges() {
        XCTAssertEqual(DSP.smooth([0, 0, 3, 0, 0], length: 3), [0, 1, 1, 1, 0])
    }

    // MARK: Pitch

    func testPitchFindsAMovingVoice() {
        var x = noise(sr * 5, rms: 0.002)
        let f: (Int) -> Double = { 140 + 25 * sin(2 * Double.pi * Double($0) / Double(self.sr) / 1.3) }
        for h in 1...6 { addTone(&x, { Double(h) * f($0) }, amplitude: 0.1 / Double(h)) }
        let times = (0..<80).map { 0.5 + Double($0) * 0.05 }
        let f0 = PitchTracker().track(x, sampleRate: sr, at: times)
        XCTAssertGreaterThan(f0.filter { $0 > 0 }.count, 60)
        for (q, v) in f0.enumerated() where v > 0 {
            XCTAssertEqual(v, f(Int(times[q] * Double(sr))), accuracy: 5)
        }
    }

    func testPitchRejectsASteadyEngineTone() {
        var x = noise(sr * 5, rms: 0.002)
        for h in 1...4 { addTone(&x, { _ in Double(h) * 95 }, amplitude: 0.1 / Double(h)) }
        let times = (0..<80).map { 0.5 + Double($0) * 0.05 }
        XCTAssertEqual(PitchTracker().track(x, sampleRate: sr, at: times).filter { $0 > 0 }.count, 0)
    }

    // MARK: Lowband

    private let drifting: (Int) -> Double = { 100 + 2 * sin(2 * Double.pi * Double($0) / 16_000 / 7) }

    func testHighpassRemovesLowToneKeepsHigh() {
        var x = [Double](repeating: 0, count: sr * 20)
        addTone(&x, drifting, amplitude: 0.1)
        addTone(&x, { _ in 1000 }, amplitude: 0.1)
        var stage = LowBandRegeneration()
        stage.mode = .highpass
        let y = stage.process(x, sampleRate: sr).output
        XCTAssertLessThan(toneAmplitude(y, drifting), 0.002)
        XCTAssertEqual(toneAmplitude(y, { _ in 1000 }), 0.1, accuracy: 0.005)
    }

    func testRegenerateKeepsLoudnessButDestroysTheTone() {
        var x = noise(sr * 20, rms: 0.05)
        addTone(&x, drifting, amplitude: 0.05)
        var stage = LowBandRegeneration()
        stage.keepVoice = false
        stage.jitterDB = 0
        stage.seed = 1
        let y = stage.process(x, sampleRate: sr).output
        XCTAssertLessThan(abs(db(bandRMS(y, 30, 220), bandRMS(x, 30, 220))), 1.5)
        XCTAssertLessThan(db(toneAmplitude(y, drifting), toneAmplitude(x, drifting)), -15)
        XCTAssertLessThan(abs(db(bandRMS(y, 500, 4000), bandRMS(x, 500, 4000))), 0.05)
    }

    func testRegenerateIsDeterministicForASeed() {
        let x = noise(sr * 6, rms: 0.05)
        var stage = LowBandRegeneration()
        stage.keepVoice = false
        stage.seed = 5
        let a = stage.process(x, sampleRate: sr).output, b = stage.process(x, sampleRate: sr).output
        stage.seed = 6
        let c = stage.process(x, sampleRate: sr).output
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testDefaultPipelineIncludesLowband() {
        XCTAssertEqual(ScrubPipeline.defaultSteps, [.mono, .hum, .subtract, .scurve, .lowband])
        var pipeline = ScrubPipeline()
        pipeline.lowband.seed = 1
        pipeline.subtraction.passes = 1
        let out = pipeline.run(Audio(sampleRate: sr, channels: [noise(sr * 4, rms: 0.05)]))
        XCTAssertTrue(out.log.contains { $0.hasPrefix("lowband:") })
        XCTAssertFalse(out.log.contains { $0.hasPrefix("wobble:") })
    }
}
