import Foundation
import XCTest
@testable import OctaveCamoKit

final class DSPTests: XCTestCase {
    private func naiveDFT(_ re: [Double], _ im: [Double]) -> ([Double], [Double]) {
        let n = re.count
        var outRe = [Double](repeating: 0, count: n), outIm = outRe
        for k in 0..<n {
            for j in 0..<n {
                let a = -2 * Double.pi * Double(j * k) / Double(n)
                outRe[k] += re[j] * cos(a) - im[j] * sin(a)
                outIm[k] += re[j] * sin(a) + im[j] * cos(a)
            }
        }
        return (outRe, outIm)
    }

    func testFFTMatchesNaiveDFT() {
        var rng = SeededRNG(seed: 3)
        let x = rng.normals(64), y = rng.normals(64)
        var re = x, im = y
        FFT(size: 64).forward(&re, &im)
        let (expRe, expIm) = naiveDFT(x, y)
        for k in 0..<64 {
            XCTAssertEqual(re[k], expRe[k], accuracy: 1e-9)
            XCTAssertEqual(im[k], expIm[k], accuracy: 1e-9)
        }
    }

    func testInverseFFTRoundTrips() {
        var rng = SeededRNG(seed: 4)
        let x = rng.normals(256), y = rng.normals(256)
        var re = x, im = y
        let fft = FFT(size: 256)
        fft.forward(&re, &im)
        fft.inverse(&re, &im)
        for i in 0..<256 {
            XCTAssertEqual(re[i], x[i], accuracy: 1e-12)
            XCTAssertEqual(im[i], y[i], accuracy: 1e-12)
        }
    }

    func testRealFFTMatchesComplexFFT() {
        var rng = SeededRNG(seed: 5)
        let x = rng.normals(1024)
        var re = x, im = [Double](repeating: 0, count: 1024)
        FFT(size: 1024).forward(&re, &im)

        let rfft = RealFFT(size: 1024)
        var rRe = [Double](repeating: 0, count: rfft.binCount), rIm = rRe
        rfft.forward(x, &rRe, &rIm)
        for k in 0..<rfft.binCount {
            XCTAssertEqual(rRe[k], re[k], accuracy: 1e-9)
            XCTAssertEqual(rIm[k], im[k], accuracy: 1e-9)
        }
    }

    func testMovingAverageMatchesNaiveSameConvolution() {
        let a = (0..<20).map { Double($0 * $0 % 7) }
        for length in [2, 5, 6] {
            let got = DSP.movingAverage(a, length: length)
            let h = (length - 1) / 2
            for i in a.indices {
                var sum = 0.0
                for j in (i - (length - 1) + h)...(i + h) where a.indices.contains(j) { sum += a[j] }
                XCTAssertEqual(got[i], sum / Double(length), accuracy: 1e-12, "length \(length), i \(i)")
            }
        }
    }

    func testInterpolateClampsAndInterpolates() {
        let got = DSP.interpolate([-1, 0, 0.5, 1.5, 3], [0, 1, 2], [10, 20, 40])
        XCTAssertEqual(got, [10, 10, 15, 30, 40])
    }

    func testGradientIsExactForQuadraticOnUnevenGrid() {
        let t = [0.0, 0.5, 1.5, 2.0, 3.5]
        let g = DSP.gradient(t.map { $0 * $0 }, t)
        for i in 1..<(t.count - 1) { XCTAssertEqual(g[i], 2 * t[i], accuracy: 1e-12) }
    }

    func testCumulativePhaseOfConstantFrequency() {
        let phase = DSP.cumulativePhase([Double](repeating: 10, count: 100), dt: 0.01)
        XCTAssertEqual(phase.last!, 2 * Double.pi * 10, accuracy: 1e-9)   // 10 Hz for 1 s
    }

    func testZeroPhaseNotchRemovesToneAndKeepsOthers() {
        let sr = 48_000
        // 4 s so the Q = 30 filter's start-up and end transients (~0.16 s) stay out of the window.
        let t = (0..<(4 * sr)).map { Double($0) / Double(sr) }
        let hum = t.map { sin(2 * Double.pi * 60 * $0) }
        let voice = t.map { sin(2 * Double.pi * 1_000 * $0) }
        let notch = Biquad.notch(frequency: 60, q: 30, sampleRate: sr)

        func rms(_ x: [Double]) -> Double { DSP.standardDeviation(Array(x[sr..<(3 * sr)])) }
        XCTAssertLessThan(rms(notch.applyZeroPhase(hum)) / rms(hum), 0.01)          // > 40 dB down
        XCTAssertEqual(rms(notch.applyZeroPhase(voice)) / rms(voice), 1, accuracy: 0.001)
    }
}
