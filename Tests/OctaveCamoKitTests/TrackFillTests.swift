import XCTest
@testable import OctaveCamoKit

/// Removal driven by flight tracks: given an aircraft's predicted Doppler curve, find its tones and
/// fill them, and touch nothing else.
final class TrackFillTests: XCTestCase {
    static let rate = 16_000

    /// The predicted curve for `LineFillTests.fanTone` (f0 1,234 Hz, 141 m/s, 2 km, closest
    /// emission at seconds/2 − 6), as flight data would give it; `shift` moves it in time.
    static func expected(seconds: Double = 60, shift: Double = 0) -> ExpectedPass {
        let heardClosest = seconds / 2 - 6 + 2_000 / FlybyGeometry.speedOfSound + shift
        let g = FlybyGeometry(f0: 1, speed: 141, t0: heardClosest, distance: 2_000)
        // Two minutes either side: the test moves the curve up to a minute for its null.
        let t = Array(stride(from: -120.0, through: seconds + 120, by: 0.1))
        return ExpectedPass(times: t, factors: g.received(at: t).frequency, closest: heardClosest)
    }

    static func stage(_ passes: [ExpectedPass]) -> TrackFill {
        var s = TrackFill()
        s.expected = passes
        s.seed = 5
        return s
    }

    // MARK: The passes themselves

    func testExpectedPassInterpolatesAndFindsTheSteepestFall() throws {
        let p = Self.expected()
        XCTAssertTrue(p.isValid)
        let t = 20.05, i = p.times.firstIndex { $0 > t }!
        XCTAssertEqual(p.factor(at: t)!, 0.5 * (p.factors[i - 1] + p.factors[i]), accuracy: 1e-9)
        XCTAssertNil(p.factor(at: 1_000))
        // The steepest fall is heard before the closest approach (29.8 s): the approach's sound
        // arrives compressed in time.
        let heardClosest = 24 + 2_000 / FlybyGeometry.speedOfSound
        XCTAssertTrue((heardClosest - 8)...heardClosest ~= p.steepest, "\(p.steepest)")
        let round = try JSONDecoder().decode(ExpectedPass.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(round, p)
    }

    func testUnusablePassesAreRefused() {
        XCTAssertFalse(ExpectedPass(times: [0], factors: [1]).isValid)
        XCTAssertFalse(ExpectedPass(times: [0, 1], factors: [1]).isValid)
        XCTAssertFalse(ExpectedPass(times: [1, 0], factors: [1, 1]).isValid)
        XCTAssertFalse(ExpectedPass(times: [0, 1], factors: [1, .nan]).isValid)
        XCTAssertFalse(ExpectedPass(times: [0, 1], factors: [1, 3]).isValid)
        let x = DetectionScenes.white(Self.rate * 30, seed: 1)
        let r = Self.stage([ExpectedPass(times: [0, 1], factors: [1, .nan])]).process(x, sampleRate: Self.rate)
        XCTAssertEqual(r.output, x)
        XCTAssertTrue(r.summary.contains("no usable"), r.summary)
    }

    // MARK: Finding and removing

    /// The attacker's verdict on the clip's one pass.
    static func verdict(_ x: [Double], _ stage: TrackFill) -> TrackFill.Tone? {
        stage.verdicts(x, sampleRate: rate).first ?? nil
    }

    /// A pass too faint for the blind path search (13 dB/Hz; at 16 kHz it needs ~16) stands out
    /// to an attacker who has the track, at the right rest frequency and timing; after removal
    /// it doesn't.
    func testFindsAndRemovesAPassTheBlindCheckCantSee() {
        let x = LineFillTests.fanTone(rate: Self.rate, snr: 13).mono
        XCTAssertTrue(PathSearch().tracks(in: x, sampleRate: Self.rate).isEmpty, "the blind search sees it: this test lost its point")
        let stage = Self.stage([Self.expected()])
        guard let before = Self.verdict(x, stage) else { return XCTFail("no verdict") }
        XCTAssertGreaterThan(before.z, stage.stopZ + 2)
        XCTAssertEqual(before.rest, 1_234, accuracy: 1_234 * 0.015)
        XCTAssertLessThanOrEqual(abs(before.offset), 1.5)
        let r = stage.process(x, sampleRate: Self.rate)
        XCTAssertFalse(r.summary.contains("filled 0 "), r.summary)
        XCTAssertLessThan(Self.verdict(r.output, stage)?.z ?? 0, stage.stopZ, r.summary)
    }

    /// A loud pass ends below the bar too, in a few fills, not one per shoulder (at the z-1 stop a
    /// 30 dB pass takes four: 20.1 → 1.0).
    func testALoudPassEndsBelowTheBar() {
        for snr in [30.0, 40] {
            let x = LineFillTests.fanTone(rate: Self.rate, snr: snr).mono
            let stage = Self.stage([Self.expected()])
            let r = stage.process(x, sampleRate: Self.rate)
            XCTAssertLessThan(Self.verdict(r.output, stage)?.z ?? 0, stage.stopZ, "\(snr) dB: \(r.summary)")
            XCTAssertTrue(["filled 1 ", "filled 2 ", "filled 3 ", "filled 4 "].contains { r.summary.contains($0) }, "\(snr) dB: \(r.summary)")
        }
    }

    /// Only the strip along the found curve changes: every sample outside the searched window is
    /// identical, and the spectrum away from the swept range is unchanged.
    func testTouchesOnlyTheCurve() {
        let x = LineFillTests.fanTone(rate: Self.rate, snr: 16).mono
        let stage = Self.stage([Self.expected()])
        let y = stage.process(x, sampleRate: Self.rate).output
        XCTAssertNotEqual(x, y)
        let c = Self.expected().center, guardBand = stage.fillHalfWindow + stage.maxOffset + 1
        for i in x.indices where abs(Double(i) / Double(Self.rate) - c) > guardBand {
            if x[i] != y[i] { return XCTFail("sample at \(Double(i) / Double(Self.rate)) s changed") }
        }
        // Below 700 Hz and above 2.5 kHz (the curve sweeps ~0.9–1.7 kHz): no change.
        for band in [(100.0, 700.0), (2_500.0, 6_000.0)] {
            let a = Self.bandPower(x, band), b = Self.bandPower(y, band)
            XCTAssertEqual(10 * log10(b / a), 0, accuracy: 0.05, "\(band)")
        }
    }

    // MARK: Leaving things alone

    func testNoPassesIsANoOp() {
        let x = DetectionScenes.white(Self.rate * 30, seed: 2)
        let r = Self.stage([]).process(x, sampleRate: Self.rate)
        XCTAssertEqual(r.output, x)
    }

    /// Noise along a plausible curve: nothing stands out, so little is filled, and what is filled
    /// leaves the attacker's z below the stopping point without raising it (several seeds). With
    /// the stop at z 1, noise alone sometimes crosses it; filling noise must not create evidence.
    func testNoiseAloneStaysBelowTheStop() {
        let stage = Self.stage([Self.expected()])
        for seed in 1...4 {
            let x = DetectionScenes.white(Self.rate * 60, seed: UInt64(seed))
            let before = Self.verdict(x, stage)?.z ?? 0
            XCTAssertLessThan(before, 3, "seed \(seed): noise shouldn't look like a pass")
            let r = stage.process(x, sampleRate: Self.rate)
            let after = Self.verdict(r.output, stage)?.z ?? 0
            XCTAssertLessThan(after, max(stage.stopZ, before) + 0.5, "seed \(seed): \(r.summary)")
        }
    }

    /// An engine's second, unrelated line (1,234 and 1,693 Hz, not harmonics), both following the
    /// pass, each 11 dB/Hz: summing two lines the verdict's excess nearly doubles (0.44 → 0.79;
    /// its z barely moves, 11.6 → 12.5, as the wrong times along these long tones gain too), and
    /// the fill keeps going until the sum is below the stop, both lines gone.
    func testSeveralLinesAddUpAndAreAllRemoved() {
        var x = LineFillTests.fanTone(rate: Self.rate, snr: 11).mono
        let second = LineFillTests.fanTone(rate: Self.rate, snr: 11, seed: 22, f0: 1_693).mono
        let floor = DetectionScenes.white(x.count, seed: 22)
        for i in x.indices { x[i] += second[i] - floor[i] }        // one noise floor, two lines
        let one = Self.stage([Self.expected()])
        var two = one
        two.lines = 2
        guard let v1 = Self.verdict(x, one), let v2 = Self.verdict(x, two) else { return XCTFail("no verdict") }
        XCTAssertGreaterThan(v2.effect, 1.6 * v1.effect, "the second line should add about as much as the first")
        let r = two.process(x, sampleRate: Self.rate)
        XCTAssertLessThan(Self.verdict(r.output, two)?.z ?? 0, two.stopZ, r.summary)
        XCTAssertLessThan(Self.verdict(r.output, one)?.z ?? 0, one.stopZ + 0.5, r.summary)
    }

    /// The verdict against wrong places is fair in noise: over 12 seeds of white noise its z
    /// averages about 0 and rarely reaches the stop. Against wrong times (the pass's flat tails,
    /// fewer independent tries at the best rest frequency) it averages about 1. A real pass still
    /// stands out.
    func testWrongPlacesNullIsFairInNoise() {
        func noise(_ null: TrackFill.Null) -> [Double] {
            var s = Self.stage([Self.expected()])
            s.null = null
            return (1...12).compactMap { Self.verdict(DetectionScenes.white(Self.rate * 60, seed: UInt64($0)), s)?.z }
        }
        let places = noise(.wrongPlaces), times = noise(.wrongTimes)
        let mean = { (v: [Double]) in v.reduce(0, +) / Double(v.count) }
        XCTAssertEqual(places.count, 12)
        XCTAssertLessThan(abs(mean(places)), 0.5, "wrong places: \(places)")
        XCTAssertLessThanOrEqual(places.filter { $0 >= 1 }.count, 3, "wrong places fire on noise: \(places)")
        XCTAssertGreaterThan(mean(times), 0.5, "the wrong-times bias this replaces: \(times)")
        var s = Self.stage([Self.expected()])
        s.null = .wrongPlaces
        XCTAssertGreaterThan(Self.verdict(LineFillTests.fanTone(rate: Self.rate, snr: 11).mono, s)?.z ?? 0, 3)
    }

    /// A physical flight's Doppler factor: falls monotonically and stays within 1/(1 ± v/c). Heard
    /// in reception time it falls fastest a little before the closest approach (approaching sound
    /// arrives compressed: df/dt = factor · df/dτ), so the factor there is just above 1, more so the
    /// faster the flight.
    func testFlightCurveIsPhysical() {
        for (v, d) in [(60.0, 400.0), (130.0, 1_500.0), (230.0, 5_000.0)] {
            let f = TrackFill.flight(speed: v, distance: d)
            XCTAssertEqual(f.count, 1_801)
            XCTAssertTrue(zip(f, f.dropFirst()).allSatisfy { $0.0 >= $0.1 - 1e-12 }, "v \(v) d \(d): not monotone")
            XCTAssertLessThanOrEqual(f.max()!, 1 / (1 - v / 343) + 1e-9)
            XCTAssertGreaterThanOrEqual(f.min()!, 1 / (1 + v / 343) - 1e-9)
            XCTAssertGreaterThanOrEqual(f[900], 1, "v \(v) d \(d): the steepest fall is on the approaching side")
            if v <= 60 { XCTAssertLessThan(f[900], 1.05, "slow flight: steepest fall near the closest approach") }
        }
    }

    /// Against physical wrong places, the verdict is fairer in noise than against wrong times, and
    /// a real pass still stands out.
    func testLibraryNullIsFairerInNoise() {
        func noise(_ null: TrackFill.Null) -> [Double] {
            var s = Self.stage([Self.expected()])
            s.null = null
            return (1...12).compactMap { Self.verdict(DetectionScenes.white(Self.rate * 60, seed: UInt64($0)), s)?.z }
        }
        let lib = noise(.library), times = noise(.wrongTimes)
        let mean = { (v: [Double]) in v.reduce(0, +) / Double(v.count) }
        XCTAssertEqual(lib.count, 12)
        XCTAssertLessThan(mean(lib), 0.6, "library: \(lib)")
        XCTAssertLessThan(mean(lib), mean(times) - 0.4, "library \(lib) against wrong times \(times)")
        var s = Self.stage([Self.expected()])
        s.null = .library
        XCTAssertGreaterThan(Self.verdict(LineFillTests.fanTone(rate: Self.rate, snr: 11).mono, s)?.z ?? 0, 3)
    }

    /// The forced-rests diagnostic fills exactly the given rest frequencies and nothing else.
    func testForcedRestsFillOnlyThoseLines() {
        let x = LineFillTests.fanTone(rate: Self.rate, snr: 20).mono
        var s = Self.stage([Self.expected()])
        s.forcedRests = [1_234]
        let r = s.process(x, sampleRate: Self.rate)
        XCTAssertTrue(r.summary.contains("forced, filled 1 tone(s) (1234 Hz)"), r.summary)
        let before = Self.verdict(x, Self.stage([Self.expected()]))?.z ?? 0
        let after = Self.verdict(r.output, Self.stage([Self.expected()]))?.z ?? 99
        XCTAssertLessThan(after, before / 3, "one fill should take most of the tone: z \(before) → \(after)")
        let diff = zip(r.output, x).map { $0 - $1 }
        XCTAssertLessThan(Self.bandPower(diff, (2_300, 7_000)), 1e-9 * max(Self.bandPower(diff, (800, 2_200)), 1e-300))
    }

    /// A scaled pass is the attacker's scaled wrong place: factor^a, time stretched by b about the
    /// centre, centred `offset` later.
    func testScaledPassMatchesTheAttackersWrongPlace() {
        let p = Self.expected()
        let c = p.center
        for (a, b, o) in [(1.0, 1.0, 3.0), (0.6, 1.6, -4.5), (1.6, 0.6, 1.5)] {
            let d = p.scaled(a: a, b: b, offset: o)
            // A fast pass's factor^1.6 can leave the physical range (decoyPasses skips those).
            XCTAssertEqual(d.isValid, d.factors.allSatisfy { $0 > 0.5 && $0 < 2 })
            XCTAssertEqual(d.center, c + o, accuracy: 1e-9)
            for t in stride(from: c - 20, through: c + 20, by: 2.5) {
                guard let want = p.factor(at: c + (t - c - o) / b).map({ exp(a * log($0)) }), let got = d.factor(at: t) else { continue }
                // Raised then interpolated against interpolated then raised: equal to second order in the grid step.
                XCTAssertEqual(got, want, accuracy: 1e-5, "a \(a) b \(b) o \(o) t \(t)")
            }
        }
    }

    /// Decoys: K distinct valid curves, none the truth, the same for the same seed; with decoys each
    /// forced fill is also made along every decoy.
    func testDecoysAreDistinctWrongPlacesAndAreFilled() {
        var s = Self.stage([Self.expected()])
        s.decoys = 6
        var r1 = SeededRNG(seed: 11), r2 = SeededRNG(seed: 11)
        let a = s.decoyPasses(for: Self.expected(), rng: &r1), b = s.decoyPasses(for: Self.expected(), rng: &r2)
        XCTAssertEqual(a.count, 6)
        XCTAssertEqual(a, b)
        XCTAssertEqual(Set(a.map { $0.factors.prefix(50).map { ($0 * 1e9).rounded() } + [($0.center * 1e6).rounded()] }).count, 6)
        XCTAssertFalse(a.contains(Self.expected()))
        let x = LineFillTests.fanTone(rate: Self.rate, snr: 20).mono
        s.forcedRests = [1_234]
        let r = s.process(x, sampleRate: Self.rate)
        XCTAssertTrue(r.summary.contains("forced, filled 1 tone(s) (1234 Hz), and 6 along 6 decoy(s)"), r.summary)
        // The decoy strips change audio beyond the truth's strip: the change carries more energy
        // than one fill alone (the six decoy strips, each about as much as the truth's minus its tone).
        var plain = Self.stage([Self.expected()])
        plain.forcedRests = [1_234]
        let one = plain.process(x, sampleRate: Self.rate).output
        let energy = { (y: [Double]) in zip(y, x).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) } }
        XCTAssertGreaterThan(energy(r.output), 1.5 * energy(one))
    }

    /// An attacker who knows the code and finds every processed curve still can't pick the pass out
    /// of them: the truth is the centre of the set (nearest its centroid, or nearest the others in
    /// all) about one time in nine, as any member is. Decoys built around the truth, as the first
    /// version did, have it at the centre nearly always.
    func testDecoysDontPointBackToThePass() {
        let pass = Self.expected()
        var s = Self.stage([pass]); s.decoys = 8
        let k = pass.factors.indices.max { abs(log(pass.factors[$0])) < abs(log(pass.factors[$1])) }!
        let span = pass.times.last! - pass.times.first!
        // Each member's (log a, log b, offset) relative to the truth, scaled by the known spreads.
        func coords(_ d: ExpectedPass) -> [Double] {
            [log(log(d.factors[k]) / log(pass.factors[k])) / TrackFill.decoyLogSpread,
             log((d.times.last! - d.times.first!) / span) / TrackFill.decoyLogSpread,
             (d.center - pass.center) / TrackFill.decoyOffset]
        }
        func dist(_ x: [Double], _ y: [Double]) -> Double { sqrt(zip(x, y).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }) }
        let trials = 600
        var nearCentroid = 0, medoid = 0
        var rng = SeededRNG(seed: 5)
        for _ in 0..<trials {
            let d = s.decoyPasses(for: pass, rng: &rng)
            XCTAssertEqual(d.count, 8)
            let m = [[0.0, 0, 0]] + d.map(coords)        // the truth first
            let centroid = (0..<3).map { i in m.reduce(0) { $0 + $1[i] } / Double(m.count) }
            if m.indices.min(by: { dist(m[$0], centroid) < dist(m[$1], centroid) }) == 0 { nearCentroid += 1 }
            let total = m.map { x in m.reduce(0) { $0 + dist(x, $1) } }
            if total.indices.min(by: { total[$0] < total[$1] }) == 0 { medoid += 1 }
        }
        // 1/9 of 600 is 67, standard deviation 7.7: within 4 either way.
        for (rule, hits) in [("nearest the centroid", nearCentroid), ("nearest the others", medoid)] {
            XCTAssertEqual(Double(hits), Double(trials) / 9, accuracy: 4 * sqrt(Double(trials) * 8 / 81),
                           "the truth was the one \(rule) \(hits) of \(trials) times")
        }
    }

    /// `harmonics` 1 means none: with one tone allowed, the null target touches nothing above the
    /// fundamental's sweep (870–2,090 Hz here); with 3 it also fills ×2 and ×3 there.
    func testHarmonicsOneFillsNoMultiples() {
        let x = LineFillTests.fanTone(rate: Self.rate, snr: 20).mono
        func above(_ harmonics: Int) -> Double {
            var s = Self.stage([Self.expected()])
            s.target = .null; s.harmonics = harmonics; s.maxTones = 1
            s.maxRaises = 0                 // only the fill and its multiples, no raising after it
            let y = s.process(x, sampleRate: Self.rate).output
            return Self.bandPower(zip(y, x).map { $0 - $1 }, (2_300, 7_000))
        }
        let none = above(1), three = above(3)
        XCTAssertGreaterThan(three, 0, "×2 and ×3 should have been filled")
        XCTAssertLessThan(none, 1e-9 * max(three, 1e-300), "harmonics 1 still changed the band above the fundamental")
        XCTAssertEqual(TrackFill().harmonics, 1, "off by default: tuned on a synthetic ×2/×3 engine")
    }

    /// The defaults are the shipped behaviour: the fixed stop on one line against wrong times.
    func testDefaultsAreTheFixedStopOnOneLine() {
        let s = TrackFill()
        XCTAssertEqual(s.target, .fixed)
        XCTAssertEqual(s.lines, 1)
        XCTAssertEqual(s.null, .wrongTimes)
        XCTAssertEqual(TrackFill.reach(toleranceHz: 0, binHz: 7.8), 2)
        XCTAssertEqual(TrackFill.reach(toleranceHz: 39, binHz: 7.8), 5)
    }

    /// Summing four lines, noise alone: the fill doesn't raise the verdict. (Before any fill, the
    /// four-line z in white noise runs higher than one line's, mean 1.3 against 0.9 over 16 seeds,
    /// up to 3.2: the wrong times this verdict compares with, the same curve 20–60 s away, aren't
    /// exchangeable with the truth in noise. docs/EXPERIMENTS.md.)
    func testNoiseAloneStaysBelowTheStopWithFourLines() {
        var stage = Self.stage([Self.expected()])
        stage.lines = 4
        for seed in 1...4 {
            let x = DetectionScenes.white(Self.rate * 60, seed: UInt64(seed))
            let before = Self.verdict(x, stage)?.z ?? 0
            XCTAssertLessThan(before, 3.5, "seed \(seed): noise shouldn't look like a pass")
            let r = stage.process(x, sampleRate: Self.rate)
            let after = Self.verdict(r.output, stage)?.z ?? 0
            XCTAssertLessThan(after, max(stage.stopZ, before) + 0.5, "seed \(seed): \(r.summary)")
        }
    }

    /// The tone is there, but not when the tracks say: a wrong track doesn't remove the real pass
    /// (the right track still finds it afterwards), and works only around its own closest
    /// approach. (Its curve, at some rest frequencies, lies along the real tone's tail, which an
    /// attacker holding that track would score too, z 4.2 here; it fills those and stops.)
    func testAPassAtTheWrongTimeLeavesTheRealOne() {
        let x = LineFillTests.fanTone(rate: Self.rate, seconds: 120, snr: 20).mono
        let wrong = Self.stage([Self.expected(seconds: 120, shift: 45)]), right = Self.stage([Self.expected(seconds: 120)])
        let r = wrong.process(x, sampleRate: Self.rate)
        XCTAssertGreaterThan(Self.verdict(r.output, right)?.z ?? 0, right.stopZ + 2, r.summary)
        let c = wrong.expected[0].center, guardBand = wrong.fillHalfWindow + wrong.maxOffset + 1
        XCTAssertFalse(x.indices.contains { abs(Double($0) / Double(Self.rate) - c) > guardBand && x[$0] != r.output[$0] })
    }

    /// Speech under a predicted pass: its harmonics don't follow the curve, so it's untouched.
    func testSpeechIsLeftAlone() {
        let speech = Scenes.make("speech", rate: Self.rate).mono
        let x = Array([speech, speech, speech, speech].joined())
        let r = Self.stage([Self.expected()]).process(x, sampleRate: Self.rate)
        XCTAssertEqual(r.output, x, r.summary)
    }

    // MARK: Aiming at a draw from the null

    /// (score before, after, target) from a null-target summary's "a → b (target t)".
    static func aimed(_ summary: String) -> (Double, Double, Double)? {
        guard let r = summary.range(of: #"(-?[0-9.]+) → (-?[0-9.]+) \(target (-?[0-9.]+)\)"#, options: .regularExpression) else { return nil }
        let n = summary[r].split(whereSeparator: { " →()target".contains($0) }).compactMap { Double($0) }
        return n.count == 3 ? (n[0], n[1], n[2]) : nil
    }

    /// Noise along a curve, the target drawn above its score: the strip is raised (the sound already
    /// there, louder) until the score is near the target, and nothing is filled.
    func testNullTargetRaisesAQuietPassTowardItsTarget() {
        var lifted = 0
        for seed in 1...6 {
            var stage = Self.stage([Self.expected()])
            stage.target = .null
            stage.null = .wrongTimes        // the mechanics, on the comparison these seeds were chosen for
            stage.seed = UInt64(seed)
            let x = DetectionScenes.white(Self.rate * 60, seed: UInt64(seed))
            let r = stage.process(x, sampleRate: Self.rate)
            guard let (before, after, aim) = Self.aimed(r.summary) else { return XCTFail(r.summary) }
            let check = Self.verdict(r.output, stage)?.score ?? .nan
            XCTAssertEqual(check, after, accuracy: 0.011, r.summary)
            if aim > before + 0.05 {
                lifted += 1
                XCTAssertTrue(r.summary.contains("filled 0 ") && !r.summary.contains("raised 0 "), r.summary)
                XCTAssertLessThan(abs(after - aim), 0.5 * (aim - before), r.summary)
            }
        }
        XCTAssertGreaterThan(lifted, 0, "no target fell above its score: this test lost its point")
    }

    /// A loud pass under a null target: removed down to around its target (a draw from the null,
    /// so a few at most), not left standing.
    func testNullTargetStillRemovesALoudPass() {
        let x = LineFillTests.fanTone(rate: Self.rate, snr: 30).mono
        var stage = Self.stage([Self.expected()])
        stage.target = .null
        let r = stage.process(x, sampleRate: Self.rate)
        guard let (before, after, aim) = Self.aimed(r.summary) else { return XCTFail(r.summary) }
        XCTAssertGreaterThan(before - aim, 1, r.summary)
        XCTAssertLessThan(after - aim, 0.3 * (before - aim), r.summary)
    }

    // MARK: In the pipeline

    func testRunsAfterTheLowBandAndBeforeLinesOnlyWhenGivenPasses() {
        let audio = LineFillTests.fanTone(rate: Self.rate, seconds: 60, snr: 16)
        var p = ScrubPipeline()
        p.steps = [.mono, .lowband, .lines]
        p.lowband.seed = 1
        p.lines.seed = 1
        let plain = p.run(audio).log
        XCTAssertFalse(plain.contains { $0.hasPrefix("tracks:") })
        p.tracks = Self.stage([Self.expected()])
        let log = p.run(audio).log
        let order = ["lowband", "tracks:", "lines:"].map { key in log.firstIndex { $0.hasPrefix(key) } ?? -1 }
        XCTAssertTrue(order.allSatisfy { $0 >= 0 } && order == order.sorted(), "\(log)")
    }

    // MARK: Helpers

    static func bandPower(_ x: [Double], _ band: (Double, Double)) -> Double {
        let n = 4_096, fft = RealFFT(size: n), w = DSP.hann(n)
        var re = [Double](repeating: 0, count: n / 2 + 1), im = re, total = 0.0
        let lo = Int(band.0 * Double(n) / Double(rate)), hi = Int(band.1 * Double(n) / Double(rate))
        for start in stride(from: 0, to: x.count - n, by: n / 2) {
            fft.forward((0..<n).map { x[start + $0] * w[$0] }, &re, &im)
            for k in lo..<hi { total += re[k] * re[k] + im[k] * im[k] }
        }
        return total
    }
}
