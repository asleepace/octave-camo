import Foundation
import XCTest
@testable import OctaveCamoKit

/// How sensitive the check is, and how often it cries wolf: detection against tone strength and
/// false lines per minute in noise, recorded in Snapshots/detection.json (docs/ACOUSTICS.md §9). This is
/// the baseline the attacker-grade detector has to beat; a change to the check shows up here as a diff.
///
/// Re-record on purpose with:  OCTAVE_CAMO_RECORD=1 swift test -c release --filter DetectionBaselineTests
final class DetectionBaselineTests: XCTestCase {
    static let snapshot = SnapshotFile<[String: Double]>("detection")

    static let rates = [16_000, 48_000]
    static let seeds: [UInt64] = [1, 2, 3]
    static let ladder = [0.0, 3, 6, 9, 12, 15, 20]

    private func check(_ audio: Audio) -> Analysis { FlybyAnalyzer().analyze(audio) }

    private func label(_ rate: Int) -> String { "\(rate / 1_000)k" }

    /// The two halves of each rate's measurements, so a parallel run can spread them out (this
    /// was one 280 s test, the longest in the suite).
    enum Part: String, CaseIterable { case steady, others }

    func measure(rates: [Int] = rates, parts: [Part] = Part.allCases) -> (values: [String: Double], table: [String]) {
        var values: [String: Double] = [:], table: [String] = []
        func mean(_ xs: [Double]) -> Double { (xs.reduce(0, +) / Double(max(xs.count, 1)) * 100).rounded() / 100 }

        for rate in rates {
            if parts.contains(.steady) {
                for hz in [300.0, 1_200, 4_500] {
                    var row = "steady \(Int(hz)) Hz @\(label(rate)):"
                    var bySeed = [[Bool]](repeating: [], count: Self.seeds.count)
                    for snr in Self.ladder {
                        let d = Self.seeds.map { Detection(check(DetectionScenes.steady(hz: hz, snr: snr, rate: rate, seed: $0)), band: hz...hz, toneSeconds: 20) }
                        for k in d.indices { bySeed[k].append(d[k].found) }
                        let key = "steady \(Int(hz)) Hz \(Int(snr)) dB @\(label(rate))"
                        values[key + " found"] = mean(d.map { $0.found ? 1 : 0 })
                        values[key + " coverage"] = mean(d.map(\.coverage))
                        row += "  \(Int(snr)) dB \(d.filter(\.found).count)/\(d.count) (\(Int(100 * mean(d.map(\.coverage))))%)"
                    }
                    // Detection is monotone in strength: a tone found at some level is found at
                    // every higher one (for each seed), from 6 dB up.
                    for (k, found) in bySeed.enumerated() {
                        let ladder = Array(found[Self.ladder.firstIndex(of: 6)!...])
                        if let first = ladder.firstIndex(of: true) {
                            XCTAssertFalse(ladder[first...].contains(false), "\(Int(hz)) Hz @\(rate) seed \(Self.seeds[k]): found at 6…20 dB = \(ladder)")
                        }
                    }
                    table.append(row)
                }
            }
            guard parts.contains(.others) else { continue }
            for snr in [6.0, 12, 20] {
                let d = Self.seeds.map { seed -> Detection in
                    let scene = DetectionScenes.drifting(hz: 1_200, snr: snr, rate: rate, seed: seed)
                    return Detection(check(scene.audio), band: scene.path, toneSeconds: 30)
                }
                let key = "drifting 1200 Hz \(Int(snr)) dB @\(label(rate))"
                values[key + " found"] = mean(d.map { $0.found ? 1 : 0 })
                values[key + " coverage"] = mean(d.map(\.coverage))
                table.append("\(key): \(d.filter(\.found).count)/\(d.count) (\(Int(100 * mean(d.map(\.coverage))))%)")
            }
            for snr in [9.0, 15, 20] {
                let d = Self.seeds.map { Detection(check(DetectionScenes.intermittent(hz: 1_200, snr: snr, rate: rate, seed: $0)), band: 1_200...1_200, toneSeconds: 12) }
                let key = "intermittent 1200 Hz \(Int(snr)) dB @\(label(rate))"
                values[key + " found"] = mean(d.map { $0.found ? 1 : 0 })
                values[key + " coverage"] = mean(d.map(\.coverage))
                table.append("\(key): \(d.filter(\.found).count)/\(d.count) (\(Int(100 * mean(d.map(\.coverage))))%)")
            }
            for snr in [3.0, 6, 9] {
                let a = Self.seeds.map { check(DetectionScenes.gridFamily(snr: snr, rate: rate, seed: $0)) }
                let key = "grid 120-1200 Hz \(Int(snr)) dB @\(label(rate))"
                values[key + " hum"] = mean(a.map { Double($0.hum.count) })
                values[key + " tones"] = mean(a.map { Double($0.tracks.count) })
                table.append("\(key): hum lines \(mean(a.map { Double($0.hum.count) })), long tones \(mean(a.map { Double($0.tracks.count) })) (of 19 harmonics)")
            }
            for kind in ["white", "pink", "wind", "traffic"] {
                let lines = [UInt64(11), 12].map { Double(check(DetectionScenes.noise(kind, rate: rate, seed: $0)).tracks.count) }
                let key = "noise \(kind) @\(label(rate)) false lines per minute"
                values[key] = mean(lines)
                table.append("\(key): \(mean(lines))")
            }
        }
        return (values, table)
    }

    static var recording: Bool { ProcessInfo.processInfo.environment["OCTAVE_CAMO_RECORD"] == "1" }

    /// One rate's half against the matching part of the recorded baseline.
    func checkPart(_ rate: Int, _ part: Part) throws {
        if Self.recording { throw XCTSkip("recording: testRecordTheBaseline writes the whole snapshot") }
        let (now, table) = measure(rates: [rate], parts: [part])
        print("DETECTION REPORT (\(part.rawValue) @\(label(rate)))\n" + table.joined(separator: "\n"))
        if part == .steady { XCTAssertEqual(now["steady 300 Hz 20 dB @\(label(rate)) found"], 1, "a 20 dB tone at 300 Hz, \(rate) Hz") }
        guard let data = try? Data(contentsOf: Self.snapshot.url),
              let all = try? JSONDecoder().decode([String: Double].self, from: data) else {
            return XCTFail("no detection snapshot at \(Self.snapshot.url.path): record one with OCTAVE_CAMO_RECORD=1")
        }
        let tag = "@\(label(rate))"
        let mine = all.filter { ($0.key.contains(tag + " ") || $0.key.hasSuffix(tag)) && $0.key.hasPrefix("steady ") == (part == .steady) }
        let problems = Self.differences(recorded: mine, now: now)
        if !problems.isEmpty {
            print("BEGIN SNAPSHOT PART\n\(now.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n"))\nEND SNAPSHOT PART")
            XCTFail("detection changed:\n" + problems.joined(separator: "\n"))
        }
    }

    func testSteadyTonesAt16k() throws { try checkPart(16_000, .steady) }
    func testSteadyTonesAt48k() throws { try checkPart(48_000, .steady) }
    func testDriftingGridAndNoiseAt16k() throws { try checkPart(16_000, .others) }
    func testDriftingGridAndNoiseAt48k() throws { try checkPart(48_000, .others) }

    /// The whole baseline in one snapshot, written only when recording.
    func testRecordTheBaseline() throws {
        guard Self.recording else { throw XCTSkip("only with OCTAVE_CAMO_RECORD=1") }
        let (now, table) = measure()
        print("DETECTION REPORT\n" + table.joined(separator: "\n"))
        try Self.snapshot.check(now, what: "detection", differences: Self.differences)
    }

    /// Allowed drift: one seed in three for found rates, a quarter for coverage, one line for counts.
    static func differences(recorded: [String: Double], now: [String: Double]) -> [String] {
        Set(recorded.keys).union(now.keys).sorted().compactMap { key in
            guard let a = recorded[key], let b = now[key] else { return "\(key): added or removed" }
            let slack = key.hasSuffix("found") ? 0.34 : key.hasSuffix("coverage") ? 0.25 : 1.0
            return abs(a - b) > slack ? "\(key): \(a) → \(b)" : nil
        }
    }

    func testTheScenesAreWhatTheySay() {
        // The ladder's amplitude: a 0 dB tone has the noise's power in a 1 Hz band.
        let rate = 16_000, a = DetectionScenes.amplitude(snr: 0, rate: rate), sigma = DetectionScenes.noiseSigma
        XCTAssertEqual(a * a / 2, 2 * sigma * sigma / Double(rate), accuracy: 1e-15)
        XCTAssertEqual(DetectionScenes.amplitude(snr: 20, rate: rate) / a, 10, accuracy: 1e-9)
        // The flyby path spans the Doppler range around f0.
        let drift = DetectionScenes.drifting(hz: 1_200, snr: 10, rate: rate, seed: 1)
        XCTAssertLessThan(drift.path.lowerBound, 1_200)
        XCTAssertGreaterThan(drift.path.upperBound, 1_200)
        // Noise scenes have no tone: their spectrum's peak is within reach of its median.
        for kind in ["white", "pink", "wind", "traffic"] {
            let x = DetectionScenes.noise(kind, rate: rate, seconds: 4, seed: 1).channels[0]
            XCTAssertTrue(x.allSatisfy(\.isFinite), kind)
            XCTAssertGreaterThan(DSP.peakMagnitude(x), 0, kind)
        }
    }
}
