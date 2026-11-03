#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WASILibc)
import WASILibc
#endif

/// Low-band STFT editing: analyze only bins 0..<bins (Hann analysis and synthesis, 75 % overlap),
/// let the caller rewrite them, and add the change back. Untouched bins reconstruct exactly,
/// because the output is x + ISTFT(new − old).
struct LowBandSTFT {
    let size: Int
    let hop: Int
    let bins: Int
    let frames: Int
    /// frames × bins, row-major.
    let re: [Double]
    let im: [Double]

    private let x: [Double]
    private let window: [Double]
    private let pad: Int

    init(_ x: [Double], size: Int, hop: Int, bins: Int) {
        precondition(bins <= size / 2, "bins must not exceed size/2")
        self.x = x
        self.size = size
        self.hop = hop
        self.bins = bins
        pad = size
        let window = DSP.hann(size)
        self.window = window
        let frames = (x.count + 2 * size - size) / hop + 1
        self.frames = frames

        let fft = RealFFT(size: size)
        var frame = [Double](repeating: 0, count: size)
        var fr = [Double](repeating: 0, count: fft.binCount)
        var fi = [Double](repeating: 0, count: fft.binCount)
        var re = [Double](repeating: 0, count: frames * bins)
        var im = [Double](repeating: 0, count: frames * bins)
        for m in 0..<frames {
            let start = m * hop - size
            for i in 0..<size {
                let j = start + i
                frame[i] = j >= 0 && j < x.count ? x[j] * window[i] : 0
            }
            fft.forward(frame, &fr, &fi)
            for k in 0..<bins {
                re[m * bins + k] = fr[k]
                im[m * bins + k] = fi[k]
            }
        }
        self.re = re
        self.im = im
    }

    /// Mean of window²: power scale of a random-phase frame relative to a windowed one.
    var windowPower: Double { window.reduce(0) { $0 + $1 * $1 } / Double(size) }
    /// Average Σw² overlap per output sample.
    var overlapPower: Double { Double(size) * windowPower / Double(hop) }
    /// Frame center time in seconds of the original signal.
    func centerTime(of frame: Int, sampleRate: Int) -> Double {
        Double(frame * hop - pad + size / 2) / Double(sampleRate)
    }

    /// x + ISTFT(newBins − originalBins).
    func render(re newRe: [Double], im newIm: [Double]) -> [Double] {
        let fft = FFT(size: size)
        let total = x.count + 2 * pad
        var acc = [Double](repeating: 0, count: total)
        var norm = [Double](repeating: 0, count: total)
        var dr = [Double](repeating: 0, count: size)
        var di = [Double](repeating: 0, count: size)
        for m in 0..<frames {
            for i in 0..<size { dr[i] = 0; di[i] = 0 }
            var changed = false
            for k in 0..<bins {
                let a = newRe[m * bins + k] - re[m * bins + k]
                let b = newIm[m * bins + k] - im[m * bins + k]
                if a == 0 && b == 0 { continue }
                changed = true
                dr[k] = a; di[k] = b
                if k > 0 { dr[size - k] = a; di[size - k] = -b }   // Hermitian: real output
            }
            let start = m * hop
            for i in 0..<size { norm[start + i] += window[i] * window[i] }
            if !changed { continue }
            fft.inverse(&dr, &di)
            for i in 0..<size { acc[start + i] += dr[i] * window[i] }
        }
        var out = x
        for i in 0..<out.count {
            let n = norm[i + pad]
            if n > 1e-9 { out[i] += acc[i + pad] / n }
        }
        return out
    }
}

/// Equivalent rectangular bandwidth scale (Glasberg & Moore 1990): how wide a listener's
/// critical band is at each frequency.
public enum ERB {
    public static func bandwidth(_ f: Double) -> Double { 24.7 * (4.37 * f / 1000 + 1) }
    public static func number(_ f: Double) -> Double { 21.4 * log10(1 + 0.00437 * f) }
    public static func frequency(_ e: Double) -> Double { (pow(10, e / 21.4) - 1) / 0.00437 }

    /// Band edges 1 ERB apart between lo and hi (both ends included).
    public static func bands(from lo: Double, to hi: Double) -> [Double] {
        var edges: [Double] = []
        var e = number(lo)
        while e < number(hi) {
            edges.append(frequency(e))
            e += 1
        }
        edges.append(hi)
        return edges
    }
}
