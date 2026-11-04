/// STFT editing of one band of one stretch of a signal: analyze bins lo..<hi of `x` (Hann analysis
/// and synthesis, 75 % overlap), let the caller rewrite them, and get back the change to add to `x`.
/// Only the band is stored, so a line a few Hz wide costs memory for its stretch and band alone.
/// Untouched bins add nothing: the change is ISTFT(new − old).
struct BandSTFT {
    let size: Int
    let hop: Int
    let lo: Int
    let hi: Int
    let frames: Int
    /// frames × (hi − lo), row-major.
    let re: [Double]
    let im: [Double]
    let count: Int

    private let window: [Double]
    private let pad: Int

    var width: Int { hi - lo }

    init(_ x: ArraySlice<Double>, size: Int, hop: Int, lo: Int, hi: Int) {
        precondition(0 <= lo && lo < hi && hi <= size / 2, "band must lie within 0...size/2")
        self.size = size
        self.hop = hop
        self.lo = lo
        self.hi = hi
        count = x.count
        pad = size
        let window = DSP.hann(size)
        self.window = window
        let frames = (x.count + size) / hop + 1
        self.frames = frames
        let width = hi - lo, base = x.startIndex

        let fft = RealFFT(size: size)
        var frame = [Double](repeating: 0, count: size)
        var fr = [Double](repeating: 0, count: fft.binCount)
        var fi = [Double](repeating: 0, count: fft.binCount)
        var re = [Double](repeating: 0, count: frames * width)
        var im = [Double](repeating: 0, count: frames * width)
        for m in 0..<frames {
            let start = m * hop - size
            for i in 0..<size {
                let j = start + i
                frame[i] = j >= 0 && j < x.count ? x[base + j] * window[i] : 0
            }
            fft.forward(frame, &fr, &fi)
            for k in 0..<width {
                re[m * width + k] = fr[lo + k]
                im[m * width + k] = fi[lo + k]
            }
        }
        self.re = re
        self.im = im
    }

    /// Mean of window²: power scale of a random-phase frame relative to a windowed one.
    var windowPower: Double { window.reduce(0) { $0 + $1 * $1 } / Double(size) }
    /// Average Σw² overlap per output sample.
    var overlapPower: Double { Double(size) * windowPower / Double(hop) }
    /// Frame center, in samples from the stretch's start.
    func center(of frame: Int) -> Int { frame * hop - pad + size / 2 }

    /// ISTFT(new − old), one value per sample of the stretch.
    func change(re newRe: [Double], im newIm: [Double]) -> [Double] {
        let fft = FFT(size: size), width = hi - lo
        let total = count + 2 * pad
        var acc = [Double](repeating: 0, count: total)
        var norm = [Double](repeating: 0, count: total)
        var dr = [Double](repeating: 0, count: size)
        var di = [Double](repeating: 0, count: size)
        for m in 0..<frames {
            let start = m * hop
            for i in 0..<size where start + i < total { norm[start + i] += window[i] * window[i] }
            var changed = false
            for i in 0..<size { dr[i] = 0; di[i] = 0 }
            for k in 0..<width {
                let a = newRe[m * width + k] - re[m * width + k], b = newIm[m * width + k] - im[m * width + k]
                if a == 0 && b == 0 { continue }
                changed = true
                let bin = lo + k
                dr[bin] = a; di[bin] = b
                if bin > 0 && bin < size / 2 { dr[size - bin] = a; di[size - bin] = -b }   // Hermitian: real output
            }
            if !changed { continue }
            fft.inverse(&dr, &di)
            for i in 0..<size where start + i < total { acc[start + i] += dr[i] * window[i] }
        }
        var out = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let n = norm[i + pad]
            if n > 1e-9 { out[i] = acc[i + pad] / n }
        }
        return out
    }
}
