import Foundation
import XCTest
@testable import OctaveCamoKit

/// How sensitive the check is, and how often it cries wolf: detection against tone strength and
/// false lines per minute in noise, recorded in Snapshots/detection.json (ACOUSTICS.md §9). This is
/// the baseline the attacker-grade detector has to beat; a change to the check shows up here as a diff.
///
/// Re-record on purpose with:  OCTAVE_CAMO_RECORD=1 swift test -c release --filter DetectionBaselineTests
final class DetectionBaselineTests: XCTestCase {
    static let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Snapshots").appendingPathComponent("detection.json")

    static let rates = [16_000, 48_000]
    static let seeds: [UInt64] = [1, 2, 3]
    static let ladder = [0.0, 3, 6, 9, 12, 15, 20]

    private func check(_ audio: Audio) -> Analysis { FlybyAnalyzer().analyze(audio) }

    private func label(_ rate: Int) -> String { "\(rate / 1_000)k" }

    func measure() -> (values: [String: Double], table: [String]) {
        var values: [String: Double] = [:], table: [String] = []
        func mean(_ xs: [Double]) -> Double { (xs.reduce(0, +) / Double(max(xs.count, 1)) * 100).rounded() / 100 }

        for rate in Self.rates {
            for hz in [300.0, 1_200, 4_500] {
                var row = "steady \(Int(hz)) Hz @\(label(rate)):"
                for snr in Self.ladder {
                    let d = Self.seeds.map { Detection(check(DetectionScenes.steady(hz: hz, snr: snr, rate: rate, seed: $0)), band: hz...hz, toneSeconds: 20) }
                    let key = "steady \(Int(hz)) Hz \(Int(snr)) dB @\(label(rate))"
                    values[key + " found"] = mean(d.map { $0.found ? 1 : 0 })
                    values[key + " coverage"] = mean(d.map(\.coverage))
                    row += "  \(Int(snr)) dB \(d.filter(\.found).count)/\(d.count) (\(Int(100 * mean(d.map(\.coverage))))%)"
                }
                table.append(row)
            }
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

    func testDetectionMatchesTheBaseline() throws {
        let (now, table) = measure()
        print("DETECTION REPORT\n" + table.joined(separator: "\n"))

        // Sanity, whatever the baseline: a clear low tone is found.
        for rate in Self.rates { XCTAssertEqual(now["steady 300 Hz 20 dB @\(label(rate)) found"], 1, "a 20 dB tone at 300 Hz, \(rate) Hz") }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = String(decoding: try encoder.encode(now), as: UTF8.self)
        if ProcessInfo.processInfo.environment["OCTAVE_CAMO_RECORD"] == "1" {
            try FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (json + "\n").write(to: Self.file, atomically: true, encoding: .utf8)
            return
        }
        guard let data = try? Data(contentsOf: Self.file) else {
            print("BEGIN SNAPSHOT\n\(json)\nEND SNAPSHOT")
            return XCTFail("no detection baseline at \(Self.file.path): record one (see the top of this file)")
        }
        let recorded = try JSONDecoder().decode([String: Double].self, from: data)
        let problems = Self.differences(recorded: recorded, now: now)
        if !problems.isEmpty {
            print("BEGIN SNAPSHOT\n\(json)\nEND SNAPSHOT")
            XCTFail("detection changed:\n" + problems.joined(separator: "\n"))
        }
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
