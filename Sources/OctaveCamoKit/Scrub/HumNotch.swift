#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WASILibc)
import WASILibc
#endif

/// Narrow zero-phase notches at mains harmonics. Removes the electrical-network-frequency
/// fluctuations that can timestamp a recording against grid logs.
///
/// Both 50 and 60 Hz families are notched by default, and each notch is refilled with a narrow
/// band of noise at the neighbouring bands' long-term level. Notching only the local grid, or
/// leaving holes, would say which grid (and so which part of the world) the recording came from.
/// The refill is independent noise at a constant level: it carries none of the grid's drift, and
/// (unlike a level that followed the neighbours over time) no trace of when a moving tone swept
/// past the notch, which is the timing a matched attacker integrates.
public struct HumNotch: ScrubStage {
    var step: ScrubStep { .hum }

    /// Mains frequencies whose harmonics are notched (60 Hz in the Americas, 50 Hz in most of the
    /// rest of the world). Empty disables the stage.
    public var mains: [Double] = [50, 60]
    /// Harmonics are notched below this frequency.
    public var maxFrequency = 400.0
    public var q = 30.0
    /// Refill each notch with noise at the neighbouring bands' level (no dips left behind).
    public var refill = true
    public var seed: UInt64 = .random(in: 1...UInt64.max)

    public init() {}

    /// Notch frequencies: every harmonic of every mains frequency below `maxFrequency`, shared
    /// harmonics (300 Hz) once, ascending.
    var harmonics: [Double] {
        var out: [Double] = []
        for base in mains where base > 0 {
            for f in stride(from: base, to: maxFrequency, by: base) where !out.contains(where: { abs($0 - f) < 0.5 }) {
                out.append(f)
            }
        }
        return out.sorted()
    }

    public func process(_ x: [Double], sampleRate: Int) -> (output: [Double], summary: String) {
        let freqs = harmonics
        var y = freqs.reduce(x) { signal, f in
            Biquad.notch(frequency: f, q: q, sampleRate: sampleRate).applyZeroPhase(signal)
        }
        if refill && !freqs.isEmpty { y = refilled(y, freqs, sampleRate: sampleRate) }
        let families = mains.filter { $0 > 0 }.map { String(Int($0)) }.joined(separator: " and ")
        let what = refill ? "notched and refilled" : "notched"
        return (y, "hum: \(what) \(freqs.count) harmonics of \(families.isEmpty ? "nothing" : families + " Hz")")
    }

    /// Adds, for each notch, a narrow band of noise (white noise minus its own notch) at the median
    /// level of the notched signal's bands two bandwidths either side.
    func refilled(_ y: [Double], _ freqs: [Double], sampleRate: Int) -> [Double] {
        let n = y.count
        let length = max(1, Int((0.25 * Double(sampleRate)).rounded()))
        var rng = SeededRNG(seed: seed ^ 0x5eed)
        let white = rng.normals(n)
        var out = y
        for f in freqs {
            let bandwidth = f / q
            var sides: [Double] = []
            for g in [f - 2 * bandwidth, f + 2 * bandwidth] where g > 0 {
                if !freqs.contains(where: { abs($0 - g) < 1.5 * $0 / q }) { sides.append(g) }
            }
            if sides.isEmpty { continue }
            var level = 0.0
            for g in sides {
                let notched = Biquad.notch(frequency: g, q: q, sampleRate: sampleRate).applyZeroPhase(y)
                var band = [Double](repeating: 0, count: n)
                for i in 0..<n { band[i] = y[i] - notched[i] }
                let e = Self.envelope(band, length: length)
                var powers: [Double] = []
                var i = 0
                while i < n { powers.append(e[i] * e[i]); i += length }
                level += DSP.median(powers[...]) * (f / g) / Double(sides.count)   // bandwidth grows with f
            }
            let whiteNotched = Biquad.notch(frequency: f, q: q, sampleRate: sampleRate).applyZeroPhase(white)
            var fill = [Double](repeating: 0, count: n)
            var own = 0.0
            for i in 0..<n { fill[i] = white[i] - whiteNotched[i]; own += fill[i] * fill[i] }
            let gain = (level / max(own / Double(n), 1e-30)).squareRoot()
            for i in 0..<n { out[i] += fill[i] * gain }
        }
        return out
    }

    /// Centered moving RMS (edges average over the samples present).
    static func envelope(_ x: [Double], length: Int) -> [Double] {
        let n = x.count, h = length / 2
        var prefix = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + x[i] * x[i] }
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let lo = max(0, i - h), hi = min(n - 1, i + h)
            out[i] = ((prefix[hi + 1] - prefix[lo]) / Double(hi - lo + 1)).squareRoot()
        }
        return out
    }
}
