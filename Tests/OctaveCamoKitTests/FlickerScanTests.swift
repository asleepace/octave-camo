import XCTest
@testable import OctaveCamoKit

/// Mirrors reference/video_flicker.py on synthetic row profiles.
final class FlickerScanTests: XCTestCase {
    private let fps = 30.0, strips = 6, rows = 120

    /// A panning scene (different structure in each column strip, drifting over time) plus,
    /// optionally, rolling-shutter flicker whose phase wanders like ENF.
    /// `wanderHz`: how far the grid frequency swings (real grids: a few hundredths of a hertz).
    private func profiles(seconds: Double = 20, flicker: Double? = nil, readout: Double = 0.5, depth: Double = 0.03,
                          wanderHz: Double = 0.05, seed: UInt64 = 3) -> FlickerScan.Profiles {
        let K = Int(seconds * fps)
        var rng = SeededRNG(seed: seed)
        // Per strip: a few random edges and bumps, panning slowly downward.
        struct Feature { var center: Double; var width: Double; var amplitude: Double }
        var features: [[Feature]] = []
        for _ in 0..<strips {
            var list: [Feature] = []
            for _ in 0..<6 {
                list.append(Feature(center: rng.uniform(0...1), width: rng.uniform(0.02...0.2), amplitude: rng.uniform(-0.3...0.3)))
            }
            features.append(list)
        }
        var values = [Double](repeating: 0, count: K * strips * rows)
        var times = [Double](repeating: 0, count: K)
        for k in 0..<K {
            let t = Double(k) / fps
            times[k] = t
            let pan = 0.004 * t + 0.01 * sin(2 * Double.pi * t / 7)
            let drift = wanderHz * 17 / (2 * Double.pi) * cos(2 * Double.pi * t / 17)   // ∫ δ dt, cycles
            for s in 0..<strips {
                for r in 0..<rows {
                    let u = Double(r) / Double(rows) + pan
                    var v = -0.8 + 0.2 * u
                    for f in features[s] {
                        let d = (u - f.center) / f.width
                        v += f.amplitude * exp(-d * d)
                    }
                    if let flicker {
                        let phase = flicker * (t + readout / fps * Double(r) / Double(rows)) - drift
                        v += depth * cos(2 * Double.pi * phase)
                    }
                    values[(k * strips + s) * rows + r] = v + 0.002 * rng.normal()
                }
            }
        }
        return FlickerScan.Profiles(frames: K, strips: strips, rows: rows, values: values, times: times)
    }

    /// At 30 fps, 120 Hz bands barely move: only their phase wander carries the clock, so this
    /// needs a strong wander to be found (a documented limit).
    func testFindsQuasiStatic120HzBandsThatWander() {
        let finding = FlickerScan().scan(profiles(flicker: 120, depth: 0.05, wanderHz: 0.15))
        XCTAssertTrue(finding.detected, "z \(finding.z)")
        XCTAssertEqual(finding.flicker, 120, accuracy: 0.6)
    }

    func testFindsRolling100HzBands() {
        let finding = FlickerScan().scan(profiles(flicker: 100, readout: 0.6))
        XCTAssertTrue(finding.detected, "z \(finding.z)")
        XCTAssertEqual(finding.flicker, 100, accuracy: 0.6)
    }

    func testCleanScenesAreNotFlagged() {
        for seed: UInt64 in [1, 2, 3] {
            let finding = FlickerScan().scan(profiles(seed: seed))
            XCTAssertFalse(finding.detected, "seed \(seed): z \(finding.z) at \(finding.flicker) Hz")
        }
    }

    func testCleaningRemovesTheBandsAndLeavesCleanVideoAlone() {
        let scan = FlickerScan()
        let cases: [(clip: FlickerScan.Profiles, ratio: Double)] = [
            (profiles(flicker: 100, readout: 0.6), 10),
            (profiles(flicker: 120, depth: 0.05, wanderHz: 0.15), 3),
        ]
        for (clip, ratio) in cases {
            let result = scan.clean(clip)
            let before = result.findings[0]
            XCTAssertTrue(before.detected)
            XCTAssertLessThan(result.after.z, before.z / ratio, "\(before.flicker) Hz: z \(before.z) → \(result.after.z)")
            // Gains stay within the depth cap.
            let logs = result.gains.map { abs(log($0)) }
            XCTAssertLessThanOrEqual(logs.max()!, scan.maxDepth * Double(scan.passes) + 1e-9)
        }
        let untouched = scan.clean(profiles())
        XCTAssertEqual(untouched.findings.count, 1)
        XCTAssertTrue(untouched.gains.allSatisfy { $0 == 1 })
    }

    func testLeastSquaresRecoversABandOnAGradient() {
        let R = 120, cycles = 1.7
        let solve = FlickerScan.leastSquares(rows: R, cycles: cycles)
        var coef = [Double](repeating: 0, count: 5)
        for r in 0..<R {
            let u = -1 + 2 * Double(r) / Double(R - 1), theta = 2 * Double.pi * cycles * Double(r) / Double(R)
            let y = 0.4 - 0.3 * u + 0.2 * u * u + 0.03 * cos(theta) - 0.02 * sin(theta)
            for i in 0..<5 { coef[i] += solve[i * R + r] * y }
        }
        for (got, want) in zip(coef, [0.4, -0.3, 0.2, 0.03, -0.02]) { XCTAssertEqual(got, want, accuracy: 1e-9) }
    }

    func testTrendBasisIsOrthonormalAndRemovesQuadratics() {
        let basis = FlickerScan.trendBasis(50)
        XCTAssertEqual(basis.count, 3)
        for a in 0..<3 {
            for b in 0..<3 {
                let dot = zip(basis[a], basis[b]).reduce(0) { $0 + $1.0 * $1.1 }
                XCTAssertEqual(dot, a == b ? 1 : 0, accuracy: 1e-9)
            }
        }
        var y = (0..<50).map { r -> Double in let u = -1 + 2 * Double(r) / 49; return 3 + 2 * u - 5 * u * u }
        FlickerScan.removeTrend(&y, basis)
        XCTAssertLessThan(y.map(abs).max()!, 1e-9)
    }
}
