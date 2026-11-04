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

    /// Syllables (0.3 s voiced, 0.12 s gap) at alternating pitches, each with intonation and jitter:
    /// speech-like, so it must be kept.
    func testPitchFindsAVoice() {
        let n = sr * 5
        var rng = SeededRNG(seed: 4)
        var f = [Double](repeating: 0, count: n), jitter = 0.0
        let bases: [Double] = [120, 175, 140, 200, 125, 165, 210, 130, 185, 150, 115, 190]
        for i in 0..<n {
            let t = Double(i) / Double(sr)
            let syllable = Int(t / 0.42)
            let into: Double = t - Double(syllable) * 0.42
            guard into < 0.3 else { continue }
            if i % 160 == 0 { jitter = 0.7 * jitter + rng.normal() * 25 }       // cents, every 10 ms
            f[i] = bases[syllable % bases.count] * (1 + 0.15 * into) * pow(2, jitter / 1_200)
        }
        var x = noise(n, rms: 0.002), phase = 0.0
        for i in 0..<n where f[i] > 0 {
            phase += 2 * Double.pi * f[i] / Double(sr)
            for h in 1...6 { x[i] += 0.1 / Double(h) * sin(Double(h) * phase) }
        }
        let times = (0..<90).map { 0.2 + Double($0) * 0.05 }
        let f0 = PitchTracker().track(x, sampleRate: sr, at: times)
        let voicedTruth = times.filter { f[Int($0 * Double(sr))] > 0 }.count
        XCTAssertGreaterThan(f0.filter { $0 > 0 }.count, voicedTruth / 2, "speech must be kept")
        for (q, v) in f0.enumerated() where v > 0 {
            let truth = f[Int(times[q] * Double(sr))]
            if truth > 0 { XCTAssertEqual(v, truth, accuracy: 0.06 * truth) }
        }
    }

    /// An engine's glide whose voicing flickers in and out (as it does in noise) must not be kept
    /// piece by piece: each piece is speech-length, the whole is a Doppler curve.
    func testPitchRejectsAGlideBrokenIntoPieces() {
        let n = sr * 6
        var x = noise(n, rms: 0.002), phase = 0.0
        for i in 0..<n {
            let t = Double(i) / Double(sr)
            let f: Double = 120 + 40 / (1 + exp((t - 3) * 1.5))        // 160 → 120 Hz, S-shaped
            phase += 2 * Double.pi * f / Double(sr)
            guard t.truncatingRemainder(dividingBy: 0.65) < 0.5 else { continue }
            for h in 1...4 { x[i] += 0.1 / Double(h) * sin(Double(h) * phase) }
        }
        let times = (0..<110).map { 0.2 + Double($0) * 0.05 }
        XCTAssertEqual(PitchTracker().track(x, sampleRate: sr, at: times).filter { $0 > 0 }.count, 0)
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

    /// Level of [lo, hi] Hz in consecutive blocks, dB (one FFT per block).
    private func blockLevels(_ x: [Double], _ lo: Double, _ hi: Double, seconds: Double) -> [Double] {
        let n = Int(seconds * Double(sr))
        return stride(from: 0, to: x.count - n + 1, by: n).map { 20 * log10(bandRMS(Array(x[$0..<($0 + n)]), lo, hi) + 1e-12) }
    }

    /// Noise whose level rises 12 dB and falls again over about 30 s, like a plane passing.
    private func swell(seconds: Int) -> [Double] {
        let x = noise(sr * seconds, rms: 0.02, seed: 8)
        return x.indices.map { i in
            let t = Double(i) / Double(sr) - Double(seconds) / 2
            return x[i] * pow(10, 12 * exp(-t * t / (2 * 8 * 8)) / 20)
        }
    }

    private func regenerate(_ x: [Double], flatten: Double, seed: UInt64 = 2) -> [Double] {
        var stage = LowBandRegeneration()
        stage.keepVoice = false
        stage.jitterDB = 0
        stage.seed = seed
        stage.flattenSeconds = flatten
        return stage.process(x, sampleRate: sr).output
    }

    /// The envelope attack's clue: a slow swell below the cutoff. Plain regeneration passes it on (it
    /// follows each band's loudness); flattening takes it out, and keeps the band's typical level.
    func testFlatteningRemovesASlowSwell() {
        let x = swell(seconds: 60)
        let swing = { (y: [Double]) -> Double in let l = self.blockLevels(y, 30, 220, seconds: 2); return l.max()! - l.min()! }
        XCTAssertGreaterThan(swing(x), 10)
        XCTAssertGreaterThan(swing(regenerate(x, flatten: 0)), 8, "plain regeneration should still show the swell (the leak this option closes)")
        let flat = regenerate(x, flatten: 5)
        XCTAssertLessThan(swing(flat), 3.5, "flattened: the swell should be gone")
        // The typical level is kept (the median block, not the peak).
        let median = { (l: [Double]) in l.sorted()[l.count / 2] }
        XCTAssertEqual(median(blockLevels(flat, 30, 220, seconds: 2)), median(blockLevels(x, 30, 220, seconds: 2)), accuracy: 2)
        // Above the crossover nothing changes.
        XCTAssertLessThan(abs(db(bandRMS(flat, 500, 4000), bandRMS(x, 500, 4000))), 0.05)
    }

    /// Quick sounds stay: short low thumps stand out from the gaps as much as without flattening.
    func testFlatteningKeepsShortThumps() {
        var x = noise(sr * 30, rms: 0.01, seed: 9)
        let thump = noise(Int(0.15 * Double(sr)), rms: 0.08, seed: 10)
        for start in stride(from: sr, to: x.count - thump.count, by: 2 * sr) {
            for i in thump.indices { x[start + i] += thump[i] * sin(Double.pi * Double(i) / Double(thump.count)) }
        }
        // Level in 0.5 s blocks: blocks holding a thump (every 4th, from 1 s) against the others.
        let contrast = { (y: [Double]) -> Double in
            let l = self.blockLevels(y, 30, 220, seconds: 0.5)
            let on = l.indices.filter { $0 % 4 == 2 }.map { l[$0] }, off = l.indices.filter { $0 % 4 == 0 }.map { l[$0] }
            return on.reduce(0, +) / Double(on.count) - off.reduce(0, +) / Double(off.count)
        }
        let plain = contrast(regenerate(x, flatten: 0)), flat = contrast(regenerate(x, flatten: 5))
        XCTAssertGreaterThan(plain, 3, "the thumps should stand out after plain regeneration")
        XCTAssertEqual(flat, plain, accuracy: 1.5, "flattening should keep the thumps (plain \(plain) dB, flattened \(flat) dB)")
    }

    func testFlattenHelperEdgeCases() {
        XCTAssertEqual(LowBandRegeneration.flatten([], window: 9), [])
        XCTAssertEqual(LowBandRegeneration.flatten([1, 2, 3], window: 1), [1, 2, 3])
        XCTAssertEqual(LowBandRegeneration.flatten([0, 0, 0, 0], window: 3), [0, 0, 0, 0])
        // Silent frames stay silent and don't drag their neighbours up.
        let gaps = LowBandRegeneration.flatten([4, 4, 0, 0, 0, 4, 4, 4, 4, 4], window: 3)
        XCTAssertEqual(gaps[2], 0)
        XCTAssertEqual(gaps[8], 4, accuracy: 1e-9)
        // A constant stays constant; a step becomes flat away from the edge.
        XCTAssertEqual(LowBandRegeneration.flatten([Double](repeating: 4, count: 20), window: 5), [Double](repeating: 4, count: 20))
        let step = LowBandRegeneration.flatten([Double](repeating: 1, count: 30) + [Double](repeating: 100, count: 30), window: 9)
        XCTAssertEqual(step[5], step[55], accuracy: 1e-9)
        XCTAssertTrue(step.allSatisfy(\.isFinite))
    }

    /// Off by default: the default pipeline (and so every behaviour snapshot) is untouched.
    func testFlatteningIsOffByDefault() {
        XCTAssertEqual(LowBandRegeneration().flattenSeconds, 0)
        XCTAssertEqual(ScrubPipeline().lowband.flattenSeconds, 0)
    }

    func testDefaultPipelineIncludesLowband() {
        XCTAssertEqual(ScrubPipeline.defaultSteps, [.mono, .hum, .subtract, .scurve, .lowband])
        var pipeline = ScrubPipeline()
        pipeline.lowband.seed = 1
        pipeline.hum.seed = 1
        pipeline.subtraction.passes = 1
        let out = pipeline.run(Audio(sampleRate: sr, channels: [noise(sr * 4, rms: 0.05)]))
        XCTAssertTrue(out.log.contains { $0.hasPrefix("lowband:") })
        XCTAssertFalse(out.log.contains { $0.hasPrefix("wobble:") })
    }
}
