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
    /// dip"). `.null`: a target drawn for each pass from the attacker's own null (the same score
    /// at a random wrong time, against the other wrong times); removal while the score is above
    /// it, and while it's below, the strip along the best tone's curve raised (the sound already
    /// there, louder) up to it. The true curve's score is then a draw from the null whatever was
    /// there: neither a bump nor a hole.
    public enum Target: String, Sendable { case fixed, null }
    public var target: Target = .fixed
    /// How close to its target a pass's score has to get (z), raising.
    public var targetTolerance = 0.25
    /// Raising: rounds per pass, and the most any strip is raised in all, dB.
    public var maxRaises = 3
    public var maxGainDB = 10.0

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
        /// The wrong-time scores' spread (z's unit, in mean excess) and the scores themselves.
        var sd: Double = 1; var nulls: [Double] = []

        /// The score of one wrong time, picked by `u` in 0..<1, against the other wrong times: a
        /// draw from the attacker's null.
        func nullDraw(_ u: Double) -> Double? {
            guard nulls.count >= 6 else { return nil }
            let k = min(nulls.count - 1, Int(u * Double(nulls.count)))
            var others = nulls
            let x = others.remove(at: k)
            return (x - DSP.mean(others)) / max(DSP.standardDeviation(others), 1e-3)
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
        var filled: [Tone] = [], open = Set(usable.indices), count = [Int](repeating: 0, count: usable.count)
        var first = [Double?](repeating: nil, count: usable.count), last = first, goal = first
        var raised = [Int](repeating: 0, count: usable.count), gainUsed = [Double](repeating: 0, count: usable.count)
        var previous: [Int: Tone] = [:]
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
                guard let tone, let aim = goal[pi], round <= rounds else { open.remove(pi); continue }
                let above = target == .null ? tone.z > aim : tone.z >= aim
                if above && raised[pi] == 0 {
                    guard count[pi] < maxTones else { open.remove(pi); continue }
                    // Aiming at a target: a fill that didn't lower the score is where removal stops
                    // helping (taking more of a background's best matches away tightens the wrong
                    // times' spread, and the true curve's score rises again).
                    if target == .null, let p = previous[pi], tone.z >= p.z { open.remove(pi); continue }
                    // The same tone again after filling it: the fill didn't take; stop rather than loop.
                    if let p = previous[pi], abs(p.rest / tone.rest - 1) < 0.01, abs(p.offset - tone.offset) <= 1 { open.remove(pi); continue }
                    if let line = stage.track(tone, sampleRate: sampleRate, count: y.count), fill.fill(&y, line, sampleRate: sampleRate, rng: &rng) {
                        filled.append(tone)
                        count[pi] += 1
                        previous[pi] = tone
                    } else {
                        open.remove(pi)
                    }
                } else if target == .null, tone.z < aim - targetTolerance, raised[pi] < maxRaises, gainUsed[pi] < maxGainDB {
                    // Below its target: the best tone's strip, louder by what the gap is worth in mean
                    // excess (dB along the curve), no more than the cap allows.
                    let gain = min((aim - tone.z) * tone.sd, maxGainDB - gainUsed[pi])
                    if gain >= 0.05, let line = stage.track(tone, sampleRate: sampleRate, count: y.count),
                       fill.amplify(&y, line, gainDB: gain, sampleRate: sampleRate) {
                        raised[pi] += 1
                        gainUsed[pi] += gain
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
            let aim = target == .null ? goal[i].map { " (target \(Self.one($0)))" } ?? "" : ""
            return "\(Self.one(a)) → \(Self.one(last[i] ?? a))\(aim)"
        }.joined(separator: ", ")
        let lifts = raised.filter { $0 > 0 }.count
        return (y, "tracks: \(usable.count) expected pass(es), filled \(filled.count) tone(s)\(list.isEmpty ? "" : " (" + list + ")")"
                    + (target == .null ? ", raised \(lifts) pass(es)" : "")
                    + (scores.isEmpty ? "" : "; attacker z \(scores)"))
    }

    static func one(_ z: Double) -> String { "\((z * 10).rounded() / 10)" }

    /// Fills reach this far either side of the closest approach (as found), s.
    var fillHalfWindow: Double { halfWindow + maxOffset }

    /// The predicted tone as a track around the closest approach (where it was tested).
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
        // The best over the analysis windows, as `test` takes it.
        let zs = prepared.compactMap { $0 }.compactMap { verdict(moved, pi, $0)?.z }
        return zs.max()
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
        let reach = max(2, Int((toleranceHz / g.binHz).rounded()))
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
        var cache: [Int: (score: Double, rest: Double)] = [:]
        let unit = offsetStep
        /// The best mean excess with the curve moved by `tau` s.
        func best(_ tau: Double) -> (score: Double, rest: Double) {
            let key = Int((tau / unit).rounded())
            if let hit = cache[key] { return hit }
            for i in 0..<R { acc[i] = 0 }
            var known = 0
            acc.withUnsafeMutableBufferPointer { out in
                rows.withUnsafeBufferPointer { src in
                    for (i, m) in frames.enumerated() {
                        guard let f = pass.factor(at: g.time(m) - tau) else { continue }
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
                let mean = Double(acc[bi]) / Double(known)
                if mean > -1e6 { top = (mean, p.rests[bi]) }
            }
            cache[key] = top
            return top
        }
        let offsets = Array(stride(from: -maxOffset, through: maxOffset + 1e-9, by: offsetStep))
        func best(shift: Double) -> (score: Double, rest: Double, offset: Double) {
            var top = (score: -Double.infinity, rest: 0.0, offset: 0.0)
            for o in offsets {
                let b = best(shift + o)
                if b.score > top.score { top = (b.score, b.rest, o) }
            }
            return top
        }
        let real = best(shift: 0)
        guard real.score.isFinite else { return nil }
        let nulls = nullShifts.map { best(shift: $0).score }.filter(\.isFinite)
        guard nulls.count >= 6 else { return nil }
        let mean = DSP.mean(nulls), sd = max(DSP.standardDeviation(nulls), 1e-3)
        return Tone(pass: pi, rest: real.rest, offset: real.offset, z: (real.score - mean) / sd, effect: real.score - mean, sd: sd, nulls: nulls)
    }
}
