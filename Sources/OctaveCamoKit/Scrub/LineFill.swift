#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WASILibc)
import WASILibc
#endif

/// Removes what the check finds. Every long tone the attacker's tracker or the line integrator
/// reports, at any frequency the check looks at (40 Hz–8 kHz), is replaced along its path by noise
/// at the level of the spectrum just beside it; then the check looks again, up to `passes` times.
///
/// The other stages each remove what their own detector sees (tone subtraction below 1 kHz, the
/// flyby search below ~600 Hz base frequency and its harmonics). Real recordings carry lines they
/// miss: faint car tones the subtraction's tracker never targets, an electrical whine at 5 kHz, an
/// engine's fan tone at 1–2 kHz sweeping with a climbing jet. This stage is driven by the check itself, so what the
/// page counts is what gets removed.
///
/// Noise fill can't be undone (the tone's samples are gone, not masked), and a strip a few bins
/// wide is little of the sound. It does remove held musical notes and other tones the check finds
/// alike (see PLAN.md: the music policy).
public struct LineFill: ScrubStage {
    var step: ScrubStep { .lines }

    /// Rounds of check → fill.
    public var passes = 2
    /// Extra half-width of the strip beyond the window's main lobe, Hz, plus `relativeMargin` of
    /// the frequency: room for the path's tracking error.
    public var marginHz = 2.0
    public var relativeMargin = 0.002
    /// The attacker model that decides what to fill (the same check the page counts with).
    public var check = FlybyAnalyzer()
    public var seed: UInt64 = .random(in: 1...UInt64.max)

    public init() {}

    /// FFT size: the power of two at least 0.15 s long (8192 at 48 kHz, 4096 at 16 kHz).
    static func fftSize(sampleRate: Int) -> Int {
        var size = 256
        while Double(size) < 0.15 * Double(sampleRate) { size *= 2 }
        return size
    }

    public func process(_ x: [Double], sampleRate: Int) -> (output: [Double], summary: String) {
        var y = x, rng = SeededRNG(seed: seed)
        var found: [Int] = [], filled = 0
        for _ in 0..<max(passes, 0) {
            let lines = check.lines(in: Audio(sampleRate: sampleRate, channels: [y]))
            let all = lines.tracked + lines.integrated
            found.append(all.count)
            if all.isEmpty { break }
            for line in all where fill(&y, line, sampleRate: sampleRate, rng: &rng) { filled += 1 }
        }
        let rounds = found.map(String.init).joined(separator: " → ")
        return (y, "lines: filled \(filled) line(s) the check found (\(rounds) per pass)")
    }

    /// Replaces one line's strip with matched noise. Returns false when there was nothing to fill.
    func fill(_ y: inout [Double], _ line: Track, sampleRate: Int, rng: inout SeededRNG) -> Bool {
        guard let t0 = line.times.first, let t1 = line.times.last, !line.frequencies.isEmpty else { return false }
        let sr = Double(sampleRate), size = Self.fftSize(sampleRate: sampleRate), hop = size / 4
        let binHz = sr / Double(size), frameSeconds = Double(size) / sr

        // How wide: the Hann main lobe (±2 bins), the tracking margin, and the sweep within a frame.
        var slope = 0.0
        for i in 1..<max(line.times.count, 1) where line.times[i] > line.times[i - 1] {
            slope = max(slope, abs(line.frequencies[i] - line.frequencies[i - 1]) / (line.times[i] - line.times[i - 1]))
        }
        let top = line.maxFrequency
        let half = 2 + Int(((marginHz + relativeMargin * top + 0.5 * slope * frameSeconds) / binHz).rounded(.up))
        let side = 4 * half + 3

        // The stretch: the line plus a frame and a half either side (the fill fades in and out over half a frame).
        let a = max(0, Int(((t0 - 1.5 * frameSeconds) * sr).rounded(.down)))
        let b = min(y.count, Int(((t1 + 1.5 * frameSeconds) * sr).rounded(.up)))
        guard b - a > size / 2 else { return false }
        let lo = max(1, Int((line.minFrequency / binHz).rounded(.down)) - side)
        let hi = min(size / 2, Int((line.maxFrequency / binHz).rounded(.up)) + side + 1)
        guard hi - lo > 2 * side else { return false }

        let band = BandSTFT(y[a..<b], size: size, hop: hop, lo: lo, hi: hi)
        let W = band.width, F = band.frames
        var power = [Double](repeating: 0, count: F * W)
        for i in 0..<(F * W) { power[i] = band.re[i] * band.re[i] + band.im[i] * band.im[i] }
        var outRe = band.re, outIm = band.im
        let gain = (band.overlapPower / band.windowPower).squareRoot()
        let fade = 0.5 * frameSeconds
        var changed = false
        var sideBins: [Double] = []
        sideBins.reserveCapacity(5 * 4 * side)

        for m in 0..<F {
            let t = (Double(a) + Double(band.center(of: m))) / sr
            // Weight in time: 1 along the line, a raised cosine to 0 over half a frame beyond its ends.
            let beyond = max(t0 - t, t - t1, 0)
            if beyond >= fade { continue }
            let wt = beyond == 0 ? 1 : 0.5 + 0.5 * cos(Double.pi * beyond / fade)
            let f = Self.interpolate(line, at: min(max(t, t0), t1))
            let c = f / binHz - Double(lo)
            guard c > Double(side), c < Double(W - side) else { continue }

            // The local floor: bins 2–4 half-widths beside the strip, over ±2 frames.
            sideBins.removeAll(keepingCapacity: true)
            for mm in max(0, m - 2)...min(F - 1, m + 2) {
                for k in 0..<W {
                    let d = abs(Double(k) - c)
                    if d >= Double(2 * half + 1) && d <= Double(side) { sideBins.append(power[mm * W + k]) }
                }
            }
            guard !sideBins.isEmpty else { continue }
            let floor = DSP.median(sideBins[...])
            // Hann-windowed noise: the median of an exponential (|X|²) is ln 2 of its mean.
            let meanPower = floor / log(2.0)
            let amp = (meanPower / 2).squareRoot() * gain

            let kLo = max(0, Int((c - Double(half) - 1).rounded(.down))), kHi = min(W - 1, Int((c + Double(half) + 1).rounded(.up)))
            for k in kLo...kHi {
                let d = abs(Double(k) - c)
                let wk = d <= Double(half) ? 1.0 : max(0, 1 - (d - Double(half)))
                let w = wt * wk
                if w <= 0 { continue }
                let i = m * W + k
                let keep = (1 - w).squareRoot(), use = w.squareRoot()
                outRe[i] = keep * band.re[i] + use * amp * rng.normal()
                outIm[i] = keep * band.im[i] + use * amp * rng.normal()
                changed = true
            }
        }
        guard changed else { return false }
        let delta = band.change(re: outRe, im: outIm)
        for i in 0..<delta.count { y[a + i] += delta[i] }
        return true
    }

    /// The line's frequency at time t (linear between its frames; t inside its span).
    static func interpolate(_ line: Track, at t: Double) -> Double {
        let ts = line.times, fs = line.frequencies
        guard ts.count > 1 else { return fs[0] }
        var j = 1
        while j < ts.count - 1 && ts[j] < t { j += 1 }
        let span = ts[j] - ts[j - 1]
        if span <= 0 { return fs[j] }
        let u = min(max((t - ts[j - 1]) / span, 0), 1)
        return fs[j - 1] + u * (fs[j] - fs[j - 1])
    }
}
