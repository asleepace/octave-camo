import Foundation

/// Iterative radix-2 complex FFT on split real/imaginary arrays.
/// Portable (no Accelerate) so the package builds on macOS, iOS and Linux.
/// On Apple platforms this is the one file to swap for vDSP if profiling says so.
final class FFT {
    let size: Int
    private let cosTable: [Double]
    private let sinTable: [Double]      // -sin, i.e. forward-transform twiddles
    private let bitReversed: [Int]

    init(size n: Int) {
        precondition(n >= 2 && n & (n - 1) == 0, "FFT size must be a power of two")
        size = n
        cosTable = (0..<(n / 2)).map { cos(2 * Double.pi * Double($0) / Double(n)) }
        sinTable = (0..<(n / 2)).map { -sin(2 * Double.pi * Double($0) / Double(n)) }
        let bits = n.trailingZeroBitCount
        bitReversed = (0..<n).map { i in
            var x = i, y = 0
            for _ in 0..<bits { y = (y << 1) | (x & 1); x >>= 1 }
            return y
        }
    }

    func forward(_ re: inout [Double], _ im: inout [Double]) { transform(&re, &im, inverse: false) }

    /// Inverse transform, scaled by 1/N (same convention as numpy.fft.ifft).
    func inverse(_ re: inout [Double], _ im: inout [Double]) { transform(&re, &im, inverse: true) }

    private func transform(_ reArray: inout [Double], _ imArray: inout [Double], inverse: Bool) {
        let n = size
        precondition(reArray.count == n && imArray.count == n, "FFT buffer size mismatch")
        reArray.withUnsafeMutableBufferPointer { re in
            imArray.withUnsafeMutableBufferPointer { im in
                for i in 0..<n {
                    let j = bitReversed[i]
                    if j > i { re.swapAt(i, j); im.swapAt(i, j) }
                }
                let sign = inverse ? -1.0 : 1.0
                var length = 2
                while length <= n {
                    let half = length / 2
                    let step = n / length
                    var start = 0
                    while start < n {
                        for k in 0..<half {
                            let wr = cosTable[k * step]
                            let wi = sign * sinTable[k * step]
                            let a = start + k, b = a + half
                            let tr = wr * re[b] - wi * im[b]
                            let ti = wr * im[b] + wi * re[b]
                            re[b] = re[a] - tr
                            im[b] = im[a] - ti
                            re[a] += tr
                            im[a] += ti
                        }
                        start += length
                    }
                    length <<= 1
                }
                if inverse {
                    let scale = 1 / Double(n)
                    for i in 0..<n { re[i] *= scale; im[i] *= scale }
                }
            }
        }
    }
}

/// Forward FFT of a real signal using one half-size complex FFT (about twice as fast).
/// Returns bins 0...N/2.
final class RealFFT {
    let size: Int
    private let half: FFT
    private let twiddleRe: [Double]     // e^{-2πik/N}, k = 0...N/2
    private let twiddleIm: [Double]
    private var scratchRe: [Double]
    private var scratchIm: [Double]

    init(size n: Int) {
        precondition(n >= 4 && n & (n - 1) == 0, "RealFFT size must be a power of two ≥ 4")
        size = n
        half = FFT(size: n / 2)
        twiddleRe = (0...(n / 2)).map { cos(2 * Double.pi * Double($0) / Double(n)) }
        twiddleIm = (0...(n / 2)).map { -sin(2 * Double.pi * Double($0) / Double(n)) }
        scratchRe = [Double](repeating: 0, count: n / 2)
        scratchIm = [Double](repeating: 0, count: n / 2)
    }

    var binCount: Int { size / 2 + 1 }

    /// `re`/`im` must hold `binCount` elements.
    func forward(_ x: [Double], _ re: inout [Double], _ im: inout [Double]) {
        let h = size / 2
        precondition(x.count == size && re.count == h + 1 && im.count == h + 1, "RealFFT buffer size mismatch")
        // Pack even samples as real, odd as imaginary, and transform at half size.
        for k in 0..<h {
            scratchRe[k] = x[2 * k]
            scratchIm[k] = x[2 * k + 1]
        }
        half.forward(&scratchRe, &scratchIm)
        // Unpack: X[k] = (Z[k] + Z*[h-k])/2 - i·W^k·(Z[k] - Z*[h-k])/2
        for k in 0...h {
            let zr = scratchRe[k % h], zi = scratchIm[k % h]
            let cr = scratchRe[(h - k) % h], ci = -scratchIm[(h - k) % h]
            let sumR = zr + cr, sumI = zi + ci
            let difR = zr - cr, difI = zi - ci
            let p = twiddleRe[k] * difR - twiddleIm[k] * difI
            let q = twiddleRe[k] * difI + twiddleIm[k] * difR
            re[k] = 0.5 * (sumR + q)
            im[k] = 0.5 * (sumI - p)
        }
    }
}
