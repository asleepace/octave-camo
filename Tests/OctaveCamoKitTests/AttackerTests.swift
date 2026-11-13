import XCTest
@testable import OctaveCamoKit

/// The scoring attacker ported into the engine (`Attacker`), and the stop built on it (the rank
/// target). That the port gives the lab's numbers is checked against the lab itself (on the public
/// corpus, 17 of 17 ranks equal to three places; lab/tests: `EngineAttacker`); these are its
/// invariants.
final class AttackerTests: XCTestCase {
    static let rate = TrackFillTests.rate

    static func judge(_ x: [Double], _ pass: ExpectedPass = TrackFillTests.expected()) -> Attacker.Verdict? {
        Attacker().judge(x, sampleRate: rate, pass: pass)
    }

    static func rankStage() -> TrackFill {
        var s = TrackFillTests.stage([TrackFillTests.expected()])
        s.target = .rank
        return s
    }

    /// "start → end (target g)" from the rank stop's summary.
    static func landed(_ summary: String) -> (start: Double, end: Double, target: Double)? {
        let pattern = #"([0-9.]+) → ([0-9.]+) \(target ([0-9.]+)\)"#
        guard let r = summary.range(of: pattern, options: .regularExpression) else { return nil }
        let v = summary[r].split(whereSeparator: { " →()target".contains($0) }).compactMap { Double($0) }
        return v.count == 3 ? (v[0], v[1], v[2]) : nil
    }

    func testRunningMedianIsExactWithNearestEnds() {
        var rng = SeededRNG(seed: 3)
        let v = (0..<200).map { _ in Double.random(in: 0..<1, using: &rng).rounded(.down) + Double.random(in: 0..<1, using: &rng) }
        for w in [1, 3, 7, 51, 401] {
            let h = w / 2
            let brute = v.indices.map { i -> Double in
                let window = (-h...h).map { v[min(max(i + $0, 0), v.count - 1)] }.sorted()
                return window[h]
            }
            XCTAssertEqual(Attacker.runningMedian(v, window: w), brute, "window \(w)")
        }
        // Ties (repeated values) are removed one at a time.
        let steps = (0..<60).map { Double($0 / 10) }
        XCTAssertEqual(Attacker.runningMedian(steps, window: 9), steps.indices.map { i in
            (-4...4).map { steps[min(max(i + $0, 0), 59)] }.sorted()[4]
        })
    }

    /// The wrong places are physical flights: approaching above 1, receding below, steepest at 0.
    func testLibraryFlightsArePhysical() {
        for (v, d) in [(60.0, 400.0), (230.0, 5_000.0), (130.0, 1_500.0)] {
            let (t, f) = Attacker.flight(speed: v, distance: d)
            XCTAssertEqual(t.count, 1_801)
            let i0 = t.firstIndex { abs($0) < 1e-9 }!
            XCTAssertEqual(Attacker.argmin(Attacker.gradient(f, t)), i0)
            XCTAssertGreaterThan(f.first!, 1)
            XCTAssertLessThan(f.last!, 1)
            XCTAssertTrue(zip(f, f.dropFirst()).allSatisfy { $0.0 >= $0.1 - 1e-12 }, "falls throughout")
            // The approaching factor tends to 1 / (1 − v/c).
            XCTAssertEqual(f.first!, 1 / (1 - v / 343), accuracy: 0.05 / (1 - v / 343))
        }
    }

    /// A pass the blind check can't see ranks first among wrong places; white noise ranks
    /// unremarkably (6 seeds: mean near 0.5, at most one in the top 5 %).
    func testAPassRanksTopAndNoiseDoesNot() {
        let x = LineFillTests.fanTone(rate: Self.rate, snr: 13).mono
        guard let v = Self.judge(x) else { return XCTFail("no verdict") }
        XCTAssertGreaterThanOrEqual(v.rank, 0.99)
        XCTAssertEqual(v.picks.first?.rest ?? 0, 1_234, accuracy: 1_234 * 0.015)
        XCTAssertEqual(v.nulls, 72)                    // 8 scaled versions × 9 timings
        let noise = (1...6).compactMap { Self.judge(DetectionScenes.white(Self.rate * 60, seed: UInt64($0)))?.rank }
        XCTAssertEqual(noise.count, 6)
        let mean = noise.reduce(0, +) / Double(noise.count)
        XCTAssertTrue((0.25...0.75).contains(mean), "\(noise)")
        XCTAssertLessThan(noise.filter { $0 >= 0.95 }.count, 2, "\(noise)")
    }

    /// The four lines it adds up are separate: at least five bins apart in rest frequency.
    func testPicksAreSeparateLines() {
        let x = LineFillTests.fanTone(rate: Self.rate, snr: 13).mono
        guard let v = Self.judge(x) else { return XCTFail("no verdict") }
        XCTAssertEqual(v.picks.count, 4)
        let df = Double(Self.rate) / 2_048
        for (i, a) in v.picks.enumerated() {
            for b in v.picks[(i + 1)...] { XCTAssertGreaterThanOrEqual(abs(a.rest - b.rest), 5 * df - 1e-9) }
        }
        XCTAssertEqual(v.score, v.picks.reduce(0) { $0 + $1.value }, accuracy: 1e-9)
        XCTAssertEqual(v.picks.map(\.value), v.picks.map(\.value).sorted(by: >))
    }

    /// Where the attacker sees nothing remarkable (rank below `actAbove`), the rank stop changes
    /// nothing at all.
    func testRankStopLeavesTheUnremarkableAlone() {
        var checked = 0
        for seed in 1...4 {
            let x = DetectionScenes.white(Self.rate * 60, seed: UInt64(seed))
            guard let v = Self.judge(x), v.rank < Self.rankStage().actAbove else { continue }
            let r = Self.rankStage().process(x, sampleRate: Self.rate)
            XCTAssertEqual(r.output, x, "seed \(seed): \(r.summary)")
            XCTAssertTrue(r.summary.contains("left alone"), r.summary)
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 3, "most noise should rank below the bar")
    }

    /// A pass is lowered to its drawn target, and the summary's end rank is the attacker's verdict on
    /// the output. Targets differ by seed (they're drawn, not fixed), and only the pass's window changes.
    func testRankStopLowersAPassToItsTarget() {
        var targets: Set<Double> = []
        for (snr, seed) in [(13.0, 5 as UInt64), (20, 6), (20, 7)] {
            let x = LineFillTests.fanTone(rate: Self.rate, snr: snr).mono
            var stage = Self.rankStage()
            stage.seed = seed
            let r = stage.process(x, sampleRate: Self.rate)
            guard let l = Self.landed(r.summary) else { return XCTFail(r.summary) }
            targets.insert(l.target)
            // A louder single line ranks a little lower (it lifts the wrong curves crossing it): 0.987 at 20 dB.
            XCTAssertGreaterThanOrEqual(l.start, 0.95, r.summary)
            XCTAssertLessThanOrEqual(l.end, l.target, "\(snr) dB: \(r.summary)")
            guard let after = Self.judge(r.output) else { return XCTFail("no verdict after") }
            XCTAssertEqual(after.rank, l.end, accuracy: 0.0006, r.summary)
            let c = TrackFillTests.expected().center, reach = stage.fillHalfWindow + 1
            for i in x.indices where abs(Double(i) / Double(Self.rate) - c) > reach {
                if x[i] != r.output[i] { return XCTFail("sample at \(Double(i) / Double(Self.rate)) s changed") }
            }
        }
        XCTAssertEqual(targets.count, 3, "targets should be drawn per seed")
    }

    /// With decoys the stop still lands at or below its target, its end rank is still the attacker's
    /// verdict on the output (decoy fills are judged too), and nothing changes beyond the farthest a
    /// decoy can sit: the pass's reach plus twice the decoy offset.
    func testRankStopWithDecoysLandsAndStaysInReach() {
        let x = LineFillTests.fanTone(rate: Self.rate, snr: 20).mono
        var stage = Self.rankStage()
        stage.decoys = 8
        stage.seed = 6
        let r = stage.process(x, sampleRate: Self.rate)
        guard let l = Self.landed(r.summary) else { return XCTFail(r.summary) }
        XCTAssertLessThanOrEqual(l.end, l.target, r.summary)
        XCTAssertTrue(r.summary.contains("along 8 decoy(s)"), r.summary)
        guard let after = Self.judge(r.output) else { return XCTFail("no verdict after") }
        XCTAssertEqual(after.rank, l.end, accuracy: 0.0006, r.summary)
        let c = TrackFillTests.expected().center, reach = stage.fillHalfWindow + 2 * TrackFill.decoyOffset + 1
        for i in x.indices where abs(Double(i) / Double(Self.rate) - c) > reach {
            if x[i] != r.output[i] { return XCTFail("sample at \(Double(i) / Double(Self.rate)) s changed") }
        }
    }

    /// Judge-only (no rounds) is a pure measurement.
    func testZeroRoundsOnlyMeasures() {
        let x = LineFillTests.fanTone(rate: Self.rate, snr: 13).mono
        var stage = Self.rankStage()
        stage.rankRounds = 0
        let r = stage.process(x, sampleRate: Self.rate)
        XCTAssertEqual(r.output, x)
        XCTAssertTrue(r.summary.contains("filled 0 "), r.summary)
    }
}
