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

    /// Why didn't the voice rule keep the speech scene's lines? Pitch-track stats and, per line, the
    /// share of its frames on a harmonic of the tracked pitch.
    func testVoiceRuleOnSpeech() {
        let input = Scenes.make("speech", rate: 16_000), y = input.mono
        let stage = LineFill(), step = 0.02
        let times = Array(stride(from: 0.0, to: Double(y.count) / 16_000, by: step))
        let f0 = stage.pitch.track(y, sampleRate: 16_000, at: times)
        let voiced = f0.filter { $0 > 0 }
        print("diagnose voice: \(voiced.count)/\(f0.count) frames voiced, median f0 \(voiced.isEmpty ? 0 : DSP.median(voiced[...]))")
        var low = LowBandRegeneration()
        low.seed = 1
        print("diagnose voice: \(low.process(y, sampleRate: 16_000).summary)")
        let l = FlybyAnalyzer().lines(in: input), isVoice = stage.voiceTest(y, sampleRate: 16_000)
        for line in l.tracked + l.integrated {
            print("diagnose voice: line \(Int(line.minFrequency))–\(Int(line.maxFrequency)) Hz, \(String(format: "%.1f", line.times.first ?? 0))–\(String(format: "%.1f", line.times.last ?? 0)) s: voice \(isVoice(line))")
        }
    }
}
