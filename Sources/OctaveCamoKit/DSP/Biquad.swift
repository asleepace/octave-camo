#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WASILibc)
import WASILibc
#endif

/// Direct-form I biquad with normalized coefficients (a0 = 1).
struct Biquad {
    let b0, b1, b2, a1, a2: Double

    /// RBJ cookbook notch.
    static func notch(frequency: Double, q: Double, sampleRate: Int) -> Biquad {
        precondition(frequency > 0 && frequency < Double(sampleRate) / 2 && q > 0, "notch must sit between 0 and Nyquist")
        let w = 2 * Double.pi * frequency / Double(sampleRate)
        let alpha = sin(w) / (2 * q)
        let cosW = cos(w)
        let a0 = 1 + alpha
        return Biquad(b0: 1 / a0, b1: -2 * cosW / a0, b2: 1 / a0,
                      a1: -2 * cosW / a0, a2: (1 - alpha) / a0)
    }

    /// Samples for the filter's ringing to decay by 60 dB (pole radius √a2).
    var settleSamples: Int {
        guard a2 > 0, a2 < 1 else { return 0 }
        return Int((log(1e-3) / log(a2.squareRoot())).rounded(.up))
    }

    func apply(_ x: [Double]) -> [Double] {
        var out = x
        out.withUnsafeMutableBufferPointer { run($0, from: 0, to: $0.count) }
        return out
    }

    /// Filters in place from a cold start: indices `from..<to` ascending when `from <= to`,
    /// otherwise `from-1` down to `to`.
    private func run(_ y: UnsafeMutableBufferPointer<Double>, from: Int, to: Int) {
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        let step = from <= to ? 1 : -1
        var i = from <= to ? from : from - 1
        let end = from <= to ? to : to - 1
        while i != end {
            let xn = y[i]
            let yn = b0 * xn + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = xn
            y2 = y1; y1 = yn
            y[i] = yn
            i += step
        }
    }

    /// Forward then backward: zero phase shift, squared magnitude response.
    ///
    /// A pass that starts cold lets the notched frequency through until it settles, so plain
    /// forward-backward filtering leaves the tone in the first and last few hundred milliseconds
    /// (a mains line that survives at the clip's edges says which grid it came from). So near
    /// each edge, where one direction starts cold, both passes instead run toward the edge from
    /// inside the clip, already settled, and cross-fade into the zero-phase result. Those edge
    /// passes shift phase near the notch frequency only, which they remove anyway.
    func applyZeroPhase(_ x: [Double]) -> [Double] {
        let n = x.count
        var mid = x
        mid.withUnsafeMutableBufferPointer { y in
            run(y, from: 0, to: n)
            run(y, from: n, to: 0)
        }
        let L = min(settleSamples, n / 4)
        guard L >= 8 else { return mid }

        // Left edge: two backward passes over x[0..<4L] (settled below 3L), cross-fade over [L, 2L).
        var left = Array(x[0..<(4 * L)])
        left.withUnsafeMutableBufferPointer { y in
            run(y, from: 4 * L, to: 0)
            run(y, from: 4 * L, to: 0)
        }
        // Right edge: two forward passes over x[n-4L..<n], cross-fade over [n-2L, n-L).
        var right = Array(x[(n - 4 * L)..<n])
        right.withUnsafeMutableBufferPointer { y in
            run(y, from: 0, to: 4 * L)
            run(y, from: 0, to: 4 * L)
        }
        for i in 0..<(2 * L) {
            let w = i < L ? 1.0 : 0.5 + 0.5 * cos(Double.pi * Double(i - L) / Double(L))   // 1 → 0
            mid[i] = w * left[i] + (1 - w) * mid[i]
            let j = n - 1 - i
            mid[j] = w * right[4 * L - 1 - i] + (1 - w) * mid[j]
        }
        return mid
    }
}
