import XCTest
@testable import OctaveCamoKit

/// The cloak must not leave fingerprints of its own: notch holes that say which grid the
/// recording came from, or narrow lines copied into regenerated noise. Mirrors the harness's
/// "no fingerprints from the cloak itself" tests.
final class FingerprintTests: XCTestCase {
    private let sr = 16_000

    private func noise(_ n: Int, rms: Double, seed: UInt64) -> [Double] {
        var rng = SeededRNG(seed: seed)
        return rng.normals(n).map { $0 * rms }
    }

    /// Long-term power spectrum (Hann-windowed periodograms, half overlap).
    private func spectrum(_ x: [Double], size n: Int = 1 << 16) -> [Double] {
        let fft = RealFFT(size: n), window = DSP.hann(n)
        var power = [Double](repeating: 0, count: fft.binCount)
        var frame = [Double](repeating: 0, count: n)
        var re = [Double](repeating: 0, count: fft.binCount), im = [Double](repeating: 0, count: fft.binCount)
        var start = 0
        while start + n <= x.count {
            for i in 0..<n { frame[i] = x[start + i] * window[i] }
            fft.forward(frame, &re, &im)
            for k in 0..<fft.binCount { power[k] += re[k] * re[k] + im[k] * im[k] }
            start += n / 2
        }
        return power
    }

    /// Mean dB of the spectrum at each f (lowest of 5 bins) relative to its 4–12 Hz neighbourhood.
    private func prominence(_ power: [Double], at freqs: [Double], size n: Int = 1 << 16) -> Double {
        let binHz = Double(sr) / Double(n)
        var total = 0.0
        for f in freqs {
            let k = Int((f / binHz).rounded())
            let at = (k - 2...k + 2).map { power[$0] }.min()!
            var around: [Double] = []
            for d in Int((4 / binHz).rounded())...Int((12 / binHz).rounded()) { around.append(power[k - d]); around.append(power[k + d]) }
            total += 10 * log10(at / DSP.median(around[...]))
        }
        return total / Double(freqs.count)
    }

    func testDefaultNotchesCoverBothGridsOnce() {
        var below400 = HumNotch()
        below400.maxFrequency = 400
        XCTAssertEqual(below400.harmonics(sampleRate: 48_000), [50, 60, 100, 120, 150, 180, 200, 240, 250, 300, 350, 360])
        var sixty = HumNotch()
        sixty.mains = [60]
        XCTAssertEqual(sixty.harmonics(sampleRate: 48_000), Array(stride(from: 60.0, to: 1_000, by: 60)))
        // Both families up to 1 kHz, shared harmonics (300, 600, 900) once.
        XCTAssertEqual(HumNotch().harmonics(sampleRate: 48_000).count, 19 + 16 - 3)
        // Never at or above Nyquist, and nothing for nonsense grids.
        XCTAssertLessThan(HumNotch().harmonics(sampleRate: 1_000).max() ?? 0, 450)
        var silly = HumNotch()
        silly.mains = [0.01, -50, .nan]
        XCTAssertEqual(silly.harmonics(sampleRate: 48_000), [])
    }

    func testRefillRemovesAWanderingMainsLineWithoutLeavingAHole() {
        let n = sr * 8
        var x = noise(n, rms: 0.02, seed: 5)
        var phase = 0.0
        for i in 0..<n {
            phase += 2 * Double.pi * (60 + 0.05 * sin(2 * Double.pi * Double(i) / Double(sr) / 3)) / Double(sr)
            x[i] += 0.05 * sin(phase)
        }
        var hum = HumNotch()
        hum.seed = 3
        let y = Array(hum.process(x, sampleRate: sr).output[sr..<(n - sr)])
        let power = spectrum(y, size: 1 << 15)
        let binHz = Double(sr) / Double(1 << 15)
        func band(_ f: Double) -> Double {
            let k = Int((f / binHz).rounded())
            return (k - 3...k + 3).map { power[$0] }.reduce(0, +)
        }
        // The line is gone (no peak), and no hole is left (about the noise floor's power).
        XCTAssertLessThan(abs(10 * log10(band(60) / band(75))), 4)
    }

    func testCloakLeavesNoDipsThatTellSixtyHertzFromFifty() {
        var pipeline = ScrubPipeline()
        pipeline.steps = [.hum, .lowband]
        pipeline.hum.seed = 21
        pipeline.lowband.seed = 21
        let x = noise(sr * 30, rms: 0.05, seed: 21)
        let y = pipeline.run(Audio(sampleRate: sr, channels: [x])).audio.channels[0]
        let power = spectrum(y)
        let sixty = prominence(power, at: [120, 180, 240, 360]), fifty = prominence(power, at: [100, 150, 200, 250, 350])
        XCTAssertLessThan(abs(sixty - fifty), 1.5, "60 Hz family \(sixty) dB vs 50 Hz family \(fifty) dB")
    }

    func testRegeneratedNoiseCarriesNoNarrowLinesFromTheInput() {
        var x = noise(sr * 30, rms: 0.05, seed: 22)
        for i in x.indices { x[i] += 0.02 * sin(2 * Double.pi * 87 * Double(i) / Double(sr)) }   // steady motor hum
        var stage = LowBandRegeneration()
        stage.keepVoice = false
        stage.seed = 22
        let y = stage.process(x, sampleRate: sr).output
        XCTAssertLessThan(prominence(spectrum(y), at: [87]), 3)
    }

    func testProfileSmoothingSpreadsNarrowFeaturesAndKeepsFlatOnes() {
        var spike = [Double](repeating: 1, count: 100)
        spike[50] = 101
        let smoothed = LowBandRegeneration.smoothProfile(spike, binHz: 5.86, erbs: 1)
        XCTAssertLessThan(smoothed[50], 30)
        XCTAssertEqual(smoothed.reduce(0, +), spike.reduce(0, +), accuracy: 60)     // energy roughly kept
        XCTAssertEqual(LowBandRegeneration.smoothProfile([Double](repeating: 2, count: 40), binHz: 5.86, erbs: 1),
                       [Double](repeating: 2, count: 40))
    }
}
