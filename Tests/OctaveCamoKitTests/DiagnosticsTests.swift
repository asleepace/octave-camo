import Foundation
import XCTest
@testable import OctaveCamoKit

/// Temporary: prints findings for two open questions (no assertions). Remove once answered.
final class DiagnosticsTests: XCTestCase {
    private func describe(_ t: Track) -> String {
        String(format: "%.0f–%.0f Hz, %.1f–%.1f s", t.minFrequency, t.maxFrequency, t.times.first ?? 0, t.times.last ?? 0)
    }

    /// Why does the second fill pass on speech find more lines than the first?
    func testDiagnoseSpeechFillPasses() {
        let input = Scenes.make("speech", rate: 16_000)
        var stage = LineFill()
        stage.seed = 1
        let check = FlybyAnalyzer()
        var y = input.mono, rng = SeededRNG(seed: 1)
        var previous: [Track] = []
        for pass in 1...3 {
            let l = check.lines(in: Audio(sampleRate: 16_000, channels: [y]))
            let all = l.tracked + l.integrated
            for t in all {
                let near = previous.contains { p in
                    p.times.first! <= t.times.last! + 1 && t.times.first! <= p.times.last! + 1
                        && p.minFrequency - 25 <= t.maxFrequency && t.minFrequency <= p.maxFrequency + 25
                }
                print("diagnose speech pass \(pass): \(l.tracked.contains { $0.times == t.times } ? "tracker" : "integrator") \(describe(t))\(near ? " (near a line filled before)" : " (new)")")
            }
            if all.isEmpty { print("diagnose speech pass \(pass): nothing"); break }
            for t in all { _ = stage.fill(&y, t, sampleRate: 16_000, rng: &rng) }
            previous += all
        }
    }

    /// Which stage of Full removes the modelled jet fan tone (1.7 → 0.9 kHz)?
    func testDiagnoseWhichStageRemovesTheFanTone() {
        let input = LineFillTests.fanTone(rate: 16_000), check = FlybyAnalyzer()
        let count = { (a: Audio) in check.analyze(a).tracks.filter { $0.maxFrequency >= 1_000 && $0.minFrequency <= 1_800 } }
        print("diagnose fan: input \(count(input).map { "\($0.kind) \(Int($0.minFrequency))–\(Int($0.maxFrequency)) Hz \(String(format: "%.0f", $0.duration)) s" })")
        let sets: [(String, Set<ScrubStep>)] = [("hum", [.mono, .hum]), ("subtract", [.mono, .subtract]), ("scurve", [.mono, .scurve]),
                                               ("lowband", [.mono, .lowband]), ("full", ScrubPipeline.defaultSteps)]
        for (name, steps) in sets {
            let r = seededPipeline(steps, seed: 3).run(input)
            let left = count(r.audio)
            print("diagnose fan: \(name) only → \(left.count) line(s) in 1–1.8 kHz \(left.map { "\($0.kind) \(Int($0.minFrequency))–\(Int($0.maxFrequency)) Hz \(String(format: "%.0f", $0.duration)) s" }); \(r.log.dropFirst().joined(separator: " | "))")
        }
    }
}
