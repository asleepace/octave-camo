#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WASILibc)
import WASILibc
#endif

/// Voice pitch tracking (YIN, de Cheveigné & Kawahara 2002), used to keep voice harmonics while
/// the rest of the low band is regenerated. Engines are periodic too, so two kinds of voiced run
/// are rejected: a nearly constant pitch held too long (machines don't move), and any unbroken run
/// longer than speech produces (a passing engine glides for many seconds without a break, and
/// keeping its pitch curve would hand the attacker the Doppler curve).
public struct PitchTracker {
    public var minHz = 70.0
    public var maxHz = 400.0
    /// YIN aperiodicity threshold (lower is stricter). 0.3 finds most voiced speech in real
    /// recordings without picking up background noise.
    public var threshold = 0.3
    /// Smooth (machine-like) stretches longer than this are rejected.
    public var maxSteadySeconds = 1.5
    /// "Steady": the smoothed pitch moves less than this over the stretch.
    public var steadyCents = 50.0
    /// Unvoiced gaps up to this long (or 2.5 query spacings, if longer) don't end a stretch.
    public var maxGapSeconds = 0.3
    /// Unbroken voiced runs longer than this are not speech, however they move. Speech breaks
    /// for consonants and pauses every second or so; a long sung note loses only its kept
    /// low-band detail (it's regenerated like everything else).
    public var maxRunSeconds = 2.0

    public init() {}

    /// f0 in Hz at each query time (0 = unvoiced).
    public func track(_ x: [Double], sampleRate: Int, at times: [Double]) -> [Double] {
        let (y, rate) = DSP.decimate(x, sampleRate: Double(sampleRate), to: 8_000)
        let window = Int((0.04 * rate).rounded())                  // 40 ms integration
        let maxLag = Int((rate / minHz).rounded(.up)), minLag = Int(rate / maxHz)
        var d = [Double](repeating: 0, count: maxLag + 1)
        var f0 = [Double](repeating: 0, count: times.count)

        for q in times.indices {
            let start = Int((times[q] * rate - Double(window) / 2).rounded())
            guard start >= 0, start + window + maxLag < y.count else { continue }
            var energy = 0.0
            for i in 0..<window { energy += y[start + i] * y[start + i] }
            guard energy >= 1e-10 * Double(window) else { continue }

            // Difference function, cumulative-mean normalized.
            var running = 0.0
            d[0] = 1
            for tau in 1...maxLag {
                var s = 0.0
                for i in 0..<window {
                    let e = y[start + i] - y[start + i + tau]
                    s += e * e
                }
                running += s
                d[tau] = running > 0 ? s * Double(tau) / running : 1
            }
            var lag = -1
            var t = minLag
            while t <= maxLag {
                if d[t] < threshold {
                    while t + 1 <= maxLag && d[t + 1] < d[t] { t += 1 }
                    lag = t
                    break
                }
                t += 1
            }
            guard lag > 0 else { continue }
            let a = d[lag - 1], b = d[lag], c = lag + 1 <= maxLag ? d[lag + 1] : d[lag]
            let den = a - 2 * b + c
            let refined = den != 0 ? Double(lag) + 0.5 * (a - c) / den : Double(lag)
            f0[q] = rate / refined
        }
        rejectSteadyRuns(&f0, times: times)
        return f0
    }

    private func cents(_ a: Double, _ b: Double) -> Double { 1200 * log2(a / b) }

    /// Rejects voiced stretches that come from a machine rather than a voice:
    /// - an unbroken run longer than `maxRunSeconds` (speech breaks every second or so);
    /// - a stretch longer than `maxSteadySeconds`, joined across short unvoiced gaps (noise makes
    ///   a machine's voicing flicker, which would otherwise chop it into speech-length pieces),
    ///   whose smoothed pitch is steady or moves one way throughout, like a Doppler pass. Speech
    ///   pitch rises and falls.
    private func rejectSteadyRuns(_ f0: inout [Double], times: [Double]) {
        var reject = [Bool](repeating: false, count: f0.count)
        // Unbroken runs.
        var start = 0
        while start < f0.count {
            if f0[start] == 0 { start += 1; continue }
            var end = start
            while end + 1 < f0.count && f0[end + 1] > 0 && abs(cents(f0[end + 1], f0[end])) < 100 { end += 1 }
            if times[end] - times[start] > maxRunSeconds { for i in start...end { reject[i] = true } }
            start = end + 1
        }
        // Stretches joined across short gaps, judged by smoothness. A gap is short relative to the
        // query spacing too: with queries 0.25 s apart, one unvoiced query is already a 0.5 s gap.
        var spacings: [Double] = []
        for i in 1..<max(times.count, 1) where times[i] > times[i - 1] { spacings.append(times[i] - times[i - 1]) }
        let spacing = spacings.isEmpty ? 0.05 : DSP.median(spacings[...])
        let maxGap = max(maxGapSeconds, 2.5 * spacing)
        var group: [Int] = []
        // Smoothing (a running median over ~0.25 s) takes out the estimator's own jitter, which
        // in noise is tens of cents and would make any machine look as lively as a voice.
        let window = max(3, Int((0.25 / spacing).rounded()) | 1)
        func judge() {
            defer { group.removeAll() }
            guard group.count >= 5, let first = group.first, let last = group.last,
                  times[last] - times[first] > maxSteadySeconds else { return }
            let raw = group.map { cents(f0[$0], f0[first]) }
            var track = raw
            for k in raw.indices {
                let lo = max(0, k - window / 2), hi = min(raw.count - 1, k + window / 2)
                track[k] = DSP.median(raw[lo...hi])
            }
            // Steady: the smoothed pitch barely moves.
            let range = (track.max() ?? 0) - (track.min() ?? 0)
            // Gliding: the smoothed pitch moves one way throughout, as a passing source's does.
            var up = 0, down = 0
            for k in 1..<track.count {
                let step = track[k] - track[k - 1]
                if step > 1 { up += 1 } else if step < -1 { down += 1 }
            }
            let oneWay = up + down >= 3 && Double(max(up, down)) >= 0.9 * Double(up + down)
            if range < steadyCents || oneWay { for i in first...last { reject[i] = true } }
        }
        for i in f0.indices where f0[i] > 0 {
            if let previous = group.last,
               times[i] - times[previous] > maxGap || abs(cents(f0[i], f0[previous])) >= 100 { judge() }
            group.append(i)
        }
        judge()
        for i in f0.indices where reject[i] { f0[i] = 0 }
    }
}
