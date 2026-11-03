import XCTest
@testable import OctaveCamoKit

/// The same synthetic clip as web/test/wasm.test.ts, so native and WebAssembly runs can be compared.
final class WebSmokeTests: XCTestCase {
    private func flybyClip() -> Audio {
        let sr = 16_000, n = sr * 40
        let c = 343.0, speed = 90.0, distance = 300.0, t0 = 20.0, f0 = 180.0
        var x = [Double](repeating: 0, count: n)
        var seed: UInt32 = 7
        func rand() -> Double {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Double(seed) / 4_294_967_296
        }
        var phase = 0.0
        for i in 0..<n {
            let t = Double(i) / Double(sr)
            let dx = speed * (t - t0), r = (dx * dx + distance * distance).squareRoot()
            phase += 2 * Double.pi * f0 / (1 + speed * dx / (r * c)) / Double(sr)
            let level = 0.08 * min(1, 300 / r)
            var s = 0.0
            for h in 1...3 { s += level / Double(h) * sin(Double(h) * phase) }
            s += 0.01 * sin(2 * Double.pi * 60 * t) + 0.005 * sin(2 * Double.pi * 120 * t)
            x[i] = s + 0.01 * (rand() + rand() + rand() - 1.5)
        }
        return Audio(sampleRate: sr, channels: [x])
    }

    func testAnalyzerFindsFlybyAndHum() {
        let analysis = FlybyAnalyzer().analyze(flybyClip())
        XCTAssertGreaterThan(analysis.flybys.count, 0)
        XCTAssertGreaterThan(analysis.hum.count, 0)
    }

    func testDefaultScrubRemovesThem() {
        var pipeline = ScrubPipeline()
        pipeline.lowband.seed = 42
        let out = pipeline.run(flybyClip()).audio
        let analysis = FlybyAnalyzer().analyze(out)
        XCTAssertEqual(analysis.flybys.count, 0)
        XCTAssertEqual(analysis.hum.count, 0)
    }
}
