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
/// the rest of the low band is regenerated. Engines are periodic too, so voiced runs that hold a
/// nearly constant pitch for too long are rejected: speech moves, machines don't.
public struct PitchTracker {
    public var minHz = 70.0
    public var maxHz = 400.0
    /// YIN aperiodicity threshold (lower is stricter). 0.3 finds most voiced speech in real
    /// recordings without picking up background noise.
    public var threshold = 0.3
    /// Voiced runs longer than this with less than `steadyCents` of movement are not voice.
    public var maxSteadySeconds = 1.5
    public var steadyCents = 30.0

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

    private func rejectSteadyRuns(_ f0: inout [Double], times: [Double]) {
        var start = 0
        while start < f0.count {
            if f0[start] == 0 { start += 1; continue }
            var end = start
            while end + 1 < f0.count && f0[end + 1] > 0 && abs(cents(f0[end + 1], f0[end])) < 100 { end += 1 }
            if times[end] - times[start] > maxSteadySeconds {
                let run = f0[start...end]
                if cents(run.max()!, run.min()!) < steadyCents {
                    for i in start...end { f0[i] = 0 }
                }
            }
            start = end + 1
        }
    }
}
