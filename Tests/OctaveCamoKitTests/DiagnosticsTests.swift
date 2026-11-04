import Foundation
import XCTest
@testable import OctaveCamoKit

/// Prints how loud a jet's fan tone (sweeping 1.7 → 0.9 kHz) must be for the check to see it above
/// 1 kHz. No assertions: a measurement for ACOUSTICS.md (drifting tones up there are a known gap).
final class DiagnosticsTests: XCTestCase {
    func testFanToneSensitivityAboveOneKilohertz() {
        let check = FlybyAnalyzer()
        for snr in [20.0, 25, 30, 35, 40] {
            let input = LineFillTests.fanTone(rate: 16_000, snr: snr)
            let high = check.analyze(input).tracks.filter { $0.maxFrequency >= 1_100 && $0.minFrequency <= 1_700 }
            let desc = high.map { "\($0.kind) \(Int($0.minFrequency))–\(Int($0.maxFrequency)) Hz \(String(format: "%.0f", $0.duration)) s" }
            print("diagnose fan sensitivity: \(Int(snr)) dB (1 Hz band) → \(high.count) line(s) in 1.1–1.7 kHz \(desc)")
        }
    }
}
