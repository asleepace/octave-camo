import Foundation
import XCTest
@testable import OctaveCamoKit

/// What the default cloak does to each scene in `Scenes`: the attacker's counts before and after,
/// how much of the sound above the low band is kept, and the level change per octave. Recorded in
/// Snapshots/behavior.json; a change beyond the tolerances fails, so tuning a stage shows what it
/// did to every scene (a held note, a whistle, birdsong) and not only to planes.
///
/// To accept a change on purpose, re-record and commit the diff with the change:
///     OCTAVE_CAMO_RECORD=1 swift test -c release --filter BehaviorSnapshotTests
/// (A run that fails prints the new snapshot between BEGIN/END SNAPSHOT lines, so it can also be
/// copied from a CI log.)
final class BehaviorSnapshotTests: XCTestCase {
    static let snapshot = SnapshotFile<[String: SceneMetrics]>("behavior")

    /// Allowed drift: counts may move by one (but not to or from zero), levels by 1.5 dB, kept by 0.03.
    static let countSlack = 1, levelSlackDB = 1.5, keptSlack = 0.03

    func cloak(_ audio: Audio) -> Audio { cloaked(audio, seed: 7) }

    func testBehaviorMatchesTheSnapshot() throws {
        var now: [String: SceneMetrics] = [:]
        for name in Scenes.names {
            let input = Scenes.make(name)
            now[name] = SceneMetrics.measure(input, cloak(input))
        }
        try Self.snapshot.check(now, what: "behavior", differences: Self.differences)
    }

    static func differences(recorded: [String: SceneMetrics], now: [String: SceneMetrics]) -> [String] {
        var out: [String] = []
        for name in Set(recorded.keys).union(now.keys).sorted() {
            guard let r = recorded[name], let n = now[name] else { out.append("\(name): scene added or removed"); continue }
            let kinds = ["long tones", "doppler", "hum", "flybys"]
            for (label, a, b) in [("before", r.before, n.before), ("after", r.after, n.after)] {
                for k in kinds.indices where k < a.count && k < b.count {
                    if abs(a[k] - b[k]) > countSlack || (a[k] == 0) != (b[k] == 0) {
                        out.append("\(name): \(kinds[k]) \(label) \(a[k]) → \(b[k])")
                    }
                }
            }
            if abs(r.kept - n.kept) > keptSlack { out.append("\(name): kept \(r.kept) → \(n.kept)") }
            for octave in Set(r.octaves.keys).union(n.octaves.keys).sorted(by: { Double($0)! < Double($1)! }) {
                guard let a = r.octaves[octave], let b = n.octaves[octave] else { out.append("\(name): \(octave) Hz octave appeared or vanished"); continue }
                if abs(a - b) > levelSlackDB { out.append("\(name): \(octave) Hz \(a) dB → \(b) dB") }
            }
        }
        return out
    }

    /// The comparison itself: slack is honored, zero-ness is not negotiable.
    func testDifferencesRespectTheSlack() {
        let base = SceneMetrics(before: [2, 1, 1, 1], after: [0, 0, 0, 0], kept: 0.95, octaves: ["500": -0.2])
        var same = base
        same.before = [3, 1, 1, 1]; same.kept = 0.93; same.octaves = ["500": 1.0]
        XCTAssertEqual(Self.differences(recorded: ["a": base], now: ["a": same]), [])
        var leak = base
        leak.after = [1, 0, 0, 0]
        XCTAssertEqual(Self.differences(recorded: ["a": base], now: ["a": leak]).count, 1)
        var louder = base
        louder.octaves = ["500": 2.0]; louder.kept = 0.9
        XCTAssertEqual(Self.differences(recorded: ["a": base], now: ["a": louder]).count, 2)
        XCTAssertEqual(Self.differences(recorded: ["a": base], now: [:]).count, 1)
    }
}
