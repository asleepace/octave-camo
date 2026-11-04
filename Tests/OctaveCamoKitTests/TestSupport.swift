import Foundation
import XCTest
@testable import OctaveCamoKit

/// The default pipeline with every seeded stage on one seed, so runs are reproducible.
func seededPipeline(_ steps: Set<ScrubStep> = ScrubPipeline.defaultSteps, seed: UInt64) -> ScrubPipeline {
    var p = ScrubPipeline()
    p.steps = steps
    p.hum.seed = seed
    p.lowband.seed = seed
    p.wobble.seed = seed
    p.lines.seed = seed
    return p
}

/// The default cloak's output for `audio`, with a fixed seed.
func cloaked(_ audio: Audio, seed: UInt64) -> Audio { seededPipeline(seed: seed).run(audio).audio }

/// A recorded JSON snapshot next to the tests (Snapshots/<name>.json), compared on every run.
///
/// With OCTAVE_CAMO_RECORD=1 the current values are written instead. A run that has no snapshot,
/// or differs beyond the caller's tolerances, fails and prints the new snapshot between
/// BEGIN/END SNAPSHOT lines, so it can be copied from a CI log.
struct SnapshotFile<Value: Codable> {
    let url: URL

    init(_ name: String, file: StaticString = #filePath) {
        url = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
            .appendingPathComponent("Snapshots").appendingPathComponent("\(name).json")
    }

    /// Compares `now` with the recording; `differences` lists what moved beyond its tolerances.
    func check(_ now: Value, what: String, differences: (_ recorded: Value, _ now: Value) -> [String],
               file: StaticString = #filePath, line: UInt = #line) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = String(decoding: try encoder.encode(now), as: UTF8.self)
        if ProcessInfo.processInfo.environment["OCTAVE_CAMO_RECORD"] == "1" {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (json + "\n").write(to: url, atomically: true, encoding: .utf8)
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            print("BEGIN SNAPSHOT\n\(json)\nEND SNAPSHOT")
            return XCTFail("no \(what) snapshot at \(url.path): record one with OCTAVE_CAMO_RECORD=1", file: file, line: line)
        }
        let problems = differences(try JSONDecoder().decode(Value.self, from: data), now)
        if !problems.isEmpty {
            print("BEGIN SNAPSHOT\n\(json)\nEND SNAPSHOT")
            XCTFail("\(what) changed:\n" + problems.joined(separator: "\n"), file: file, line: line)
        }
    }
}
