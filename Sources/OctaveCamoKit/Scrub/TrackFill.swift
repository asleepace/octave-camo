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
/// flight tracks (ADS-B); the engine never sees a position.
public struct ExpectedPass: Codable, Equatable {
    /// Audio time, s, increasing.
    public var times: [Double]
    public var factors: [Double]

    public init(times: [Double], factors: [Double]) {
        self.times = times
        self.factors = factors
    }

    /// Usable: at least two points, the same count of each, times strictly increasing, everything
    /// finite, factors physical (a source slower than sound: 0.5–2).
    public var isValid: Bool {
        times.count >= 2 && times.count == factors.count
            && times.allSatisfy(\.isFinite) && factors.allSatisfy { $0.isFinite && $0 > 0.5 && $0 < 2 }
            && zip(times, times.dropFirst()).allSatisfy { $0 < $1 }
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

/// Removes what flight tracks say is there: the attacker's own method, run first. For each expected
/// pass, the engine's tones are found in the audio along the predicted curve (rest frequency free,
/// a few seconds of timing slack, scored against the same curve at wrong times), and every tone
/// that stands out is filled with noise along its curve, the way `lines` fills what the check
/// finds. A blind check can't see a faint pass under the noise; an attacker who integrates along
/// the known curve can, and so can this.
public struct TrackFill {
    public var expected: [ExpectedPass] = []
    /// Tones per pass at most (an engine has several: fan, shaft orders, harmonics).
    public var maxTones = 4
    /// A tone is filled when its z against neighbouring rest frequencies reaches this *and* it
    /// stands `minExcessDB` above the same curve at wrong times. Filling a strip of noise along a
    /// known curve costs little, so the bar is low; on white noise the best of ~1,800 rest
    /// frequencies reaches z 4–5.4 but only 0.17–0.41 dB, a real session's engine tones 1.0–1.4 dB.
    public var minZ = 3.5
    public var minExcessDB = 0.6
    /// Search, then fill, then search what is left again.
    public var rounds = 2
    /// Timing slack, s (published positions lag and are coarse).
    public var maxOffset = 6.0
    public var offsetStep = 1.0
    /// Where the null curves go: moved this far, so they don't overlap the real one.
    public var nullShifts = [-40.0, -28, 28, 40]
    /// The search looks this far either side of the steepest fall, s (where the pass is loud).
    public var halfWindow = 25.0
    /// Rest frequencies searched.
    public var restRange: ClosedRange<Double> = 80...3_500
    /// The fill strip's extra half-width, Hz: the predicted curve is only as good as the track.
    public var marginHz = 8.0
    public var seed: UInt64 = .random(in: 1...UInt64.max)

    public init() {}

    /// The band searched and filled. The pipeline starts it at the low band's cutoff when `lowband`
    /// runs (below it, every tone has already been replaced with new noise).
    public var band: ClosedRange<Double> = 60...4_500

    var search: PathSearch {
        var p = PathSearch()
        p.band = band
        return p
    }

    /// Rest frequency step (0.2 %: finer than a Doppler factor's uncertainty).
    let ratio = 1.002

    struct Tone { let pass: Int; let rest: Double; let offset: Double; let z: Double }

    public func process(_ x: [Double], sampleRate: Int) -> (output: [Double], summary: String) {
        let usable = expected.filter(\.isValid)
        guard !usable.isEmpty else { return (x, "tracks: no usable expected passes (\(expected.count) given)") }
        var stage = self
        stage.expected = usable
        var y = x
        var rng = SeededRNG(seed: seed)
        var filled: [Tone] = []
        var fill = LineFill()
        fill.marginHz = marginHz
        for _ in 0..<rounds {
            let tones = stage.find(y, sampleRate: sampleRate)
            if tones.isEmpty { break }
            for tone in tones {
                if let line = stage.track(tone, sampleRate: sampleRate, count: y.count), fill.fill(&y, line, sampleRate: sampleRate, rng: &rng) {
                    filled.append(tone)
                }
            }
        }
        let list = filled.map { "\(Int($0.rest.rounded())) Hz (z \(($0.z * 10).rounded() / 10))" }.joined(separator: ", ")
        return (y, "tracks: \(usable.count) expected pass(es), filled \(filled.count) tone(s)\(list.isEmpty ? "" : ": " + list)")
    }

    /// The predicted tone as a track over the part of the audio the pass covers.
    func track(_ tone: Tone, sampleRate: Int, count: Int) -> Track? {
        let pass = expected[tone.pass], end = Double(count) / Double(sampleRate), c = pass.steepest + tone.offset
        var times: [Double] = [], freqs: [Double] = []
        // Only where the tone was found (around the steepest fall): a strip filled where there
        // is nothing to remove is pure risk, since any bias in its level traces the exact curve.
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

    /// Tones standing out along each pass's curve, strongest first per pass.
    func find(_ x: [Double], sampleRate: Int) -> [Tone] {
        let ps = search
        guard let g = ps.grid(count: x.count, sampleRate: sampleRate) else { return [] }
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
        var out: [Tone] = []
        for (pi, pass) in expected.enumerated() {
            var masked = am
            for _ in 0..<maxTones {
                guard let tone = best(pass, pi, masked, g, rests) else { break }
                out.append(tone)
                // Mask this tone's curve (±3 bins) so the next search finds a different one. The
                // mask is the average excess (0, the excess being centred), not the floor: the
                // wrong-time curves of other rest frequencies cross this one, and a hole along it
                // would lower their nulls and make them stand out.
                for m in 0..<g.frames {
                    guard let f = pass.factor(at: g.time(m) - tone.offset) else { continue }
                    let k = Int(((tone.rest * f) / g.binHz).rounded()) - g.kLo
                    guard k + 3 >= 0, k - 3 < g.bins else { continue }
                    for kk in max(0, k - 3)...min(g.bins - 1, k + 3) { masked[m * g.bins + kk] = 0 }
                }
            }
        }
        return out
    }

    /// The pass's best tone. For every rest frequency: the best mean excess along its curve over
    /// the timing offsets, minus the same at wrong times (the curve moved ±28–40 s, same frames,
    /// same offsets). A steady sound or an artefact at that frequency is there at the wrong times
    /// too and cancels; a tone that follows the curve doesn't. Each difference is scaled by the
    /// spread of its neighbours' (rest frequencies within ±25 %, most carrying no tone); the best
    /// one standing `minExcessDB` clear is kept if it reaches `minZ`.
    func best(_ pass: ExpectedPass, _ pi: Int, _ a: [Float], _ g: PathSearch.Grid, _ rests: [Double]) -> Tone? {
        let c = pass.steepest
        let all = (0..<g.frames).filter { abs(g.time($0) - c) <= halfWindow && pass.factor(at: g.time($0)) != nil }
        let frames = stride(from: 0, to: all.count, by: 2).map { all[$0] }
        guard frames.count >= 40 else { return nil }
        var factors = [Double](repeating: .nan, count: frames.count)
        // Mean excess along each rest frequency's curve, moved by `shift` (NaN: too few frames).
        func means(shift: Double) -> [Double] {
            for (i, m) in frames.enumerated() { factors[i] = pass.factor(at: g.time(m) - shift) ?? .nan }
            return rests.map { r in
                var sum = 0.0, n = 0
                for (i, m) in frames.enumerated() where !factors[i].isNaN {
                    let k = Int((r * factors[i] / g.binHz).rounded()) - g.kLo
                    guard k >= 0, k < g.bins else { continue }
                    sum += Double(a[m * g.bins + k])
                    n += 1
                }
                return n >= 40 ? sum / Double(n) : .nan
            }
        }
        let offsets = Array(stride(from: -maxOffset, through: maxOffset + 1e-9, by: offsetStep))
        // Per rest frequency: the best over offsets (and which offset).
        func scan(around shift: Double) -> (best: [Double], offset: [Double]) {
            var best = [Double](repeating: -.infinity, count: rests.count), at = [Double](repeating: 0, count: rests.count)
            for o in offsets {
                for (i, v) in means(shift: shift + o).enumerated() where v.isFinite && v > best[i] { best[i] = v; at[i] = o }
            }
            return (best, at)
        }
        let real = scan(around: 0)
        let nulls = nullShifts.map { scan(around: $0).best }
        var diff = [Double](repeating: .nan, count: rests.count)
        for i in rests.indices where real.best[i].isFinite {
            let ns = nulls.map { $0[i] }.filter(\.isFinite)
            if ns.count >= 2 { diff[i] = real.best[i] - DSP.mean(ns) }
        }
        // Each rest frequency against its neighbours (within ±25 %, leaving out ±2 % around it):
        // the spread differs across the band (the low band's new noise, a busy voice range).
        var zs = [Double](repeating: -.infinity, count: rests.count)
        let near = Int((log(1.25) / log(ratio)).rounded()), gap = Int((log(1.02) / log(ratio)).rounded())
        var local: [Double] = []
        for i in rests.indices where diff[i].isFinite {
            local.removeAll(keepingCapacity: true)
            for j in max(0, i - near)...min(rests.count - 1, i + near) where abs(j - i) > gap && diff[j].isFinite { local.append(diff[j]) }
            guard local.count >= 20 else { continue }
            let med = DSP.median(local[...])
            let spread = max(1.4826 * DSP.median(local.map { abs($0 - med) }[...]), 1e-3)
            zs[i] = (diff[i] - med) / spread
        }
        guard let i = zs.indices.filter({ zs[$0].isFinite && diff[$0] >= minExcessDB }).max(by: { zs[$0] < zs[$1] }) else { return nil }
        let z = zs[i]
        return z >= minZ ? Tone(pass: pi, rest: rests[i], offset: real.offset[i], z: z) : nil
    }
}
