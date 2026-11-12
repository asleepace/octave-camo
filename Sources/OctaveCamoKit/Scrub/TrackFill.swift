#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WASILibc)
import WASILibc
#endif

/// One aircraft's predicted Doppler factor (received ÷ emitted frequency) over the audio's time, as
/// heard at the recording's position (sound travel included). Computed outside the engine from
/// flight tracks (ADS-B); the engine never sees a position. Give it a couple of minutes either
/// side of the audio: the search compares the curve with itself moved up to a minute.
public struct ExpectedPass: Codable, Equatable {
    /// Audio time, s, increasing.
    public var times: [Double]
    public var factors: [Double]
    /// When the closest approach is heard (audio time, s), if known; the search looks around it.
    public var closest: Double?

    public init(times: [Double], factors: [Double], closest: Double? = nil) {
        self.times = times
        self.factors = factors
        self.closest = closest
    }

    /// Usable: at least two points, the same count of each, times strictly increasing, everything
    /// finite, factors physical (a source slower than sound: 0.5–2).
    public var isValid: Bool {
        times.count >= 2 && times.count == factors.count
            && times.allSatisfy(\.isFinite) && factors.allSatisfy { $0.isFinite && $0 > 0.5 && $0 < 2 }
            && zip(times, times.dropFirst()).allSatisfy { $0 < $1 }
            && (closest?.isFinite ?? true)
    }

    /// When the pitch falls fastest, as heard: a few seconds before the closest approach is heard
    /// (sound from the approach arrives compressed in time), and where a pass is loudest.
    var steepest: Double {
        var best = 0.0, at = times.first ?? 0
        for i in 1..<max(times.count, 1) where times[i] > times[i - 1] {
            let slope = -(factors[i] - factors[i - 1]) / (times[i] - times[i - 1])
            if slope > best { best = slope; at = 0.5 * (times[i] + times[i - 1]) }
        }
        return at
    }

    /// Where the search centres: the closest approach when given, else the steepest fall.
    var center: Double { closest ?? steepest }

    /// The same pass reshaped as the scoring attacker's scaled wrong places are: factor^a, time
    /// stretched by b about its centre, centred `offset` later.
    public func scaled(a: Double, b: Double, offset: Double) -> ExpectedPass {
        let c = center
        return ExpectedPass(times: times.map { c + offset + ($0 - c) * b },
                            factors: factors.map { exp(a * log($0)) }, closest: c + offset)
    }

    func factor(at t: Double) -> Double? {
        guard let first = times.first, let last = times.last, t >= first, t <= last, times.count == factors.count else { return nil }
        var lo = 0, hi = times.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if times[mid] <= t { lo = mid } else { hi = mid }
        }
        let w = times[hi] > times[lo] ? (t - times[lo]) / (times[hi] - times[lo]) : 0
        return factors[lo] + w * (factors[hi] - factors[lo])
    }
}

/// Removes what flight tracks say is there, by running the attacker's own test first and acting
/// on it. For each expected pass: the best mean excess along f0·factor(t − offset) over every rest
/// frequency f0 and a few seconds of timing slack, near the closest approach, compared with the
/// same search with the curve moved to many wrong times (a z, exactly as the known-path attacker
/// scores it). While that z is at least `stopZ`, the best tone is filled with noise along its
/// curve and the filled audio is tested again. Partial removal is worse than none (removing some
/// of an engine's tones tightens the attacker's null, so the rest stand out more), so it doesn't
/// stop at the tones it likes; it stops when the attacker's score is low.
public struct TrackFill {
    public var expected: [ExpectedPass] = []
    /// Remove until the attacker-equivalent z is below this. Not a detection threshold: the place
    /// search sums every aircraft's evidence over a grid, so tones at z 1–2.5 that no single test
    /// would call a pass still rank the true place high (docs/EXPERIMENTS.md, "Stopping track
    /// removal"). At 1 instead of 2.5 a borderline session went from p 0.12 and 0.06 to 0.35 and
    /// 0.21 against the scene's no-information baseline, for 0.1–0.3 dB more change above 300 Hz;
    /// 0 doubled the change for nothing more. On the holdout, 1 and 2.5 cleared both sessions alike.
    public var stopZ = 1.0
    /// Tones filled per pass at most (an engine has several: fan, shaft orders, harmonics; a light
    /// aircraft's propeller many more). At 8, 10 of 35 public-corpus passes stopped at the cap with
    /// the tone still up; at 24, the tuning half's median z along the traced harmonic went 2.5 → 1.7
    /// and passes at z ≥ 5 from 6 to 1–3 (two seeds), for 0.7 dB median change above 300 Hz.
    public var maxTones = 24
    /// Timing slack, s (published positions lag and are coarse), as the attacker searches it.
    public var maxOffset = 6.0
    public var offsetStep = 0.5
    /// Where the null curves go: ±20–60 s, every 5 s.
    public var nullShifts: [Double] = stride(from: 20.0, through: 60, by: 5).flatMap { [-$0, $0] }
    /// What the verdict compares the pass's curve with.
    /// - `wrongTimes`: the same curve moved `nullShifts`. Across the window those copies are mostly
    ///   the pass's flat tails, and a flat curve gets fewer independent tries at the best rest
    ///   frequency (neighbouring rests stay on the same bin every frame) than a sweeping one, so in
    ///   noise the truth wins by default: z averages ~1 in white noise, and told to expect a pass that
    ///   isn't there the fill acts on 30 % of real backgrounds and leaves a hole (docs/EXPERIMENTS.md).
    /// - `wrongPlaces`: curves a different geometry would give, as the attacker's wrong answers are:
    ///   the pass's own curve with its swing's depth (in log factor) and duration scaled by
    ///   `placeScales` (not both 1), centred `placeOffsets` s from the truth's closest approach.
    ///   They sweep like the truth, so the best-of-many advantage cancels: in white noise z averages
    ///   −0.06 (1.05 against wrong times). But they sit on a real line near the closest approach and
    ///   share its credit, so a real pass scores low (docs/EXPERIMENTS.md, "A fair stopping test").
    /// - `library`: physical wrong places: the Doppler curves of straight, level, constant-speed
    ///   flight past a listener at other closest distances and speeds (`librarySpeeds` ×
    ///   `libraryDistances`), centred `placeOffsets` s from the pass's closest approach. Other places
    ///   along a flight hear exactly such curves, so these are wrong answers like the attacker's
    ///   (lab/geometry.py, the same formula). Experimental: on the public corpus's shapes it
    ///   separates real passes from white noise best of the three (median z 1.40 against noise's
    ///   +0.35, spread 1.3; wrong times 2.70 against +1.50, scaled copies 1.10 against +0.41), but
    ///   as the stop it removes less than wrong times and the corpus leaks more (17 of 34 against
    ///   12, docs/EXPERIMENTS.md): the old stop's bias works as extra removal.
    ///
    /// The default stays `wrongTimes`: fair stops remove less, which helps holes and hurts leaks.
    public enum Null: String { case wrongTimes, wrongPlaces, library }
    public var librarySpeeds: [Double] = [60, 90, 130, 180, 230]
    public var libraryDistances: [Double] = [400, 800, 1_500, 3_000, 5_000]

    /// The Doppler factor heard from straight, level flight at `speed` m/s whose closest slant
    /// distance is `distance` m, sampled every `step` s of reception time from −`half` to +`half`
    /// s about its steepest fall: factor = 1 / (1 + v·s / (r·c)), s = v·τ, r = √(d² + s²), heard
    /// at t = τ + r/c.
    static func flight(speed v: Double, distance d: Double, half: Double = 90, step: Double = 0.1) -> [Double] {
        let c = 343.0, fine = step / 4
        var t: [Double] = [], f: [Double] = []
        var tau = -half - 30
        while tau <= half + 30 {
            let sAlong = v * tau, r = (d * d + sAlong * sAlong).squareRoot()
            t.append(tau + r / c); f.append(1 / (1 + v * sAlong / (r * c)))
            tau += fine
        }
        var steepest = 0, slope = Double.infinity
        for i in 1..<(t.count - 1) {
            let g = (f[i + 1] - f[i - 1]) / (t[i + 1] - t[i - 1])
            if g < slope { slope = g; steepest = i }
        }
        let t0 = t[steepest]
        var out: [Double] = [], j = 0
        var q = -half
        while q <= half + 1e-9 {
            let want = t0 + q
            while j + 1 < t.count && t[j + 1] < want { j += 1 }
            let a = t[j], b = t[min(j + 1, t.count - 1)]
            let w = b > a ? (want - a) / (b - a) : 0
            out.append(f[j] + (f[min(j + 1, f.count - 1)] - f[j]) * min(max(w, 0), 1))
            q += step
        }
        return out
    }
    public var null = Null.wrongTimes
    public var placeScales: [Double] = [0.6, 1, 1.6]
    public var placeOffsets: [Double] = [-6, -3, 0, 3, 6]
    /// The search looks this far either side of the closest approach, s (where the pass is loud).
    public var halfWindow = 25.0
    /// Rest frequencies searched, in 0.2 % steps.
    public var restRange: ClosedRange<Double> = 100...3_500
    /// The band whitened and searched: the attacker's.
    public var band: ClosedRange<Double> = 80...4_000
    /// The fill strip's extra half-width, Hz: the predicted curve is only as good as the track.
    public var marginHz = 8.0
    /// ...plus this fraction of its frequency: a predicted swing can be a percent or so off at its
    /// ends (stale archive positions), and a strip that half-covers a tone leaves its edge.
    public var relativeMargin = 0.01
    /// How far off the curve a frame's excess still counts, Hz (at least ±2 bins of the search's
    /// own grid, about ±12 Hz at 48 kHz). Off by default: tried to match an attacker scoring ±23 Hz
    /// wide, it raised the wrong-time scores more than the real tone's, so removal filled less
    /// (public corpus, tuning half: median z 1.7 → 2.7 at ±24 Hz). The second window does that job.
    public var toleranceHz = 0.0
    /// The same as a fraction of the frequency, on top (a curve a little off in shape moves a high
    /// harmonic further than a low one). Off by default, for the same reason (with 2 %: 4.3).
    public var relativeTolerance = 0.0
    /// How many separate lines the verdict adds up along the curve (the attacker's statistic,
    /// THREAT_MODEL.md). Every line an engine makes follows the same Doppler factor, harmonic or
    /// not, so lines too faint to stand out one at a time still add up; with more than one, the
    /// fill keeps going while their sum stands out, the strongest line first. Separate: at least
    /// the tolerance's width (2·reach + 1 bins) apart in rest frequency, so one line counts once
    /// (where the curve's factor is below 1 the observed gap is that much narrower, up to 0.5×).
    /// Not shown to beat removing deeper on the public corpus (docs/EXPERIMENTS.md); off by default.
    public var lines = 1
    /// How the fill reads its level (LineFill.Level; experimental, OPEN_QUESTIONS.md).
    public var fillLevel = LineFill.Level.median
    public var seed: UInt64 = .random(in: 1...UInt64.max)

    public init() {}

    /// Analysis windows the stopping test checks, s (a tone counts at whichever sees it best).
    /// The search's own 0.17 s window resolves 5.9 Hz at 48 kHz; an attacker using 85 ms windows
    /// found harmonics it passed over (docs/EXPERIMENTS.md, "Removal's stopping test against the
    /// attacker's").
    /// One by default. Adding 85 ms halved the traced harmonic's median z on the public corpus's
    /// tuning half (1.7 → 0.7, two seeds), but on our own sessions its extra fills left a hole an
    /// attacker can find (e9a1c3: the truth 1,045th of 1,089, p 0.000 from the bottom, where one
    /// window fills nothing) and made 37a954's place easier (p 0.49 → 0.14, same seed). Fills
    /// aren't yet clean enough to fill on weaker evidence.
    public var windows: [Double] = [0.17]

    /// Where each pass's score should end up. `.fixed`: below `stopZ` (removal only). That leaves a
    /// mark of its own: removal takes away the best match along the true curve, and even with no
    /// plane some background lines up with it by chance, so afterwards the true curve scores lower
    /// than the same curve at wrong times or places, which keep their best. Summed over aircraft,
    /// a hole at the true place, however clean the fill (docs/EXPERIMENTS.md, "What leaves the
    /// dip"). `.null`: a target drawn for each pass from the attacker's own null (the best mean
    /// excess of the same curve centred at a random other time, on its own stretch); removal while
    /// the pass's best mean excess is above it, and while it's below, the strip along the best
    /// tone's curve raised (the sound already there, louder) up to it. Meant to leave the true
    /// curve's score a draw from the null, neither a bump nor a hole; on synthetic scenes it comes
    /// close, but on the public corpus raising rebuilds what's left of a plane along the true curve
    /// and, scored against wrong places' curves, `.null` is no better than `.fixed`
    /// (docs/EXPERIMENTS.md). Experimental.
    public enum Target: String, Sendable { case fixed, null, rank }
    public var target: Target = .fixed
    /// How close to its target a pass's score has to get, raising (in wrong-time spreads).
    public var targetTolerance = 0.25
    /// `rank` target: act only on passes the scoring attacker ranks at least this high among wrong
    /// places, and fill at most this many lines per pass (0: judge only, for checking).
    public var actAbove = 0.9
    public var rankRounds = 24
    public var rankWrong = Attacker.Wrong.scaled
    /// Experimental: each line filled along a pass is also filled, at the same rest frequency, along
    /// this many decoy curves (the pass reshaped as the attacker's scaled wrong places are, drawn once
    /// per pass, see `decoyPasses`). Filling only along the truth changes cells that wrong places'
    /// curves cross and the truth's own best lines, parallel to the strips, never do
    /// (docs/EXPERIMENTS.md); decoys give the wrong places the same treatment.
    public var decoys = 0
    /// Decoys' spread: log a and log b each uniform within ± this, the offset within ± `decoyOffset` s.
    static let decoyLogSpread = 0.5, decoyOffset = 5.0
    /// Raising: rounds per pass, and the most any strip is raised in all, dB.
    public var maxRaises = 6
    public var maxGainDB = 10.0
    /// Under the null target, removal goes on while z is at least this, whatever the score.
    public var strongZ = 3.0
    /// Under the null target, each filled tone's multiples up to this one are filled with it (1:
    /// none). Off: it was tuned on a synthetic engine with ×2 and ×3, and real engines' other lines
    /// are mostly not harmonics of the strongest (docs/EXPERIMENTS.md, "What real engines carry").
    public var harmonics = 1
    /// A diagnostic: when not empty, fill exactly these rest frequencies along the first expected
    /// pass's curve (no verdict, no stop) and nothing else. For asking "can the fill remove what
    /// the attacker sees, if told where?" (lab: the attacker in the loop).
    public var forcedRests: [Double] = []

    var search: PathSearch { search(window: windows.first ?? 0.17) }

    func search(window: Double) -> PathSearch {
        var p = PathSearch()
        p.band = band
        p.windowSeconds = window
        // Quarter-second blocks for the running median, closer to the attacker's exact 15 s
        // median: with 1 s blocks this search scored a real pass 5.2 where the attacker scores
        // 6.3, and stopped after two of the four tones the attacker could use; at 0.25 s, 6.4.
        p.blockSeconds = 0.25
        return p
    }

    let ratio = 1.002

    /// A pass's verdict: its best tone (rest frequency, timing offset) and how far it stands out.
    struct Tone {
        let pass: Int; let rest: Double; let offset: Double; let z: Double; let effect: Double
        /// The best mean excess itself (what the place search sums and ranks, before any z), the
        /// wrong-time scores' spread (z's unit, in mean excess) and the scores themselves.
        var score: Double = 0; var sd: Double = 1; var nulls: [Double] = []

        /// The score of one wrong time, picked by `u` in 0..<1: a draw from the attacker's null.
        func nullDraw(_ u: Double) -> Double? {
            guard nulls.count >= 6 else { return nil }
            return nulls[min(nulls.count - 1, Int(u * Double(nulls.count)))]
        }
    }

    public func process(_ x: [Double], sampleRate: Int) -> (output: [Double], summary: String) {
        let usable = expected.filter(\.isValid)
        guard !usable.isEmpty else { return (x, "tracks: no usable expected passes (\(expected.count) given)") }
        var stage = self
        stage.expected = usable
        var y = x
        var rng = SeededRNG(seed: seed)
        var fill = LineFill()
        fill.marginHz = marginHz
        fill.relativeMargin = relativeMargin
        fill.level = fillLevel
        if !forcedRests.isEmpty {
            var done: [String] = [], along = 0
            var picker = SeededRNG(seed: seed ^ 0x6465_636f_7973)
            let decoyPasses = stage.decoyPasses(for: usable[0], rng: &picker)
            for r in forcedRests {
                let tone = Tone(pass: 0, rest: r, offset: 0, z: 0, effect: 0)
                if let line = stage.track(tone, sampleRate: sampleRate, count: y.count), fill.fill(&y, line, sampleRate: sampleRate, rng: &rng) {
                    done.append("\(Int(r.rounded())) Hz")
                    along += stage.fillDecoys(decoyPasses, rest: r, &y, sampleRate: sampleRate, fill: fill, rng: &rng)
                }
            }
            return (y, "tracks: forced, filled \(done.count) tone(s)\(done.isEmpty ? "" : " (" + done.joined(separator: ", ") + ")")"
                        + (decoys > 0 ? ", and \(along) along \(decoyPasses.count) decoy(s)" : ""))
        }
        if target == .rank { return stage.rankStop(y, sampleRate: sampleRate, fill: &fill, rng: &rng) }
        var filled: [Tone] = [], open = Set(usable.indices), count = [Int](repeating: 0, count: usable.count)
        var first = [Double?](repeating: nil, count: usable.count), last = first, goal = first
        var firstScore = first, lastScore = first
        var raised = [Int](repeating: 0, count: usable.count), gainUsed = [Double](repeating: 0, count: usable.count)
        var previous: [Int: Tone] = [:]
        var lastRaise: [Int: (score: Double, gain: Double)] = [:]
        var draws = SeededRNG(seed: seed ^ 0x7461_7267_6574)     // targets apart from the fill's noise
        let rounds = maxTones + (target == .null ? maxRaises : 0)
        var prepared: [Prepared?]? = nil                        // the audio as it came, for the draws
        var round = 0
        while !open.isEmpty {
            let verdicts = stage.test(y, sampleRate: sampleRate, passes: open)
            for pi in verdicts.keys.sorted() {
                let tone = verdicts[pi] ?? nil
                if first[pi] == nil {
                    first[pi] = tone?.z
                    firstScore[pi] = tone?.score
                    // Drawn once, from the audio as it came (null), or the fixed stop.
                    if target == .null, let tone {
                        let u = Double.random(in: 0..<1, using: &draws)
                        if prepared == nil { prepared = (windows.isEmpty ? [0.17] : windows).map { stage.prepare(y, sampleRate: sampleRate, window: $0) } }
                        goal[pi] = stage.elsewhere(pi, u, prepared ?? [], duration: Double(y.count) / Double(sampleRate)) ?? tone.nullDraw(u)
                    } else {
                        goal[pi] = stopZ
                    }
                }
                last[pi] = tone?.z
                lastScore[pi] = tone?.score
                guard let tone, let aim = goal[pi], round <= rounds else { open.remove(pi); continue }
                // The null target is a score, not a z: a z divides by the spread of wrong times
                // within the pass's own stretch, which differs from stretch to stretch (music's
                // held notes), so a z drawn elsewhere doesn't translate; the score does, and it's
                // what the place search compares across curves.
                // A score at its target isn't enough on its own: the same audio along the curve's
                // neighbours (the place search's other curves, the wrong times within the stretch)
                // still sees a plane's harmonic that's left (z 3-8 at target), so removal goes on
                // while z is at least `strongZ`, and a strip that stands out that far is never the
                // one raised. Not at `stopZ`: background alone gets there often enough that
                // removing it leaves the hole again (pink noise, null-test percentile 0.39 → 0.27).
                let level = target == .null ? tone.score : tone.z
                let strong = tone.z >= strongZ
                let above = target == .null ? strong || level > aim : level >= aim
                if above && (raised[pi] == 0 || strong) {
                    guard count[pi] < maxTones else { open.remove(pi); continue }
                    // Aiming at a target: a fill that didn't lower the score is where removal stops
                    // helping (taking more of a background's best matches away tightens the wrong
                    // times' spread, and the true curve's score rises again).
                    if target == .null, !strong, let p = previous[pi], tone.score >= p.score { open.remove(pi); continue }
                    // The same tone again after filling it: the fill didn't take; stop rather than loop.
                    if let p = previous[pi], abs(p.rest / tone.rest - 1) < 0.01, abs(p.offset - tone.offset) <= 1 { open.remove(pi); continue }
                    if let line = stage.track(tone, sampleRate: sampleRate, count: y.count), fill.fill(&y, line, sampleRate: sampleRate, rng: &rng) {
                        filled.append(tone)
                        count[pi] += 1
                        previous[pi] = tone
                        // An engine's tone may come with harmonics, each along the same curve, and
                        // the search finds whichever is left (with the synthetic ×2/×3 engine, the
                        // second or third stood out after the fundamental went: room 0.96).
                        // Filled with it, unscored: if the tone was background, its multiples are
                        // just other background (other rests, not the best ones), which leaves
                        // no hole.
                        if target == .null, harmonics >= 2 {
                            for h in 2...harmonics where tone.rest * Double(h) <= restRange.upperBound {
                                let up = Tone(pass: tone.pass, rest: tone.rest * Double(h), offset: tone.offset, z: tone.z, effect: tone.effect)
                                if let line = stage.track(up, sampleRate: sampleRate, count: y.count) {
                                    _ = fill.fill(&y, line, sampleRate: sampleRate, rng: &rng)
                                }
                            }
                        }
                    } else {
                        open.remove(pi)
                    }
                } else if target == .null, !strong, level < aim - targetTolerance * tone.sd, raised[pi] < maxRaises, gainUsed[pi] < maxGainDB {
                    // Below its target: the best tone's strip, louder by what the gap is worth in mean
                    // excess (dB along the curve), no more than the cap allows.
                    // A strip's dB don't all reach the score (the excess is clipped, the search takes
                    // the best of neighbouring bins, the running median moves), so after the first
                    // raise the step comes from how far the last one moved it (at most 4× the last).
                    var gain = aim - level
                    if let (s0, g0) = lastRaise[pi], g0 > 0 {
                        let slope = (level - s0) / g0
                        gain = slope > 1e-4 ? min((aim - level) / slope, 4 * g0) : 4 * g0
                    }
                    gain = min(gain, maxGainDB - gainUsed[pi])
                    if gain >= 0.05, let line = stage.track(tone, sampleRate: sampleRate, count: y.count),
                       fill.amplify(&y, line, gainDB: gain, sampleRate: sampleRate) {
                        raised[pi] += 1
                        gainUsed[pi] += gain
                        lastRaise[pi] = (level, gain)
                    } else {
                        open.remove(pi)
                    }
                } else {
                    open.remove(pi)
                }
            }
            round += 1
        }
        let list = filled.map { "\(Int($0.rest.rounded())) Hz" }.joined(separator: ", ")
        let scores = usable.indices.compactMap { i -> String? in
            guard let a = first[i] else { return nil }
            guard target == .null, let aim = goal[i], let s = firstScore[i] else { return "\(Self.one(a)) → \(Self.one(last[i] ?? a))" }
            return "\(Self.one(a)) → \(Self.one(last[i] ?? a)), score \(Self.two(s)) → \(Self.two(lastScore[i] ?? s)) (target \(Self.two(aim)))"
        }.joined(separator: ", ")
        let lifts = raised.filter { $0 > 0 }.count
        return (y, "tracks: \(usable.count) expected pass(es), filled \(filled.count) tone(s)\(list.isEmpty ? "" : " (" + list + ")")"
                    + (target == .null ? ", raised \(lifts) pass(es)" : "")
                    + (scores.isEmpty ? "" : "; attacker z \(scores)"))
    }

    /// How many bins either side the verdict's best-of-neighbours reaches (at least 2: the Hann lobe).
    static func reach(toleranceHz: Double, binHz: Double) -> Int { max(2, Int((toleranceHz / binHz).rounded())) }

    static func one(_ z: Double) -> String { "\((z * 10).rounded() / 10)" }
    static func two(_ x: Double) -> String { "\((x * 100).rounded() / 100)" }

    /// Fills reach this far either side of the closest approach (as found), s.
    var fillHalfWindow: Double { halfWindow + maxOffset }

    /// The predicted tone as a track around the closest approach (where it was tested).
    /// `decoys` curves for a pass, drawn so that they don't point back to it. Reshaping composes by
    /// adding (log a, log b, offset), so the truth and its decoys are drawn alike: `decoys` + 1 points
    /// drawn independently, the truth taking the first, and each decoy is the pass moved by its point's
    /// difference from the truth's. Anyone who finds every processed curve then can't tell which is the
    /// pass from their arrangement: each is the truth equally often (a decoy set built around the
    /// truth has the truth at its centre). Nothing is redrawn or dropped: keeping only physical
    /// decoys would keep the ones on one side of the truth, which points back to it again. A decoy
    /// is filled wherever its curve is in the band (`fillDecoys`).
    func decoyPasses(for pass: ExpectedPass, rng: inout SeededRNG) -> [ExpectedPass] {
        guard decoys > 0 else { return [] }
        let l = Self.decoyLogSpread, o = Self.decoyOffset
        let p = (0...decoys).map { _ in (rng.uniform(-l...l), rng.uniform(-l...l), rng.uniform(-o...o)) }
        return p.dropFirst().map { pass.scaled(a: exp($0.0 - p[0].0), b: exp($0.1 - p[0].1), offset: $0.2 - p[0].2) }
    }

    /// Fills `rest` along each decoy curve, where it's below 45 % of the sample rate; how many took.
    func fillDecoys(_ passes: [ExpectedPass], rest: Double, _ y: inout [Double], sampleRate: Int, fill: LineFill, rng: inout SeededRNG) -> Int {
        var n = 0
        let top = 0.45 * Double(sampleRate)
        for d in passes {
            var one = self
            one.expected = [d]
            guard let full = one.track(Tone(pass: 0, rest: rest, offset: 0, z: 0, effect: 0), sampleRate: sampleRate, count: y.count)
            else { continue }
            let keep = full.frequencies.indices.filter { full.frequencies[$0] > 20 && full.frequencies[$0] < top }
            guard keep.count > 4 else { continue }
            let line = Track(times: keep.map { full.times[$0] }, frequencies: keep.map { full.frequencies[$0] },
                             levels: keep.map { full.levels[$0] })
            if fill.fill(&y, line, sampleRate: sampleRate, rng: &rng) { n += 1 }
        }
        return n
    }

    func track(_ tone: Tone, sampleRate: Int, count: Int) -> Track? {
        let pass = expected[tone.pass], end = Double(count) / Double(sampleRate), c = pass.center + tone.offset
        var times: [Double] = [], freqs: [Double] = []
        // Only where the tone was found: a strip filled where there is nothing to remove is pure
        // risk, since any bias in its level traces the exact curve. That's the searched window,
        // widened by the timing slack: an attacker whose track puts the closest approach a few
        // seconds elsewhere (archive positions are stale) centres its window there.
        let half = fillHalfWindow
        var t = max(0, (pass.times.first ?? 0) + tone.offset, c - half)
        while t <= min(end, (pass.times.last ?? 0) + tone.offset, c + half) {
            if let f = pass.factor(at: t - tone.offset) {
                times.append(t)
                freqs.append(tone.rest * f)
            }
            t += 0.05
        }
        guard times.count > 4 else { return nil }
        return Track(times: times, frequencies: freqs, levels: [Double](repeating: 0, count: times.count))
    }

    /// A draw from what the pass's score would be with nothing there: the same curve, shape and all,
    /// centred at another time (picked by `u`) and scored on its own stretch, as a wrong place's
    /// curve is scored. Far enough away that neither stretch nor any fill reaches the other. Nil
    /// when the audio is too short; then the wrong-time scores stand in (`Tone.nullDraw`), which
    /// move the curve within one stretch: its fall leaves the stretch and a flatter curve scores
    /// differently (higher along held notes), so they're the rougher draw.
    func elsewhere(_ pi: Int, _ u: Double, _ prepared: [Prepared?], duration end: Double) -> Double? {
        let pass = expected[pi], c = pass.center
        let gap = 2 * halfWindow + maxOffset
        // Centres for the copy: [halfWindow, c − gap] and [c + gap, end − halfWindow].
        let left = (halfWindow, c - gap), right = (c + gap, end - halfWindow)
        let lw = max(0, left.1 - left.0), rw = max(0, right.1 - right.0)
        guard lw + rw > 0 else { return nil }
        let at = u * (lw + rw) < lw ? left.0 + u * (lw + rw) : right.0 + (u * (lw + rw) - lw)
        let d = at - c
        var moved = pass
        moved.times = pass.times.map { $0 + d }
        moved.closest = c + d
        // The score of the window `test` would take (the one it stands out in most).
        let tones = prepared.compactMap { $0 }.compactMap { verdict(moved, pi, $0) }
        return tones.max { $0.z < $1.z }?.score
    }

    /// The attacker's verdict on every pass, in order.
    func verdicts(_ x: [Double], sampleRate: Int) -> [Tone?] {
        let v = test(x, sampleRate: sampleRate, passes: Set(expected.indices))
        return expected.indices.map { v[$0] ?? nil }
    }

    /// The whitened excess, ready for every pass's search.
    struct Prepared {
        let g: PathSearch.Grid
        /// Centred excess, frames × bins; and the best of ±2 bins (the curve is only as good as the track).
        let a: [Float]
        let am: [Float]
        /// Rest frequencies, `ratio` apart from `restRange.lowerBound`.
        let rests: [Double]
        /// Log-frequency index j (rest index + Doppler shift in `ratio` steps, from `jLo`) → bin, or −1.
        let binOf: [Int32]
        let jLo: Int
    }

    func prepare(_ x: [Double], sampleRate: Int, window: Double? = nil) -> Prepared? {
        let ps = window.map { search(window: $0) } ?? search
        guard let g = ps.grid(count: x.count, sampleRate: sampleRate) else { return nil }
        var a = ps.excess(x, g)
        let mean = a.reduce(0, +) / Float(a.count)
        for i in a.indices { a[i] -= mean }
        var am = a
        let reach = Self.reach(toleranceHz: toleranceHz, binHz: g.binHz)
        for m in 0..<g.frames {
            let row = m * g.bins
            for k in 0..<g.bins {
                var v = a[row + k]
                for d in 1...reach {
                    if k >= d { v = max(v, a[row + k - d]) }
                    if k + d < g.bins { v = max(v, a[row + k + d]) }
                }
                am[row + k] = v
            }
        }
        let rests = Array(sequence(first: restRange.lowerBound) { $0 * ratio < restRange.upperBound ? $0 * ratio : nil })
        // Factors 0.5–2 shift a rest by at most ±log(2)/log(ratio) steps.
        let span = Int((log(2.0) / log(ratio)).rounded(.up)) + 1
        let jLo = -span, jHi = rests.count + span
        let binOf = (jLo..<jHi).map { j -> Int32 in
            let k = Int((restRange.lowerBound * pow(ratio, Double(j)) / g.binHz).rounded()) - g.kLo
            return k >= 0 && k < g.bins ? Int32(k) : -1
        }
        return Prepared(g: g, a: a, am: am, rests: rests, binOf: binOf, jLo: jLo)
    }

    /// The attacker's verdict on each pass in `passes` (nil: it can't be tested, e.g. its closest
    /// approach is out of the audio).
    func test(_ x: [Double], sampleRate: Int, passes: Set<Int>) -> [Int: Tone?] {
        var best: [Int: Tone?] = [:]
        for w in windows.isEmpty ? [0.17] : windows {
            for (pi, tone) in test(prepare(x, sampleRate: sampleRate, window: w), passes: passes) {
                guard let tone else { if best[pi] == nil { best[pi] = .some(nil) }; continue }
                if let old = best[pi] ?? nil, old.z >= tone.z { continue }
                best[pi] = tone
            }
        }
        return best
    }

    func test(_ p: Prepared?, passes: Set<Int>) -> [Int: Tone?] {
        guard let p else { return Dictionary(uniqueKeysWithValues: passes.map { ($0, nil) }) }
        return Dictionary(uniqueKeysWithValues: passes.map { ($0, verdict(expected[$0], $0, p)) })
    }

    /// The best tone along the pass's curve and its z against the curve at wrong times.
    ///
    /// On a log-frequency axis a rest frequency times a Doppler factor is a shift, so each frame's
    /// excess is resampled once onto that axis and every rest frequency is scored at once: one
    /// contiguous add per frame for each timing (offset plus null shift), instead of a lookup per
    /// rest. Offsets and null shifts that add up to the same timing share it. Frames where a curve
    /// would leave the band score far below anything real, so only curves inside the band for
    /// every frame count, as the attacker counts them.
    func verdict(_ pass: ExpectedPass, _ pi: Int, _ p: Prepared) -> Tone? {
        let g = p.g, c = pass.center
        let frames = (0..<g.frames).filter { abs(g.time($0) - c) <= halfWindow && pass.factor(at: g.time($0)) != nil }
        guard frames.count >= 40 else { return nil }
        let R = p.rests.count, J = p.binOf.count, outside: Float = -1e9
        // Each frame's excess on the log axis.
        var rows = [Float](repeating: outside, count: frames.count * J)
        for (i, m) in frames.enumerated() {
            let base = i * J, row = m * g.bins
            for j in 0..<J where p.binOf[j] >= 0 { rows[base + j] = p.am[row + Int(p.binOf[j])] }
        }
        let lr = log(ratio)
        // The relative slack: the best within ±T log steps (a constant fraction of the frequency).
        let T = Int((log(1 + relativeTolerance) / lr).rounded())
        if T > 0 {
            var line = [Float](repeating: outside, count: J)
            for i in 0..<frames.count {
                let base = i * J
                for j in 0..<J { line[j] = rows[base + j] }
                for j in 0..<J {
                    var v = line[j]
                    for d in 1...T {
                        if j >= d { v = max(v, line[j - d]) }
                        if j + d < J { v = max(v, line[j + d]) }
                    }
                    rows[base + j] = v
                }
            }
        }
        var acc = [Float](repeating: 0, count: R)
        let width = Double(2 * Self.reach(toleranceHz: toleranceHz, binHz: g.binHz) + 1) * g.binHz
        var cache: [Int: (score: Double, rest: Double)] = [:]
        let unit = offsetStep
        // Shape 0 is the pass's curve; under `wrongPlaces`, the others are its swing scaled in depth
        // (a, in log factor) and duration (b) about its closest approach.
        var shapes: [(a: Double, b: Double)] = [(1, 1)]
        if null == .wrongPlaces {
            for a in placeScales { for b in placeScales where !(a == 1 && b == 1) { shapes.append((a, b)) } }
        }
        // Under `library`, shapes 1… are physical flights; their factor is relative to its median,
        // as the expected pass's is to its own (only the shape matters: the rest frequency is free).
        var flights: [[Double]] = []
        if null == .library {
            for v in librarySpeeds {
                for d in libraryDistances {
                    let f = Self.flight(speed: v, distance: d)
                    let med = f.sorted()[f.count / 2]
                    flights.append(f.map { $0 / med })
                    shapes.append((0, 0))
                }
            }
        }
        let limit = log(1.95)
        func factor(_ shape: Int, _ t: Double) -> Double? {
            if null == .library && shape > 0 {
                let f = flights[shape - 1], i = (t - c) / 0.1 + 900
                guard i >= 0, i <= Double(f.count - 1) else { return nil }
                let k = Int(i), w = i - Double(k)
                let v = f[k] + (f[min(k + 1, f.count - 1)] - f[k]) * w
                return exp(min(max(log(v), -limit), limit))
            }
            let (a, b) = shapes[shape]
            if a == 1 && b == 1 { return pass.factor(at: t) }
            guard let f = pass.factor(at: c + (t - c) / b) else { return nil }
            return exp(min(max(a * log(f), -limit), limit))
        }
        /// The best mean excess with shape `shape` moved by `tau` s.
        func best(_ tau: Double, shape: Int = 0) -> (score: Double, rest: Double) {
            let key = Int((tau / unit).rounded()) &* 64 &+ shape
            if let hit = cache[key] { return hit }
            for i in 0..<R { acc[i] = 0 }
            var known = 0
            acc.withUnsafeMutableBufferPointer { out in
                rows.withUnsafeBufferPointer { src in
                    for (i, m) in frames.enumerated() {
                        guard let f = factor(shape, g.time(m) - tau) else { continue }
                        known += 1
                        let start = i * J + Int((log(f) / lr).rounded()) - p.jLo
                        let row = src.baseAddress! + start
                        for r in 0..<R { out[r] += row[r] }
                    }
                }
            }
            var top = (score: -Double.infinity, rest: 0.0)
            if known >= 40 {
                var bi = 0
                for i in 1..<R where acc[i] > acc[bi] { bi = i }
                var total = Double(acc[bi])
                var picked = [p.rests[bi]]
                while picked.count < lines {
                    var bj = -1
                    for i in 0..<R where bj < 0 || acc[i] > acc[bj] {
                        if picked.allSatisfy({ abs(p.rests[i] - $0) >= width }) { bj = i }
                    }
                    guard bj >= 0, Double(acc[bj]) / Double(known) > -1e6 else { break }
                    total += Double(acc[bj]); picked.append(p.rests[bj])
                }
                let mean = total / Double(known)
                if mean > -1e6 { top = (mean, p.rests[bi]) }
            }
            cache[key] = top
            return top
        }
        let offsets = Array(stride(from: -maxOffset, through: maxOffset + 1e-9, by: offsetStep))
        // Every curve, true or wrong, gets the same timing slack: the best over `offsets`.
        func best(shift: Double, shape: Int = 0) -> (score: Double, rest: Double, offset: Double) {
            var top = (score: -Double.infinity, rest: 0.0, offset: 0.0)
            for o in offsets {
                let b = best(shift + o, shape: shape)
                if b.score > top.score { top = (b.score, b.rest, o) }
            }
            return top
        }
        let real = best(shift: 0)
        guard real.score.isFinite else { return nil }
        let nulls: [Double]
        switch null {
        case .wrongTimes:
            nulls = nullShifts.map { best(shift: $0).score }.filter(\.isFinite)
        case .wrongPlaces, .library:
            nulls = (1..<shapes.count).flatMap { sh in placeOffsets.map { best(shift: $0, shape: sh).score } }.filter(\.isFinite)
        }
        guard nulls.count >= 6 else { return nil }
        let mean = DSP.mean(nulls), sd = max(DSP.standardDeviation(nulls), 1e-3)
        return Tone(pass: pi, rest: real.rest, offset: real.offset, z: (real.score - mean) / sd, effect: real.score - mean, score: real.score, sd: sd, nulls: nulls)
    }
}
