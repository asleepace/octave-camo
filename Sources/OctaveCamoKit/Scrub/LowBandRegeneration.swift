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
    /// Off at 0. Otherwise each band's loudness loses its swells slower than about this many seconds
    /// (see `flatten`): it keeps the band's median level and anything quicker (a thump, a door,
    /// footsteps), but not the rise and fall
    /// of a passing plane over tens of seconds, which the smoothing above lets through and an
    /// attacker can line up with flight tracks (ACOUSTICS.md, the envelope attack).
    public var flattenSeconds = 0.0
    public var fftSize = 8_192
    /// Width, in ERBs, over which the noise's spectral shape is smoothed. Anything narrower (a
    /// notch left by `hum`, a steady motor tone) would otherwise be copied into the new noise.
    public var profileSmoothingERB = 1.0
    /// Half-width kept around each voice harmonic, Hz (in Hz, not bins, so it's the same at
    /// every sample rate).
    public var voiceHalfWidthHz = 9.0
    public var pitch = PitchTracker()
    public var seed: UInt64 = .random(in: 1...UInt64.max)

    public init() {}

    public func process(_ x: [Double], sampleRate: Int) -> (output: [Double], summary: String) {
        let sr = Double(sampleRate), size = fftSize, hop = size / 4
        let binHz = sr / Double(size)
        // Keep the crossover inside (40 Hz, 0.45 × sample rate): a cutoff outside it would leave
        // no bands (and trap) or reach past Nyquist.
        let cutoff = min(max(self.cutoff.isFinite ? self.cutoff : 300, 40), 0.45 * sr / (1 + crossover))
        let top = cutoff * (1 + crossover), bottom = cutoff * (1 - crossover)
        let K = min(Int((top / binHz).rounded(.up)) + 2, size / 2)
        let stft = LowBandSTFT(x, size: size, hop: hop, bins: K)
        let F = stft.frames
        var outRe = stft.re, outIm = stft.im

        // How much of each bin to replace: 1 below `bottom`, raised cosine to 0 at `top`.
        var replace = [Double](repeating: 0, count: K)
        for k in 0..<K {
            let f: Double = Double(k) * binHz
            if f <= bottom {
                replace[k] = 1
            } else if f < top {
                let u: Double = (f - bottom) / (top - bottom)
                replace[k] = 0.5 + 0.5 * cos(Double.pi * u)
            }
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
            var times = [Double](repeating: 0, count: F)
            for m in 0..<F { times[m] = stft.centerTime(of: m, sampleRate: sampleRate) }
            let f0 = pitch.track(x, sampleRate: sampleRate, at: times)
            for m in 0..<F where f0[m] > 0 {
                voicedFrames += 1
                var h = 1.0
                while h * f0[m] < top {
                    let c = h * f0[m] / binHz, half = voiceHalfWidthHz / binHz
                    let lo = max(0, Int((c - half).rounded(.down))), hi = min(K - 1, Int((c + half).rounded(.up)))
                    if lo <= hi { for k in lo...hi { keep[m * K + k] = true } }
                    h += 1
                }
            }
        }

        // ERB bands over [0, top]; each bin belongs to one band.
        let edges = [0.0] + ERB.bands(from: 20, to: top).dropFirst()
        let B = edges.count - 1
        var bandOf = [Int](repeating: 0, count: K)
        for k in 0..<K {
            let f: Double = Double(k) * binHz
            var b = 0
            while b + 1 < B && f >= edges[b + 1] { b += 1 }
            bandOf[k] = b
        }

        // Static per-bin spectral shape (long-term median power): carries no time-varying information.
        var rawProfile = [Double](repeating: 0, count: K)
        var powers = [Double](repeating: 0, count: F)
        for k in 0..<K {
            for m in 0..<F {
                let i = m * K + k
                let p: Double = stft.re[i] * stft.re[i] + stft.im[i] * stft.im[i]
                powers[m] = p
            }
            rawProfile[k] = DSP.median(powers[...]) + 1e-20
        }
        let profile = Self.smoothProfile(rawProfile, binHz: binHz, erbs: profileSmoothingERB)

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
        var target: [[Double]] = []
        target.reserveCapacity(B)
        for b in 0..<B {
            var s: [Double] = DSP.smooth(energy[b], length: smoothFrames)
            if flattenSeconds > 0 { s = Self.flatten(s, window: Int((flattenSeconds * framesPerSecond).rounded())) }
            let period1: Double = rng.uniform(10...30), period2: Double = rng.uniform(10...30)
            let phase1: Double = rng.uniform(0...(2 * Double.pi)), phase2: Double = rng.uniform(0...(2 * Double.pi))
            for m in 0..<F {
                let t: Double = Double(m) / framesPerSecond
                let a: Double = sin(2 * Double.pi * t / period1 + phase1)
                let c: Double = sin(2 * Double.pi * t / period2 + phase2)
                let decibels: Double = jitterDB / 2 * (a + c)
                s[m] *= pow(10, decibels / 10)
            }
            target.append(s)
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
        let flat = flattenSeconds > 0 ? ", flattened swells slower than \(Self.seconds(flattenSeconds))" : ""
        return (stft.render(re: outRe, im: outIm), "lowband: regenerated below \(Int(cutoff)) Hz in \(B) ERB bands\(voice)\(flat)")
    }

    /// A band's power over time with its slow part taken out: in decibels, minus a centered
    /// triangular running average (a box `window` frames wide, applied twice), plus the band's
    /// median. A triangle's response is sinc², so sounds that recur faster than the window (footsteps,
    /// a ticking motor) cancel out of the average instead of being eaten into, while a swell slower
    /// than the window is followed and removed. Silent frames (every bin kept as voice) stay silent
    /// and don't pull the average down.
    static func flatten(_ power: [Double], window: Int) -> [Double] {
        guard window > 2, power.count > 2 else { return power }
        let positive = power.filter { $0 > 0 }
        guard !positive.isEmpty else { return power }
        let typical = DSP.median(positive.map { log($0) }[...])
        let levels = power.map { $0 > 0 ? log($0) : typical }
        let slow = DSP.smooth(DSP.smooth(levels, length: window), length: window)
        return power.indices.map { i in power[i] > 0 ? exp(levels[i] - slow[i] + typical) : 0 }
    }

    private static func seconds(_ s: Double) -> String {
        s == s.rounded() ? "\(Int(s)) s" : "\(s) s"
    }

    /// Centered moving average of a power spectrum, `erbs` ERBs wide at each bin (at least 3 bins).
    static func smoothProfile(_ profile: [Double], binHz: Double, erbs: Double) -> [Double] {
        guard erbs > 0 else { return profile }
        let K = profile.count
        var prefix = [Double](repeating: 0, count: K + 1)
        for k in 0..<K { prefix[k + 1] = prefix[k] + profile[k] }
        var out = [Double](repeating: 0, count: K)
        for k in 0..<K {
            let width: Double = erbs * ERB.bandwidth(Double(k) * binHz) / binHz
            let half = max(1, Int((width / 2).rounded()))
            let lo = max(0, k - half), hi = min(K - 1, k + half)
            out[k] = (prefix[hi + 1] - prefix[lo]) / Double(hi - lo + 1)
        }
        return out
    }
}
