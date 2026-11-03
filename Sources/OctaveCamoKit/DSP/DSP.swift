#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WASILibc)
import WASILibc
#endif

/// Small numeric helpers shared across the package.
enum DSP {
    static func nextPowerOfTwo(atLeast n: Int) -> Int {
        var p = 1
        while p < n { p <<= 1 }
        return p
    }

    /// Symmetric Hann window (numpy.hanning).
    static func hann(_ n: Int) -> [Double] {
        guard n > 1 else { return [1] }
        return (0..<n).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n - 1)) }
    }

    static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(max(x, lo), hi) }

    // MARK: Statistics

    static func mean<C: Collection>(_ a: C) -> Double where C.Element == Double {
        a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count)
    }

    static func standardDeviation(_ a: [Double]) -> Double {
        let m = mean(a)
        return sqrt(mean(a.map { ($0 - m) * ($0 - m) }))
    }

    static func median(_ a: ArraySlice<Double>) -> Double {
        let s = a.sorted()
        guard !s.isEmpty else { return 0 }
        let mid = s.count / 2
        return s.count % 2 == 1 ? s[mid] : 0.5 * (s[mid - 1] + s[mid])
    }

    static func weightedMean(_ values: [Double], weights: [Double]) -> Double {
        let total = weights.reduce(0, +)
        guard total > 0 else { return mean(values) }
        return zip(values, weights).reduce(0) { $0 + $1.0 * $1.1 } / total
    }

    static func peakMagnitude(_ x: [Double]) -> Double { x.reduce(0) { max($0, abs($1)) } }

    /// Scales down (never up) so the peak is at most `ceiling`.
    static func limitPeak(_ x: inout [Double], to ceiling: Double) {
        let peak = peakMagnitude(x)
        guard peak > ceiling else { return }
        let g = ceiling / peak
        for i in x.indices { x[i] *= g }
    }

    // MARK: Signals

    /// Running phase of an oscillator whose frequency (Hz) is given per step of `dt` seconds.
    /// Element i includes step i (numpy.cumsum convention).
    static func cumulativePhase(_ frequency: [Double], dt: Double) -> [Double] {
        var phase = [Double](repeating: 0, count: frequency.count)
        var acc = 0.0
        let k = 2 * Double.pi * dt
        for i in frequency.indices {
            acc += k * frequency[i]
            phase[i] = acc
        }
        return phase
    }

    /// numpy.convolve(a, ones(L)/L, "same"): centered box filter with zero-padded edges.
    static func movingAverage(_ a: [Double], length L: Int) -> [Double] {
        let n = a.count
        guard n > 0, L > 1 else { return a }
        let h = (L - 1) / 2
        var prefix = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + a[i] }
        let scale = 1 / Double(L)
        return (0..<n).map { i in
            let lo = max(i - (L - 1) + h, 0), hi = min(i + h, n - 1)
            return hi >= lo ? (prefix[hi + 1] - prefix[lo]) * scale : 0
        }
    }

    /// numpy.gradient(f, t): second-order central differences, non-uniform spacing allowed.
    static func gradient(_ f: [Double], _ t: [Double]) -> [Double] {
        let n = f.count
        guard n > 1 else { return [Double](repeating: 0, count: n) }
        var g = [Double](repeating: 0, count: n)
        g[0] = (f[1] - f[0]) / (t[1] - t[0])
        g[n - 1] = (f[n - 1] - f[n - 2]) / (t[n - 1] - t[n - 2])
        if n > 2 {
            for i in 1..<(n - 1) {
                let hl = t[i] - t[i - 1], hr = t[i + 1] - t[i]
                g[i] = (hl * hl * f[i + 1] - hr * hr * f[i - 1] + (hr * hr - hl * hl) * f[i])
                    / (hl * hr * (hl + hr))
            }
        }
        return g
    }

    /// numpy.interp: piecewise linear, clamped at the ends. `xp` must be ascending.
    static func interpolate(_ xq: [Double], _ xp: [Double], _ fp: [Double]) -> [Double] {
        precondition(!xp.isEmpty && xp.count == fp.count, "interpolate: bad table")
        let last = xp.count - 1
        return xq.map { x in
            if x <= xp[0] { return fp[0] }
            if x >= xp[last] { return fp[last] }
            var lo = 0, hi = last
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if xp[mid] <= x { lo = mid } else { hi = mid }
            }
            return fp[lo] + (x - xp[lo]) / (xp[hi] - xp[lo]) * (fp[hi] - fp[lo])
        }
    }

    /// Centered moving average over `length` samples; edges average only the samples present.
    static func smooth(_ x: [Double], length: Int) -> [Double] {
        guard length > 1, !x.isEmpty else { return x }
        let n = x.count, h = length / 2
        var prefix = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + x[i] }
        return (0..<n).map { i in
            let lo = max(0, i - h), hi = min(n, i + h + 1)
            return (prefix[hi] - prefix[lo]) / Double(hi - lo)
        }
    }

    /// Integer-factor decimation with a windowed-sinc low-pass. Returns the new rate too.
    static func decimate(_ x: [Double], sampleRate: Double, to target: Double) -> (signal: [Double], rate: Double) {
        let factor = max(1, Int((sampleRate / target).rounded()))
        if factor == 1 { return (x, sampleRate) }
        let taps = 16 * factor + 1, half = (taps - 1) / 2
        let cutoff = 0.45 / Double(factor)
        var h = [Double](repeating: 0, count: taps)
        var sum = 0.0
        for i in 0..<taps {
            let k = Double(i - half)
            let sinc = k == 0 ? 2 * cutoff : sin(2 * Double.pi * cutoff * k) / (Double.pi * k)
            h[i] = sinc * (0.54 - 0.46 * cos(2 * Double.pi * Double(i) / Double(taps - 1)))
            sum += h[i]
        }
        for i in 0..<taps { h[i] /= sum }
        let n = x.count / factor
        var out = [Double](repeating: 0, count: n)
        for o in 0..<n {
            let center = o * factor
            var acc = 0.0
            for i in 0..<taps {
                let j = center + i - half
                if j >= 0 && j < x.count { acc += h[i] * x[j] }
            }
            out[o] = acc
        }
        return (out, sampleRate / Double(factor))
    }

    /// Stretches control values spread evenly over `duration` onto the times `t`.
    static func resample(_ values: [Double], over duration: Double, at t: [Double]) -> [Double] {
        guard values.count > 1 else { return [Double](repeating: values.first ?? 0, count: t.count) }
        let grid = (0..<values.count).map { duration * Double($0) / Double(values.count - 1) }
        return interpolate(t, grid, values)
    }
}
