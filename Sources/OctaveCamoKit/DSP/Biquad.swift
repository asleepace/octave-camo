import Foundation

/// Direct-form I biquad with normalized coefficients (a0 = 1).
struct Biquad {
    let b0, b1, b2, a1, a2: Double

    /// RBJ cookbook notch.
    static func notch(frequency: Double, q: Double, sampleRate: Int) -> Biquad {
        let w = 2 * Double.pi * frequency / Double(sampleRate)
        let alpha = sin(w) / (2 * q)
        let cosW = cos(w)
        let a0 = 1 + alpha
        return Biquad(b0: 1 / a0, b1: -2 * cosW / a0, b2: 1 / a0,
                      a1: -2 * cosW / a0, a2: (1 - alpha) / a0)
    }

    func apply(_ x: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: x.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in x.indices {
            let xn = x[i]
            let yn = b0 * xn + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = xn
            y2 = y1; y1 = yn
            out[i] = yn
        }
        return out
    }

    /// Forward then backward: zero phase shift, squared magnitude response.
    func applyZeroPhase(_ x: [Double]) -> [Double] {
        Array(apply(Array(apply(x).reversed())).reversed())
    }
}
