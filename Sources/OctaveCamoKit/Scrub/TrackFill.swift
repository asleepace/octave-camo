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
    /// Remove until the attacker-equivalent z is below this. Below 3 for margin: the lab's attacker
    /// whitens with an exact 15 s running median and scores about 10 % higher than this search.
    public var stopZ = 2.5
    /// Tones filled per pass at most (an engine has several: fan, shaft orders, harmonics).
    public var maxTones = 8
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
    public var seed: UInt64 = .random(in: 1...UInt64.max)

    public init() {}

    var search: PathSearch {
        var p = PathSearch()
        p.band = band
        // Quarter-second blocks for the running median, closer to the attacker's exact 15 s
        // median: with 1 s blocks this search scored a real pass 5.2 where the attacker scores
        // 6.3, and stopped after two of the four tones the attacker could use; at 0.25 s, 6.4.
        p.blockSeconds = 0.25
        return p
    }

    let ratio = 1.002

    /// A pass's verdict: its best tone (rest frequency, timing offset) and how far it stands out.
    struct Tone { let pass: Int; let rest: Double; let offset: Double; let z: Double; let effect: Double }

    public func process(_ x: [Double], sampleRate: Int) -> (output: [Double], summary: String) {
        let usable = expected.filter(\.isValid)
        guard !usable.isEmpty else { return (x, "tracks: no usable expected passes (\(expected.count) given)") }
        var stage = self
        stage.expected = usable
        var y = x
        var rng = SeededRNG(seed: seed)
        var fill = LineFill()
        fill.marginHz = marginHz
        var filled: [Tone] = [], open = Set(usable.indices), count = [Int](repeating: 0, count: usable.count)
        var first = [Double?](repeating: nil, count: usable.count), last = first
        var previous: [Int: Tone] = [:]
        var round = 0
        while !open.isEmpty {
            let verdicts = stage.test(y, sampleRate: sampleRate, passes: open)
            for (pi, tone) in verdicts {
                if first[pi] == nil { first[pi] = tone?.z }
                last[pi] = tone?.z
                guard let tone, tone.z >= stopZ, count[pi] < maxTones, round <= maxTones else { open.remove(pi); continue }
                // The same tone again after filling it: the fill didn't take; stop rather than loop.
                if let p = previous[pi], abs(p.rest / tone.rest - 1) < 0.01, abs(p.offset - tone.offset) <= 1 { open.remove(pi); continue }
                if let line = stage.track(tone, sampleRate: sampleRate, count: y.count), fill.fill(&y, line, sampleRate: sampleRate, rng: &rng) {
                    filled.append(tone)
                    count[pi] += 1
                    previous[pi] = tone
                } else {
                    open.remove(pi)
                }
            }
            round += 1
        }
        let list = filled.map { "\(Int($0.rest.rounded())) Hz" }.joined(separator: ", ")
        let scores = usable.indices.compactMap { i -> String? in
            guard let a = first[i] else { return nil }
            return "\(Self.one(a)) → \(Self.one(last[i] ?? a))"
        }.joined(separator: ", ")
        return (y, "tracks: \(usable.count) expected pass(es), filled \(filled.count) tone(s)\(list.isEmpty ? "" : " (" + list + ")")"
                    + (scores.isEmpty ? "" : "; attacker z \(scores)"))
    }

    static func one(_ z: Double) -> String { "\((z * 10).rounded() / 10)" }

    /// The predicted tone as a track around the closest approach (where it was tested).
    func track(_ tone: Tone, sampleRate: Int, count: Int) -> Track? {
        let pass = expected[tone.pass], end = Double(count) / Double(sampleRate), c = pass.center + tone.offset
        var times: [Double] = [], freqs: [Double] = []
        // Only where the tone was found: a strip filled where there is nothing to remove is pure
        // risk, since any bias in its level traces the exact curve.
        var t = max(0, (pass.times.first ?? 0) + tone.offset, c - halfWindow)
        while t <= min(end, (pass.times.last ?? 0) + tone.offset, c + halfWindow) {
            if let f = pass.factor(at: t - tone.offset) {
                times.append(t)
                freqs.append(tone.rest * f)
            }
            t += 0.05
        }
        guard times.count > 4 else { return nil }
        return Track(times: times, frequencies: freqs, levels: [Double](repeating: 0, count: times.count))
    }

    /// The attacker's verdict on every pass, in order.
    func verdicts(_ x: [Double], sampleRate: Int) -> [Tone?] {
        let v = test(x, sampleRate: sampleRate, passes: Set(expected.indices))
        return expected.indices.map { v[$0] ?? nil }
    }

    /// The attacker's verdict on each pass in `passes` (nil: it can't be tested, e.g. its closest
    /// approach is out of the audio).
    func test(_ x: [Double], sampleRate: Int, passes: Set<Int>) -> [Int: Tone?] {
        let ps = search
        guard let g = ps.grid(count: x.count, sampleRate: sampleRate) else { return Dictionary(uniqueKeysWithValues: passes.map { ($0, nil) }) }
        var a = ps.excess(x, g)
        let mean = a.reduce(0, +) / Float(a.count)
        for i in a.indices { a[i] -= mean }
        // Best of ±2 bins (the curve is only as good as the track).
        var am = a
        for m in 0..<g.frames {
            let row = m * g.bins
            for k in 0..<g.bins {
                var v = a[row + k]
                for d in 1...2 {
                    if k >= d { v = max(v, a[row + k - d]) }
                    if k + d < g.bins { v = max(v, a[row + k + d]) }
                }
                am[row + k] = v
            }
        }
        let rests = Array(sequence(first: restRange.lowerBound) { $0 * ratio < restRange.upperBound ? $0 * ratio : nil })
        return Dictionary(uniqueKeysWithValues: passes.map { ($0, verdict(expected[$0], $0, am, g, rests)) })
    }

    /// The best tone along the pass's curve and its z against the curve at wrong times.
    func verdict(_ pass: ExpectedPass, _ pi: Int, _ a: [Float], _ g: PathSearch.Grid, _ rests: [Double]) -> Tone? {
        let c = pass.center
        let frames = (0..<g.frames).filter { abs(g.time($0) - c) <= halfWindow && pass.factor(at: g.time($0)) != nil }
        guard frames.count >= 40 else { return nil }
        var factors = [Double](repeating: .nan, count: frames.count)
        let offsets = Array(stride(from: -maxOffset, through: maxOffset + 1e-9, by: offsetStep))
        // The best mean excess over rest frequencies and offsets, with the curve moved by `shift`.
        func best(shift: Double) -> (score: Double, rest: Double, offset: Double) {
            var top = (score: -Double.infinity, rest: 0.0, offset: 0.0)
            for o in offsets {
                for (i, m) in frames.enumerated() { factors[i] = pass.factor(at: g.time(m) - shift - o) ?? .nan }
                let known = factors.reduce(0) { $1.isNaN ? $0 : $0 + 1 }
                for r in rests {
                    var sum = 0.0, n = 0
                    for (i, m) in frames.enumerated() where !factors[i].isNaN {
                        let k = Int((r * factors[i] / g.binHz).rounded()) - g.kLo
                        guard k >= 0, k < g.bins else { continue }
                        sum += Double(a[m * g.bins + k])
                        n += 1
                    }
                    // Only curves inside the band for every frame, as the attacker counts them: a
                    // curve half off the band's edge averages fewer, noisier frames.
                    if n >= 40, n == known, sum / Double(n) > top.score { top = (sum / Double(n), r, o) }
                }
            }
            return top
        }
        let real = best(shift: 0)
        guard real.score.isFinite else { return nil }
        let nulls = nullShifts.map { best(shift: $0).score }.filter(\.isFinite)
        guard nulls.count >= 6 else { return nil }
        let mean = DSP.mean(nulls), sd = max(DSP.standardDeviation(nulls), 1e-3)
        return Tone(pass: pi, rest: real.rest, offset: real.offset, z: (real.score - mean) / sd, effect: real.score - mean)
    }
}
