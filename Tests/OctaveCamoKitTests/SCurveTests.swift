import XCTest
@testable import OctaveCamoKit

/// Mirrors the harness's scurve tests (harness/test/defense.test.ts).
final class SCurveTests: XCTestCase {
    private let sr = 8_000

    private func noise(_ n: Int, rms: Double, seed: UInt64) -> [Double] {
        var rng = SeededRNG(seed: seed)
        return rng.normals(n).map { $0 * rms }
    }

    /// Instantaneous frequency per sample for a straight pass (f0 at speed, distance, t0).
    private func flybyFrequency(f0: Double, speed: Double, distance: Double, t0: Double, n: Int) -> [Double] {
        let times = (0..<n).map { Double($0) / Double(sr) }
        return FlybyGeometry(f0: f0, speed: speed, t0: t0, distance: distance).received(at: times).frequency
    }

    private func toneAmplitude(_ x: [Double], _ freq: [Double]) -> Double {
        var phase = 0.0, s = 0.0, c = 0.0
        for i in x.indices {
            phase += 2 * Double.pi * freq[i] / Double(sr)
            s += x[i] * sin(phase); c += x[i] * cos(phase)
        }
        return 2 * (s * s + c * c).squareRoot() / Double(x.count)
    }

    private func rms(_ x: [Double]) -> Double { (x.reduce(0) { $0 + $1 * $1 } / Double(x.count)).squareRoot() }
    private func db(_ a: Double, _ b: Double) -> Double { 20 * log10(a / b) }

    func testFindsAndCancelsAFaintFlybyBuriedInNoise() {
        let n = sr * 60
        let freq = flybyFrequency(f0: 110, speed: 120, distance: 4_000, t0: 30, n: n)
        var x = noise(n, rms: 0.1, seed: 3)
        var phase = 0.0
        for i in 0..<n {
            phase += 2 * Double.pi * freq[i] / Double(sr)
            x[i] += 0.012 * sin(phase)   // ≈ -21 dB re the noise: invisible frame by frame
        }
        let (y, summary) = SCurveCancel().process(x, sampleRate: sr)
        XCTAssertLessThan(db(toneAmplitude(y, freq), toneAmplitude(x, freq)), -12, summary)
    }

    func testOnPureNoiseOverCancellingChangesAlmostNothing() {
        let x = noise(sr * 60, rms: 0.1, seed: 9)
        let y = SCurveCancel().process(x, sampleRate: sr).output
        XCTAssertLessThan(abs(db(rms(y), rms(x))), 0.3)
    }

    func testShortClipsPassThrough() {
        let x = noise(sr * 4, rms: 0.1, seed: 1)
        XCTAssertEqual(SCurveCancel().process(x, sampleRate: sr).output, x)
    }
}
