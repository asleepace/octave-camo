#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WASILibc)
import WASILibc
#endif

/// Finds weak, steady or slowly drifting lines by integrating over seconds, the way an attacker
/// who averages would (ACOUSTICS.md §3–4). It complements `ToneTracker`, which judges each frame
/// alone: a line 6–9 dB over the noise in a 1 Hz band, invisible frame by frame, is found here.
///
/// 1. A spectrogram in physical units: a power-of-two window close to 1 s (1–1.5 Hz bins at any
///    sample rate), a 0.5 s hop, each frame divided by its local median floor (so noise is about
///    exponential with mean 1, whatever the spectrum's shape).
/// 2. For spans of 3 s and 8 s, every path that starts at a bin and drifts by up to
///    `maxDriftHzPerSecond` is tested: **is it above τ in at least half the frames?** That median
///    test ignores a voice or a recurring note that lights a bin in a third of the frames, and a
///    single loud frame, while a steady tone passes in nearly all of them.
/// 3. τ comes from the binomial tail of that test in noise, for `falseLinesPerMinute` over the whole
///    search (bins × drifts × spans × minutes), not from a hand-tuned dB figure.
/// 4. A passing path must also be narrow (well above the paths 4 Hz either side), so broadband
///    bumps such as footsteps don't count; nearby weaker peaks (sidelobes) are suppressed.
/// 5. Detections are linked into tracks by frequency and time.
///
/// Fast Doppler curves are left to `ToneTracker` (and to the path search planned in ACOUSTICS.md).
public struct LineIntegrator {
    /// Target window length; the actual one is the largest power of two up to 1.1× this.
    public var windowSeconds = 1.0
    public var hopSeconds = 0.5
    /// Integration spans. Short ones catch tones that come and go; long ones catch the weakest.
    public var spans: [Double] = [3, 8]
    /// Paths may drift by up to this much (either way).
    public var maxDriftHzPerSecond = 1.0
    public var frequencyRange: ClosedRange<Double> = 40...8_000
    /// Search-wide false alarm budget (nominal: the test's tail treats frames and bins as
    /// independent; measured on noise scenes, the real rate stays under 0.1 per minute).
    public var falseLinesPerMinute = 0.03
    /// Half-width of the median floor around each bin.
    public var floorHalfWidthHz = 50.0
    /// A line must stand this many times above the paths 4 Hz either side.
    public var narrowness = 1.8

    public init() {}

    public func tracks(in x: [Double], sampleRate: Int) -> [Track] {
        let rate = Double(sampleRate)
        var n = 4
        while n * 2 <= Int(1.1 * windowSeconds * rate) { n <<= 1 }
        let hop = max(1, Int((hopSeconds * rate).rounded()))
        guard sampleRate > 0, x.count >= n else { return [] }
        let binHz = rate / Double(n), frames = (x.count - n) / hop + 1
        let kLo = max(1, Int((frequencyRange.lowerBound / binHz).rounded(.up)))
        let kHi = min(Int(frequencyRange.upperBound / binHz), Int(0.95 * rate / 2 / binHz))
        guard kHi > kLo + 8 else { return [] }
        let bins = kHi - kLo + 1
        let z = whitened(x, n: n, hop: hop, frames: frames, kLo: kLo, kHi: kHi, binHz: binHz)

        // Scales: frames per span, drift steps, evaluation stride, and τ from the search size.
        struct Scale { let frames: Int, drift: Int, stride: Int, need: Int; var tau = 0.0 }
        var scales: [Scale] = spans.compactMap { s in
            let k = Int((s / hopSeconds).rounded()) + 1
            guard k >= 3, k <= frames else { return nil }
            let stride = s >= 6 ? max(1, Int((2 / hopSeconds).rounded())) : 1
            return Scale(frames: k, drift: Int((maxDriftHzPerSecond * s / binHz).rounded(.up)), stride: stride, need: (k + 1) / 2)
        }
        guard !scales.isEmpty else { return [] }
        let minutes = max(Double(x.count) / rate / 60, 1.0 / 60)
        var tests = 0.0
        for s in scales { tests += Double(bins * (2 * s.drift + 1) * ((frames - s.frames) / s.stride + 1)) }
        let p = falseLinesPerMinute / max(tests / minutes, 1)
        for i in scales.indices { scales[i].tau = Self.countThreshold(scales[i].frames, scales[i].need, p) }

        let window = Double(n) / rate
        let w = max(3, Int((4 / binHz).rounded()))
        var detections: [Detection] = []
        var best = [Double](repeating: 0, count: bins), bestDrift = [Int](repeating: 0, count: bins)

        func pathMax(_ e: Int, _ s: Scale, _ k: Int) -> Double {
            var top = 0.0
            for d in -s.drift...s.drift {
                var sum = 0.0
                for j in 0..<s.frames {
                    let kk = min(bins - 1, max(0, k + Int((Double(d * j) / Double(s.frames - 1)).rounded())))
                    sum += Double(z[(e + j) * bins + kk])
                }
                top = max(top, sum / Double(s.frames))
            }
            return top
        }

        for s in scales {
            let tau = Float(s.tau)
            var e = 0
            while e + s.frames <= frames {
                for k in 0..<bins { best[k] = 0 }
                for d in -s.drift...s.drift {
                    let offsets = (0..<s.frames).map { Int((Double(d * $0) / Double(s.frames - 1)).rounded()) }
                    let from = max(0, -min(0, d)), to = min(bins, bins - max(0, d))
                    guard from < to else { continue }
                    for k in from..<to {
                        var sum: Float = 0, count = 0, j = 0
                        while j < s.frames {
                            let v = z[(e + j) * bins + k + offsets[j]]
                            sum += v
                            if v > tau { count += 1 } else if count + (s.frames - 1 - j) < s.need { break }
                            j += 1
                        }
                        let mean = Double(sum) / Double(s.frames)
                        if count >= s.need && mean > best[k] { best[k] = mean; bestDrift[k] = d }
                    }
                }
                // Narrow local maxima, strongest first; then suppress weaker ones within 6 bins.
                var candidates: [(k: Int, score: Double)] = []
                if bins > 4 {
                    for k in 2..<(bins - 2) {
                        let m = best[k]
                        guard m > 0, m >= best[k - 1], m >= best[k + 1], m >= best[k - 2], m >= best[k + 2] else { continue }
                        guard m >= narrowness * max(pathMax(e, s, max(0, k - w)), pathMax(e, s, min(bins - 1, k + w))) else { continue }
                        candidates.append((k, m))
                    }
                }
                candidates.sort { $0.score > $1.score }
                var kept: [(k: Int, score: Double)] = []
                for c in candidates where !kept.contains(where: { abs($0.k - c.k) <= 6 }) { kept.append(c) }
                let t0 = Double(e) * hopSeconds, t1 = Double(e + s.frames - 1) * hopSeconds + window
                for c in kept {
                    // Sub-bin peak (parabola through the neighbours' scores).
                    let a = best[c.k - 1], b = best[c.k], g = best[c.k + 1], denominator = a - 2 * b + g
                    let offset = denominator < 0 ? max(-0.5, min(0.5, 0.5 * (a - g) / denominator)) : 0
                    let f0 = (Double(c.k + kLo) + offset) * binHz
                    detections.append(Detection(start: t0, end: t1, f0: f0, f1: f0 + Double(bestDrift[c.k]) * binHz, score: c.score))
                }
                e += s.stride
            }
        }
        return link(detections, binHz: binHz)
    }

    struct Detection { let start: Double, end: Double, f0: Double, f1: Double, score: Double }

    /// Joins detections that continue each other (overlapping or adjacent in time, close in
    /// frequency, allowing the drift) into tracks; each detection joins its nearest track.
    func link(_ detections: [Detection], binHz: Double) -> [Track] {
        struct Open { var points: [(t: Double, f: Double)]; var end: Double; var last: (t: Double, f: Double); var score: Double }
        var open: [Open] = []
        for d in detections.sorted(by: { $0.start < $1.start }) {
            var hit: Int?, bestGap = Double.infinity
            for (i, o) in open.enumerated() where d.start <= o.end + 1 {
                let gap = abs(o.last.f - d.f0)
                let tolerance = 3 * binHz + maxDriftHzPerSecond * max(1, d.start - o.last.t)
                if gap <= tolerance && gap < bestGap { hit = i; bestGap = gap }
            }
            if let i = hit {
                open[i].points += [(d.start, d.f0), (d.end, d.f1)]
                open[i].end = max(open[i].end, d.end)
                open[i].last = (d.end, d.f1)
                open[i].score = max(open[i].score, d.score)
            } else {
                open.append(Open(points: [(d.start, d.f0), (d.end, d.f1)], end: d.end, last: (d.end, d.f1), score: d.score))
            }
        }
        return open.map { o in
            let points = o.points.sorted { $0.t < $1.t }
            let level = 10 * log10(max(o.score, 1e-12))
            return Track(times: points.map(\.t), frequencies: points.map(\.f), levels: points.map { _ in level })
        }
    }

    /// Power per bin (kLo…kHi) divided by its local median floor / ln 2, so noise has mean ≈ 1.
    /// Frames × bins, row-major.
    func whitened(_ x: [Double], n: Int, hop: Int, frames: Int, kLo: Int, kHi: Int, binHz: Double) -> [Float] {
        let bins = kHi - kLo + 1, fft = RealFFT(size: n), window = DSP.hann(n)
        let halfWidth = max(4, Int((floorHalfWidthHz / binHz).rounded()))
        let a = max(1, kLo - halfWidth), b = min(fft.binCount - 1, kHi + halfWidth)
        var out = [Float](repeating: 0, count: frames * bins)
        var frame = [Double](repeating: 0, count: n)
        var re = [Double](repeating: 0, count: fft.binCount), im = [Double](repeating: 0, count: fft.binCount)
        var power = [Double](repeating: 0, count: b - a + 1)
        let block = 8
        for f in 0..<frames {
            for i in 0..<n { frame[i] = x[f * hop + i] * window[i] }
            fft.forward(frame, &re, &im)
            for k in a...b {
                let p = re[k] * re[k] + im[k] * im[k]
                power[k - a] = p.isFinite ? p : 0
            }
            // Medians at block centers every 8 bins, interpolated between them.
            var centers: [Int] = [], medians: [Double] = []
            var c = kLo
            while c <= kHi + block {
                let lo = max(a, c - halfWidth), hi = min(b, c + halfWidth)
                var values = Array(power[(lo - a)...(hi - a)])
                values.sort()
                centers.append(c)
                medians.append(values[values.count / 2])
                c += block
            }
            for k in kLo...kHi {
                let j = min(medians.count - 2, (k - kLo) / block)
                let u = Double(k - centers[j]) / Double(block)
                let floor = max(1e-30, (medians[j] * (1 - u) + medians[j + 1] * u) / log(2.0))
                out[f * bins + k - kLo] = Float(power[k - a] / floor)
            }
        }
        return out
    }

    // MARK: Threshold

    /// log Γ(x) for x > 0 (Lanczos).
    static func logGamma(_ x: Double) -> Double {
        let c = [76.18009172947146, -86.50532032941677, 24.01409824083091, -1.231739572450155,
                 0.1208650973866179e-2, -0.5395239384953e-5]
        var y = x, series = 1.000000000190015
        let tmp = x + 5.5 - (x + 0.5) * log(x + 5.5)
        for k in c { y += 1; series += k / y }
        return -tmp + log(2.5066282746310005 * series / x)
    }

    /// P(at least m of n frames exceed τ) when each does with probability q = e^−τ.
    static func binomialTail(_ n: Int, _ m: Int, _ q: Double) -> Double {
        guard m <= n else { return 0 }
        var sum = 0.0
        for j in m...n {
            let logChoose = logGamma(Double(n + 1)) - logGamma(Double(j + 1)) - logGamma(Double(n - j + 1))
            sum += exp(logChoose + Double(j) * log(q) + Double(n - j) * log1p(-q))
        }
        return sum
    }

    /// τ such that "at least m of n frames above τ" has probability p in noise.
    static func countThreshold(_ n: Int, _ m: Int, _ p: Double) -> Double {
        var lo = 0.0, hi = 60.0
        for _ in 0..<200 {
            let mid = (lo + hi) / 2
            if binomialTail(n, m, exp(-mid)) > p { lo = mid } else { hi = mid }
        }
        return hi
    }
}
