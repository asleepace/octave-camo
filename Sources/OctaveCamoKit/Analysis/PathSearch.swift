#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WASILibc)
import WASILibc
#endif

/// Finds tones that move: a jet's fan tone sweeping down as it passes, which the frame tracker
/// (one-second windows, a per-frame threshold) smears away and the line integrator (steady lines)
/// isn't built for. docs/EXPERIMENTS.md, E2: on a real indoor recording it found a fan tone sweeping
/// 1.75 → 1.0 kHz that the check had missed, while music, singing, speech, sirens, construction and
/// busy rooms stayed quiet once the check's flyby fit was applied.
///
/// 1. A short-window spectrogram (≈ 0.17 s) of the band, each bin divided by its running median
///    (a steady hum *is* the median, so it vanishes; a moving tone never sits in one bin long
///    enough to become it), minus each frame's median over the band (a bang raises every bin of
///    its frame; a tone raises a few), clipped.
/// 2. In every 10 s span (every 2.5 s), a Viterbi search for the best path whose pitch only falls
///    (a straight pass is always heard falling), by 0–2 bins per frame, paying for each change of
///    slope (a Doppler curve bends gently), and falling at least 2 % overall, clear of the band's
///    edges.
/// 3. Spans scoring at least `threshold` (a z-score against the same search on white noise) are
///    joined into passes, their ends trimmed to where the tone stands clear; a pass must last
///    longer than one span. The caller keeps the ones its flyby fit accepts.
public struct PathSearch {
    public var band: ClosedRange<Double> = 500...4_000
    public var windowSeconds = 0.17
    /// Running median span, as a median of block medians (fast enough for the browser).
    public var referenceSeconds = 15.0
    public var blockSeconds = 1.0
    public var clip: ClosedRange<Double> = -3...12
    public var spanSeconds = 10.0
    public var stepSeconds = 2.5
    /// Pitch change per frame, bins (downward).
    public var slopes = [0, 1, 2]
    public var slopePenalty = 2.0
    public var minFall = 0.02
    /// Paths must stay this many bins inside the band.
    public var edgeBins = 3
    /// z against white noise. Real sessions: false passes up to 8.6, the real pass 19.4.
    public var threshold = 10.0
    /// A pass must last this long once trimmed, s: longer than one span (a real pass bends over
    /// 20–30 s; on the recorder sessions every false pass fit in one span, a short fall through
    /// hiss or a TV's sound).
    public var minSeconds = 12.0
    /// A pass's ends are trimmed while the excess along it (over ±0.5 s) is below what the search
    /// collects per frame from noise plus this, dB.
    public var trimMargin = 2.0

    public init() {}

    struct Grid {
        let n: Int, hop: Int, kLo: Int, bins: Int, frames: Int
        let binHz: Double, dt: Double, t0: Double
        func time(_ m: Int) -> Double { t0 + Double(m) * dt }
        func frequency(_ k: Int) -> Double { Double(kLo + k) * binHz }
    }

    func grid(count: Int, sampleRate: Int) -> Grid? {
        let sr = Double(sampleRate)
        let n = Int(pow(2, (log2(windowSeconds * sr)).rounded()))
        let hop = n / 4
        guard count >= n * 4 else { return nil }
        let binHz = sr / Double(n)
        let kLo = Int((band.lowerBound / binHz).rounded(.up)), kHi = min(n / 2 - 1, Int((band.upperBound / binHz).rounded(.down)))
        guard kHi - kLo > 4 * edgeBins + 8 else { return nil }
        return Grid(n: n, hop: hop, kLo: kLo, bins: kHi - kLo + 1, frames: 1 + (count - n) / hop,
                    binHz: binHz, dt: Double(hop) / sr, t0: Double(n / 2) / sr)
    }

    /// Clipped excess in dB, frames × bins (row-major), not yet centred.
    func excess(_ x: [Double], _ g: Grid) -> [Float] {
        let fft = RealFFT(size: g.n), window = DSP.hann(g.n)
        var frame = [Double](repeating: 0, count: g.n)
        var re = [Double](repeating: 0, count: fft.binCount), im = re
        var power = [Float](repeating: 0, count: g.frames * g.bins)
        for m in 0..<g.frames {
            let start = m * g.hop
            for i in 0..<g.n { frame[i] = x[start + i] * window[i] }
            fft.forward(frame, &re, &im)
            for k in 0..<g.bins {
                let b = g.kLo + k
                power[m * g.bins + k] = Float(re[b] * re[b] + im[b] * im[b]) + 1e-30
            }
        }
        // Running median per bin: the median of the block medians within ±referenceSeconds/2.
        let block = max(1, Int((blockSeconds / g.dt).rounded()))
        let blocks = (g.frames + block - 1) / block
        let half = max(1, Int((referenceSeconds / 2 / blockSeconds).rounded()))
        var blockMedian = [Float](repeating: 0, count: blocks * g.bins)
        var scratch = [Float]()
        for k in 0..<g.bins {
            for b in 0..<blocks {
                scratch.removeAll(keepingCapacity: true)
                for m in (b * block)..<min(g.frames, (b + 1) * block) { scratch.append(power[m * g.bins + k]) }
                blockMedian[b * g.bins + k] = Self.median(&scratch)
            }
        }
        var reference = [Float](repeating: 0, count: blocks * g.bins)
        for k in 0..<g.bins {
            for b in 0..<blocks {
                scratch.removeAll(keepingCapacity: true)
                for bb in max(0, b - half)...min(blocks - 1, b + half) { scratch.append(blockMedian[bb * g.bins + k]) }
                reference[b * g.bins + k] = Self.median(&scratch)
            }
        }
        var out = [Float](repeating: 0, count: g.frames * g.bins)
        var row = [Float](repeating: 0, count: g.bins)
        for m in 0..<g.frames {
            let b = m / block
            for k in 0..<g.bins { row[k] = 10 * log10(power[m * g.bins + k] / reference[b * g.bins + k]) }
            var sorted = row
            let frameMedian = Self.median(&sorted)
            for k in 0..<g.bins {
                out[m * g.bins + k] = min(Float(clip.upperBound), max(Float(clip.lowerBound), row[k] - frameMedian))
            }
        }
        return out
    }

    struct Span { let start: Int; let score: Double; let path: [Int] }

    /// The best falling path in every span (`a`: centred excess, frames × bins).
    func spans(_ a: [Float], _ g: Grid) -> [Span] {
        let W = max(8, Int((spanSeconds / g.dt).rounded())), step = max(1, Int((stepSeconds / g.dt).rounded()))
        guard g.frames >= W else { return [] }
        let nb = g.bins, ns = slopes.count, neg = -1e9
        var out: [Span] = []
        var V = [Double](repeating: 0, count: ns * nb), next = V
        var back = [Int8](repeating: 0, count: W * ns * nb)
        for s in stride(from: 0, through: g.frames - W, by: step) {
            for mi in 0..<ns { for k in 0..<nb { V[mi * nb + k] = Double(a[s * nb + k]) } }
            for j in 1..<W {
                let row = (s + j) * nb
                for (mi, m) in slopes.enumerated() {
                    for k in 0..<nb {
                        let from = k + m                              // the previous frame was m bins higher
                        var best = neg, arg = 0
                        if from < nb {
                            for pi in 0..<ns {
                                let v = V[pi * nb + from] - (pi == mi ? 0 : slopePenalty)
                                if v > best { best = v; arg = pi }
                            }
                        }
                        next[mi * nb + k] = best + Double(a[row + k])
                        back[(j * ns + mi) * nb + k] = Int8(arg)
                    }
                }
                swap(&V, &next)
            }
            // The best end state whose path falls enough and stays clear of the band's edges.
            let order = V.indices.sorted { V[$0] > V[$1] }.prefix(300)
            for idx in order where V[idx] > neg / 2 {
                var mi = idx / nb, k = idx % nb
                var path = [Int](repeating: 0, count: W)
                path[W - 1] = k
                var ok = k >= edgeBins && k < nb - edgeBins
                var j = W - 1
                while ok && j > 0 {
                    let m = slopes[mi]
                    mi = Int(back[(j * ns + mi) * nb + k])
                    k += m
                    j -= 1
                    path[j] = k
                    ok = k >= edgeBins && k < nb - edgeBins
                }
                guard ok else { continue }
                let f0 = g.frequency(path[0]), f1 = g.frequency(path[W - 1])
                if f0 - f1 >= minFall * f0 {
                    out.append(Span(start: s, score: V[idx], path: path))
                    break
                }
            }
        }
        return out
    }

    /// Mean excess and the best-path score's mean and spread on white noise, per sample rate and
    /// settings (computed once, then cached).
    struct Null { let mu: Double, mean: Double, sd: Double }
    /// Locked: the engine runs on one thread, but a library caller could search from several.
    /// Computing is outside the lock (two threads may both compute a missing entry; they get the
    /// same value, the noise being seeded).
    private static let nulls = Locked<[String: Null]>([:])

    func null(sampleRate: Int) -> Null? {
        let key = "\(sampleRate)|\(band)|\(windowSeconds)|\(referenceSeconds)|\(blockSeconds)|\(clip)|\(spanSeconds)|\(stepSeconds)|\(slopes)|\(slopePenalty)|\(minFall)|\(edgeBins)"
        if let n = Self.nulls.withLock({ $0[key] }) { return n }
        var rng = SeededRNG(seed: 0x9A75)
        let noise = rng.normals(sampleRate * 60)
        guard let g = grid(count: noise.count, sampleRate: sampleRate) else { return nil }
        var a = excess(noise, g)
        let mu = Double(a.reduce(0, +)) / Double(a.count)
        for i in a.indices { a[i] -= Float(mu) }
        let scores = spans(a, g).map(\.score)
        guard scores.count > 2 else { return nil }
        let mean = DSP.mean(scores), sd = max(DSP.standardDeviation(scores), 1e-6)
        let n = Null(mu: mu, mean: mean, sd: sd)
        Self.nulls.withLock { $0[key] = n }
        return n
    }

    /// Candidate passes: spans scoring at least `threshold`, joined where they overlap and agree.
    public func tracks(in x: [Double], sampleRate: Int) -> [Track] {
        guard let g = grid(count: x.count, sampleRate: sampleRate), let nl = null(sampleRate: sampleRate) else { return [] }
        var a = excess(x, g)
        for i in a.indices { a[i] -= Float(nl.mu) }
        let strong = spans(a, g).filter { ($0.score - nl.mean) / nl.sd >= threshold }
        // Join overlapping spans whose paths agree (median gap ≤ 3 bins over the overlap).
        var passes: [[Int: [Int]]] = []                       // frame → bins seen there
        for sp in strong {
            var joined = false
            if var last = passes.last {
                let overlap = sp.path.indices.compactMap { j -> Int? in
                    guard var seen = last[sp.start + j] else { return nil }
                    seen.sort()
                    return abs(seen[seen.count / 2] - sp.path[j])
                }
                if !overlap.isEmpty {
                    var gaps = overlap
                    gaps.sort()
                    if gaps[gaps.count / 2] <= 3 {
                        for (j, k) in sp.path.enumerated() { last[sp.start + j, default: []].append(k) }
                        passes[passes.count - 1] = last
                        joined = true
                    }
                }
            }
            if !joined {
                var p: [Int: [Int]] = [:]
                for (j, k) in sp.path.enumerated() { p[sp.start + j] = [k] }
                passes.append(p)
            }
        }
        // Each pass: the median bin per frame, its ends trimmed back to where the tone stands
        // clear of what the search finds in noise (a path's ends wander off a fading tone).
        let W = max(8, Int((spanSeconds / g.dt).rounded()))
        let noisePerFrame = nl.mean / Double(W), smooth = max(1, Int((0.5 / g.dt).rounded()))
        return passes.compactMap { p in
            let frames = p.keys.sorted()
            let bins = frames.map { m -> Int in
                var ks = p[m]!
                ks.sort()
                return ks[ks.count / 2]
            }
            let evidence = zip(frames, bins).map { Double(a[$0 * g.bins + $1]) }
            var sums = [0.0]
            for e in evidence { sums.append(sums.last! + e) }
            func clear(_ i: Int) -> Bool {
                let lo = max(0, i - smooth), hi = min(evidence.count, i + smooth + 1)
                return (sums[hi] - sums[lo]) / Double(hi - lo) >= noisePerFrame + trimMargin
            }
            guard let first = evidence.indices.first(where: clear),
                  let last = evidence.indices.last(where: clear),
                  g.time(frames[last]) - g.time(frames[first]) >= minSeconds else { return nil }
            let keep = first...last
            return Track(times: keep.map { g.time(frames[$0]) },
                         frequencies: keep.map { g.frequency(bins[$0]) },
                         levels: keep.map { evidence[$0] })
        }
    }

    static func median(_ v: inout [Float]) -> Float {
        guard !v.isEmpty else { return 0 }
        v.sort()
        return v.count % 2 == 1 ? v[v.count / 2] : 0.5 * (v[v.count / 2 - 1] + v[v.count / 2])
    }
}
