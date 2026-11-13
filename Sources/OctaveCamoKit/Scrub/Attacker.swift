#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WASILibc)
import WASILibc
#endif

/// The scoring attacker (THREAT_MODEL.md, "The attacker every result is scored against"), ported
/// from the lab so the cloak can judge a pass the way it will be judged:
///
/// - lab/detect.py's whitening with lab/locate.py's settings: a 0.17 s Hann STFT (scipy's framing),
///   80–4000 Hz, each bin over its exact 15 s running median, minus each frame's median, clipped to
///   −3…12 dB, then the best of ±2 bins;
/// - lab/locate.py's `Scene._profile` and `lines_of`: the mean excess along f0·factor at every rest
///   frequency on a 0.2 % log grid (100–3500 Hz), over the frames within 25 s of the closest
///   approach, and the four best separate lines added up;
/// - ranked against wrong places at lab/zenodo.py's ±6 s offsets, ties halved: by default the
///   truth's own curve scaled (lab/geometry.py's `scaled`), or physical flights (its `library`).
///
/// With `wrong = .scaled` (the default) that is `zenodo.u(scene, p, [p] + geometry.scaled(p), offset, 4)`;
/// with `.library`, the same against `geometry.library()`. The lab subtracts the whole
/// clip's mean excess first; that shifts every curve's score alike and leaves ranks and picks
/// unchanged, so the scene here is only the stretch around the pass.
public struct Attacker {
    public var lines = 4
    public var band: ClosedRange<Double> = 80...4_000
    public var fftSeconds = 0.17
    public var referenceSeconds = 15.0
    public var clip: ClosedRange<Double> = -3...12
    public var halfWindow = 25.0
    public var minFrames = 80
    public var speeds: [Double] = [60, 90, 130, 180, 230]
    public var distances: [Double] = [400, 800, 1_500, 3_000, 5_000]
    /// Which wrong places the truth is ranked against: physical flights (`library`), or the truth's
    /// own flight as other places hear it, its swing scaled in depth and duration about the closest
    /// approach (`scaled`; lab/geometry.py's `scaled`). The scaled set tracks the scoring
    /// attacker's corpus ranks far better on real audio (docs/EXPERIMENTS.md, "The cloak judges
    /// like the attacker"): the library's far, flat flights match a real background's steady lines.
    public enum Wrong: String, Sendable { case library, scaled }
    public var wrong = Wrong.scaled
    public var scales: [Double] = [0.6, 1, 1.6]
    /// A wrong place's closest approach, around the truth's (numpy's arange(-6, 6.01, 1.5)).
    public var offsets: [Double] = (0...8).map { -6 + 1.5 * Double($0) }

    static let step = 0.002
    static let tolBins = 2
    /// numpy's exp(arange(log 100, log 3500, 0.002)).
    static let rests: [Double] = {
        let lo = log(100.0), n = Int(((log(3_500.0) - lo) / step).rounded(.up))
        return (0..<n).map { exp(lo + Double($0) * step) }
    }()
    /// Log-axis rows either side for factors 0.5–2.
    static let facRows = Int((log(2.0) / step).rounded(.up))

    public init() {}

    /// What the attacker makes of one pass.
    public struct Verdict {
        /// Where the truth's score falls among the wrong places' (0…1, ties halved).
        public let rank: Double
        public let score: Double
        public let nulls: Int
        /// The lines it added up: (rest frequency, mean excess), best first.
        public let picks: [(rest: Double, value: Double)]
    }

    // MARK: The scene

    struct Scene {
        /// Frame centres, s of audio time (scipy's framing: frame m is centred at m·hop/sr).
        let times: [Double]
        let bins: Int, df: Double, f0: Double
        /// Frames × bins: whitened excess, best of ±2 bins.
        let am: [Float]
    }

    /// The whitened scene over `range` (s) of the audio, with enough around it that every frame
    /// in the range has its full running-median span (where the audio allows).
    func scene(_ x: [Double], sampleRate: Int, range: ClosedRange<Double>) -> Scene? {
        let sr = Double(sampleRate)
        let n = Int(pow(2, (log2(fftSeconds * sr)).rounded()))
        let hop = n / 4, pad = n / 2
        // scipy.signal.stft: n/2 zeros either side, then zeros until the frames fit exactly.
        let padded = x.count + 2 * pad
        let extra = ((-(padded - n)) % hop + hop) % hop
        let total = padded + extra
        guard total >= n else { return nil }
        let frames = 1 + (total - n) / hop
        let dt = Double(hop) / sr
        let w = Int((referenceSeconds / dt).rounded()) | 1, h = w / 2
        let mLo = max(0, Int((range.lowerBound / dt).rounded(.down)) - h - 1)
        let mHi = min(frames - 1, Int((range.upperBound / dt).rounded(.up)) + h + 1)
        guard mHi > mLo else { return nil }
        let binHz = sr / Double(n)
        let kLo = Int((band.lowerBound / binHz).rounded(.up)), kHi = min(n / 2, Int((band.upperBound / binHz).rounded(.down)))
        guard kHi > kLo else { return nil }
        let bins = kHi - kLo + 1, count = mHi - mLo + 1
        // Periodic Hann (scipy's 'hann'), spectrum scaling (1 / window sum).
        let window = (0..<n).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n)) }
        let scale = 1 / window.reduce(0, +)
        let fft = RealFFT(size: n)
        var frame = [Double](repeating: 0, count: n)
        var re = [Double](repeating: 0, count: fft.binCount), im = re
        var power = [Double](repeating: 0, count: count * bins)        // bins × frames (per-bin runs)
        for (mi, m) in (mLo...mHi).enumerated() {
            let start = m * hop - pad                                    // in the unpadded audio
            for i in 0..<n {
                let s = start + i
                frame[i] = s >= 0 && s < x.count ? x[s] * window[i] : 0
            }
            fft.forward(frame, &re, &im)
            for k in 0..<bins {
                let b = kLo + k, r = re[b] * scale, q = im[b] * scale
                power[k * count + mi] = r * r + q * q
            }
        }
        // Exact running median over w frames per bin, 'nearest' at the ends.
        var level = [Double](repeating: 0, count: count * bins)        // frames × bins
        for k in 0..<bins {
            let run = Array(power[(k * count)..<((k + 1) * count)])
            let ref = Self.runningMedian(run, window: w)
            for mi in 0..<count { level[mi * bins + k] = 10 * log10(run[mi] / (ref[mi] + 1e-30) + 1e-12) }
        }
        // Minus each frame's median over the band (numpy's: the mean of the middle two when even), clipped.
        var a = [Float](repeating: 0, count: count * bins)
        var row = [Double](repeating: 0, count: bins)
        let lo = clip.lowerBound, hi = clip.upperBound
        for mi in 0..<count {
            for k in 0..<bins { row[k] = level[mi * bins + k] }
            row.sort()
            let med = bins % 2 == 1 ? row[bins / 2] : 0.5 * (row[bins / 2 - 1] + row[bins / 2])
            for k in 0..<bins { a[mi * bins + k] = Float(min(hi, max(lo, level[mi * bins + k] - med))) }
        }
        var am = a
        for mi in 0..<count {
            let r = mi * bins
            for k in 0..<bins {
                var v = a[r + k]
                for d in 1...Self.tolBins {
                    if k >= d { v = max(v, a[r + k - d]) }
                    if k + d < bins { v = max(v, a[r + k + d]) }
                }
                am[r + k] = v
            }
        }
        return Scene(times: (mLo...mHi).map { Double($0) * dt }, bins: bins, df: binHz, f0: Double(kLo) * binHz, am: am)
    }

    /// scipy.ndimage.median_filter along one axis: an odd `window`, 'nearest' beyond the ends.
    static func runningMedian(_ v: [Double], window w: Int) -> [Double] {
        guard !v.isEmpty else { return [] }
        let h = w / 2, n = v.count
        func at(_ i: Int) -> Double { v[min(max(i, 0), n - 1)] }
        var sorted = (-h...h).map(at).sorted()
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            if i > 0 {
                remove(at(i - 1 - h), from: &sorted)
                insert(at(i + h), into: &sorted)
            }
            out[i] = sorted[h]
        }
        return out
    }

    static func insert(_ v: Double, into s: inout [Double]) {
        var lo = 0, hi = s.count
        while lo < hi { let mid = (lo + hi) / 2; if s[mid] < v { lo = mid + 1 } else { hi = mid } }
        s.insert(v, at: lo)
    }

    static func remove(_ v: Double, from s: inout [Double]) {
        var lo = 0, hi = s.count
        while lo < hi { let mid = (lo + hi) / 2; if s[mid] < v { lo = mid + 1 } else { hi = mid } }
        if lo < s.count && s[lo] == v { s.remove(at: lo) }
    }

    // MARK: Curves

    /// The frames within `halfWindow` of `center`, on the log-frequency axis: frames × rows, NaN
    /// where a row is outside the band. Row r is the rest grid's frequency r − facRows steps up.
    struct Rows {
        let frames: [Int]
        let width: Int
        let g: [Double]
    }

    func rows(_ s: Scene, center c: Double) -> Rows {
        let j = s.times.indices.filter { abs(s.times[$0] - c) <= halfWindow }
        let R = Self.rests.count, width = R + 2 * Self.facRows, lo = log(Self.rests[0])
        let binOf = (0..<width).map { r -> Int in
            let f = exp(lo + Double(r - Self.facRows) * Self.step)
            let b = Int(((f - s.f0) / s.df).rounded(.toNearestOrEven))
            return b >= 0 && b < s.bins ? b : -1
        }
        var g = [Double](repeating: .nan, count: j.count * width)
        for (i, m) in j.enumerated() {
            for r in 0..<width where binOf[r] >= 0 { g[i * width + r] = Double(s.am[m * s.bins + binOf[r]]) }
        }
        return Rows(frames: j, width: width, g: g)
    }

    /// Mean excess along f0·factor for every rest frequency (NaN where the curve leaves the band);
    /// nil when fewer than `minFrames` frames have a factor in 0.5–2.
    func profile(_ s: Scene, _ rows: Rows, factor: (Double) -> Double?) -> [Double]? {
        let R = Self.rests.count
        var total = [Double](repeating: 0, count: R)
        var used = 0
        total.withUnsafeMutableBufferPointer { out in
            rows.g.withUnsafeBufferPointer { src in
                for (i, m) in rows.frames.enumerated() {
                    guard let f = factor(s.times[m]), f.isFinite, f > 0.5, f < 2 else { continue }
                    used += 1
                    let shift = Int((log(f) / Self.step).rounded(.toNearestOrEven))
                    let row = src.baseAddress! + i * rows.width + Self.facRows + shift
                    for r in 0..<R { out[r] += row[r] }
                }
            }
        }
        guard used >= minFrames else { return nil }
        for r in 0..<R { total[r] /= Double(used) }
        return total
    }

    /// The `lines` best rest frequencies, each at least (2·2 + 1) bins from the others (lab's
    /// `line_picks`).
    func picks(_ total: [Double], df: Double) -> [(rest: Double, value: Double)] {
        var v = total.map { $0.isFinite ? $0 : -Double.infinity }
        let width = Double(2 * Self.tolBins + 1) * df
        var out: [(rest: Double, value: Double)] = []
        for _ in 0..<lines {
            var bi = 0
            for i in 1..<v.count where v[i] > v[bi] { bi = i }
            guard v[bi].isFinite else { break }
            out.append((Self.rests[bi], v[bi]))
            let f = Self.rests[bi]
            for i in v.indices where abs(Self.rests[i] - f) < width { v[i] = -.infinity }
        }
        return out
    }

    // MARK: Wrong places

    /// lab/geometry.py's `curve`: (times relative to the steepest fall, factors), as numpy computes it.
    static func flight(speed v: Double, distance d: Double) -> (t: [Double], f: [Double]) {
        let c = 343.0
        let nTau = Int((240 / 0.025).rounded(.up))
        var t = [Double](repeating: 0, count: nTau), f = t
        for i in 0..<nTau {
            let tau = -120 + Double(i) * 0.025, s = v * tau, r = (d * d + s * s).squareRoot()
            t[i] = tau + r / c
            f[i] = 1 / (1 + v * s / (r * c))
        }
        let i0 = argmin(gradient(f, t))
        let grid = (0..<1801).map { -90 + Double($0) * 0.1 }
        let fg = grid.map { interp($0 + t[i0], t, f) }
        let tc = grid[argmin(gradient(fg, grid))]
        return (grid.map { $0 - tc }, fg)
    }

    /// numpy.gradient along `x` (second order inside, first order at the ends).
    static func gradient(_ f: [Double], _ x: [Double]) -> [Double] {
        let n = f.count
        var g = [Double](repeating: 0, count: n)
        g[0] = (f[1] - f[0]) / (x[1] - x[0])
        g[n - 1] = (f[n - 1] - f[n - 2]) / (x[n - 1] - x[n - 2])
        for i in 1..<(n - 1) {
            let h1 = x[i] - x[i - 1], h2 = x[i + 1] - x[i]
            g[i] = -h2 / (h1 * (h1 + h2)) * f[i - 1] + (h2 - h1) / (h1 * h2) * f[i] + h1 / (h2 * (h1 + h2)) * f[i + 1]
        }
        return g
    }

    static func argmin(_ v: [Double]) -> Int {
        var b = 0
        for i in 1..<v.count where v[i] < v[b] { b = i }
        return b
    }

    /// numpy.interp: linear, held at the end values.
    static func interp(_ q: Double, _ x: [Double], _ y: [Double]) -> Double {
        if q <= x[0] { return y[0] }
        if q >= x[x.count - 1] { return y[y.count - 1] }
        var lo = 0, hi = x.count - 1
        while hi - lo > 1 { let mid = (lo + hi) / 2; if x[mid] <= q { lo = mid } else { hi = mid } }
        let w = (q - x[lo]) / (x[hi] - x[lo])
        return y[lo] + (y[hi] - y[lo]) * w
    }

    /// The library's shapes, each over its median (only the shape matters: the rest is free).
    static let library = Locked<[String: [(t: [Double], f: [Double])]]>([:])

    func shapes() -> [(t: [Double], f: [Double])] {
        let key = "\(speeds)|\(distances)"
        if let hit = Self.library.withLock({ $0[key] }) { return hit }
        var out: [(t: [Double], f: [Double])] = []
        for v in speeds {
            for d in distances {
                let (t, f) = Self.flight(speed: v, distance: d)
                let s = f.sorted(), med = s.count % 2 == 1 ? s[s.count / 2] : 0.5 * (s[s.count / 2 - 1] + s[s.count / 2])
                out.append((t, f.map { $0 / med }))
            }
        }
        Self.library.withLock { $0[key] = out }
        return out
    }

    // MARK: The verdict

    /// The attacker's verdict on `pass` in `x`; nil when the truth can't be scored (too few
    /// frames, or its curve leaves the band at every rest frequency) or no wrong place can.
    public func judge(_ x: [Double], sampleRate: Int, pass: ExpectedPass) -> Verdict? {
        let c = pass.center
        guard let s = scene(x, sampleRate: sampleRate, range: (c - halfWindow)...(c + halfWindow)) else { return nil }
        let r = rows(s, center: c)
        guard let truth = profile(s, r, factor: { pass.factor(at: $0) }) else { return nil }
        let top = picks(truth, df: s.df)
        guard !top.isEmpty else { return nil }
        let s0 = top.reduce(0) { $0 + $1.value }
        var nulls: [Double] = []
        func add(_ factor: (Double) -> Double?) {
            guard let p = profile(s, r, factor: factor) else { return }
            let q = picks(p, df: s.df)
            if !q.isEmpty { nulls.append(q.reduce(0) { $0 + $1.value }) }
        }
        switch wrong {
        case .library:
            for shape in shapes() { for o in offsets { add { Self.interp($0 - c - o, shape.t, shape.f) } } }
        case .scaled:
            for a in scales {
                for b in scales where !(a == 1 && b == 1) {
                    for o in offsets { add { t in pass.factor(at: c + (t - c - o) / b).map { exp(a * log($0)) } } }
                }
            }
        }
        guard !nulls.isEmpty else { return nil }
        let below = Double(nulls.filter { $0 < s0 }.count), tied = Double(nulls.filter { $0 == s0 }.count)
        return Verdict(rank: (below + 0.5 * tied) / Double(nulls.count), score: s0, nulls: nulls.count, picks: top)
    }
}

extension TrackFill {
    /// The rank target (`target == .rank`): judge each pass as the scoring attacker does
    /// (`Attacker`), and act only on evidence. A pass ranking below `actAbove` among wrong places
    /// is left alone: with nothing there its rank is a fair draw already, and removing chance
    /// matches is what leaves a hole. Otherwise the cloak draws a target uniform on 0…1 and fills
    /// the attacker's best line, one at a time, re-judging after each, until the rank is at or
    /// below the target (or `rankRounds` fills). A real pass then lands at a random rank; with
    /// nothing there only the top (1 − `actAbove`) is touched, and it's spread over 0…1.
    func rankStop(_ x: [Double], sampleRate: Int, fill: inout LineFill, rng: inout SeededRNG) -> (output: [Double], summary: String) {
        var y = x
        var attacker = Attacker()
        attacker.wrong = rankWrong
        // Targets apart from the fill's noise, and different for every clip even under one fixed
        // seed: a seed reused across videos must not land them all at the same rank.
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ v: UInt64) { h = (h ^ v) &* 0x100_0000_01b3 }
        mix(UInt64(x.count))
        for i in stride(from: 0, to: x.count, by: max(1, x.count / 4_096)) { mix(x[i].bitPattern) }
        for p in expected { mix(p.center.bitPattern) }
        var draws = SeededRNG(seed: seed ^ 0x7261_6e6b ^ h)
        var filled: [Double] = [], notes: [String] = [], along = 0, decoyCount = 0
        func three(_ v: Double) -> String { "\((v * 1000).rounded() / 1000)" }
        for (pi, pass) in expected.enumerated() {
            let goal = Double.random(in: 0..<1, using: &draws)  // drawn for every pass, so passes keep their draws
            guard var v = attacker.judge(y, sampleRate: sampleRate, pass: pass) else { notes.append("untestable"); continue }
            let start = v.rank
            guard start >= actAbove else { notes.append("\(three(start)) (left alone)"); continue }
            var picker = SeededRNG(seed: seed ^ 0x6465_636f_7973 ^ h &+ UInt64(pi))
            let decoyPasses = decoyPasses(for: pass, rng: &picker)
            decoyCount += decoyPasses.count
            var mine: [Double] = [], attempts = 0, why = ""
            while v.rank > goal {
                guard attempts < rankRounds else { why = rankRounds > 0 ? " out of fills" : ""; break }
                // The best line not yet filled twice (a fill that didn't take shows up again nearby).
                guard let pick = v.picks.first(where: { p in mine.filter { abs($0 / p.rest - 1) < 0.01 }.count < 2 }) else {
                    why = " out of lines"; break
                }
                attempts += 1
                mine.append(pick.rest)
                let tone = Tone(pass: pi, rest: pick.rest, offset: 0, z: 0, effect: 0)
                guard let line = track(tone, sampleRate: sampleRate, count: y.count),
                      fill.fill(&y, line, sampleRate: sampleRate, rng: &rng) else { continue }
                filled.append(pick.rest)
                along += fillDecoys(decoyPasses, rest: pick.rest, &y, sampleRate: sampleRate, fill: fill, rng: &rng)
                guard let next = attacker.judge(y, sampleRate: sampleRate, pass: pass) else { why = " untestable"; break }
                v = next
            }
            notes.append("\(three(start)) → \(three(v.rank)) (target \(three(goal)))" + why)
        }
        let list = filled.map { "\(Int($0.rounded())) Hz" }.joined(separator: ", ")
        return (y, "tracks: rank target, \(expected.count) expected pass(es), filled \(filled.count) tone(s)"
                    + (list.isEmpty ? "" : " (" + list + ")") + (decoys > 0 ? ", and \(along) along \(decoyCount) decoy(s)" : "")
                    + "; attacker rank " + notes.joined(separator: ", "))
    }
}
