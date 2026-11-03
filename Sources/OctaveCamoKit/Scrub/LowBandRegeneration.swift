#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WASILibc)
import WASILibc
#endif

/// Makes the low band information-free without detecting anything.
///
/// Distant aircraft leak through narrow tones below a few hundred Hz, which an attacker follows to
/// about 0.5 Hz for tens of seconds. A listener hears that region in critical bands (about 35 Hz
/// wide at 100 Hz) as texture. So below `cutoff`:
/// - `.regenerate` replaces it with noise matching each ERB band's loudness over time, slowly
///   smoothed and randomly re-gained, keeping tracked voice harmonics as they are;
/// - `.highpass` removes it.
///
/// Port of the harness's `lowband` module; its tests are the spec.
public struct LowBandRegeneration: ScrubStage {
    var step: ScrubStep { .lowband }

    public enum Mode: String, CaseIterable { case regenerate, highpass }

    public var mode = Mode.regenerate
    public var cutoff = 300.0
    /// Crossover half-width as a fraction of `cutoff`.
    public var crossover = 0.2
    public var keepVoice = true
    /// Envelope smoothing, s: hides the loudness swell of a passing plane.
    public var smoothSeconds = 0.75
    /// Slow random gain per band, ±dB, with 10–30 s periods.
    public var jitterDB = 1.5
    public var fftSize = 8_192
    public var pitch = PitchTracker()
    public var seed: UInt64 = .random(in: 1...UInt64.max)

    public init() {}

    public func process(_ x: [Double], sampleRate: Int) -> (output: [Double], summary: String) {
        let sr = Double(sampleRate), size = fftSize, hop = size / 4
        let binHz = sr / Double(size)
        let top = cutoff * (1 + crossover), bottom = cutoff * (1 - crossover)
        let K = min(Int((top / binHz).rounded(.up)) + 2, size / 2)
        let stft = LowBandSTFT(x, size: size, hop: hop, bins: K)
        let F = stft.frames
        var outRe = stft.re, outIm = stft.im

        // How much of each bin to replace: 1 below `bottom`, raised cosine to 0 at `top`.
        let replace: [Double] = (0..<K).map { k in
            let f = Double(k) * binHz
            if f <= bottom { return 1 }
            if f >= top { return 0 }
            return 0.5 + 0.5 * cos(Double.pi * (f - bottom) / (top - bottom))
        }

        if mode == .highpass {
            for m in 0..<F {
                for k in 0..<K {
                    outRe[m * K + k] *= 1 - replace[k]
                    outIm[m * K + k] *= 1 - replace[k]
                }
            }
            return (stft.render(re: outRe, im: outIm), "lowband: removed below \(Int(cutoff)) Hz")
        }

        // Voice harmonics to keep.
        var keep = [Bool](repeating: false, count: F * K)
        var voicedFrames = 0
        if keepVoice {
            let times = (0..<F).map { stft.centerTime(of: $0, sampleRate: sampleRate) }
            let f0 = pitch.track(x, sampleRate: sampleRate, at: times)
            for m in 0..<F where f0[m] > 0 {
                voicedFrames += 1
                var h = 1.0
                while h * f0[m] < top {
                    let c = h * f0[m] / binHz
                    let lo = max(0, Int((c - 1.5).rounded(.down))), hi = min(K - 1, Int((c + 1.5).rounded(.up)))
                    if lo <= hi { for k in lo...hi { keep[m * K + k] = true } }
                    h += 1
                }
            }
        }

        // ERB bands over [0, top]; each bin belongs to one band.
        let edges = [0.0] + ERB.bands(from: 20, to: top).dropFirst()
        let B = edges.count - 1
        let bandOf: [Int] = (0..<K).map { k in
            let f = Double(k) * binHz
            var b = 0
            while b + 1 < B && f >= edges[b + 1] { b += 1 }
            return b
        }

        // Static per-bin spectral shape (long-term median power): carries no time-varying information.
        let profile: [Double] = (0..<K).map { k in
            let powers = (0..<F).map { m in stft.re[m * K + k] * stft.re[m * K + k] + stft.im[m * K + k] * stft.im[m * K + k] }
            return DSP.median(powers[...]) + 1e-20
        }

        // Band energy per frame (replaced bins only), smoothed, with slow random gain.
        var rng = SeededRNG(seed: seed)
        let framesPerSecond = sr / Double(hop)
        var energy = [[Double]](repeating: [Double](repeating: 0, count: F), count: B)
        for m in 0..<F {
            for k in 0..<K where !keep[m * K + k] && replace[k] > 0 {
                let i = m * K + k
                energy[bandOf[k]][m] += stft.re[i] * stft.re[i] + stft.im[i] * stft.im[i]
            }
        }
        let smoothFrames = Int((smoothSeconds * framesPerSecond).rounded())
        let target: [[Double]] = energy.map { e in
            let s = DSP.smooth(e, length: smoothFrames)
            let periods = [rng.uniform(10...30), rng.uniform(10...30)]
            let phases = [rng.uniform(0...(2 * Double.pi)), rng.uniform(0...(2 * Double.pi))]
            return s.indices.map { m in
                let t = Double(m) / framesPerSecond
                let wobble = sin(2 * Double.pi * t / periods[0] + phases[0]) + sin(2 * Double.pi * t / periods[1] + phases[1])
                return s[m] * pow(10, jitterDB / 2 * wobble / 10)
            }
        }

        // Random-phase frames overlap-add incoherently, so their power comes out lower than the
        // analyzed (coherent) frames' by windowPower / overlapPower; compensate.
        let gain = (stft.overlapPower / stft.windowPower).squareRoot()
        for m in 0..<F {
            var shapeSum = [Double](repeating: 0, count: B)
            for k in 0..<K where !keep[m * K + k] && replace[k] > 0 { shapeSum[bandOf[k]] += profile[k] }
            for k in 0..<K {
                let i = m * K + k, w = replace[k]
                if keep[i] || w == 0 { continue }
                let b = bandOf[k]
                let share = shapeSum[b] > 0 ? profile[k] / shapeSum[b] : 0
                let amp = (target[b][m] * share / 2).squareRoot() * gain
                // Power-complementary crossfade: the original and the noise are uncorrelated.
                let keepOriginal = (1 - w).squareRoot(), useNoise = w.squareRoot()
                outRe[i] = keepOriginal * stft.re[i] + useNoise * amp * rng.normal()
                outIm[i] = keepOriginal * stft.im[i] + useNoise * amp * rng.normal()
            }
        }
        let voice = keepVoice ? ", kept voice harmonics in \(100 * voicedFrames / max(F, 1))% of frames" : ""
        return (stft.render(re: outRe, im: outIm), "lowband: regenerated below \(Int(cutoff)) Hz in \(B) ERB bands\(voice)")
    }
}
