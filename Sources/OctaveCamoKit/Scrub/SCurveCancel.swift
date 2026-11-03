#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WASILibc)
import WASILibc
#endif

/// Finds flyby pitch curves without flight data, and cancels them.
///
/// Any straight, constant-speed pass makes a pitch curve f0·r(t) set by four numbers: f0,
/// β = v/c, the time scale τ = distance/speed and the heard closest-approach time t0. So the
/// defender runs the attacker's own trick (integrate energy along a curve) over the whole
/// physical family and cancels the best candidates. It errs toward over-cancelling: removing a
/// thin sliver along a curve that wasn't a vehicle is inaudible.
///
/// Scoring uses a log-frequency spectrogram, where f0·r(t) becomes ln f0 + ln r(t): each frame
/// is shifted and added, which scores every f0 at once.
///
/// Port of the harness's `scurve` module.
public struct SCurveCancel: ScrubStage {
    var step: ScrubStep { .scurve }

    /// Cancel candidates whose robust z (against all curves) exceeds this.
    public var z = 4.5
    public var maxCurves = 8
    public var f0Min = 40.0
    public var f0Max = 600.0
    /// Amplitude low-pass for cancellation, s (curves are estimated, so keep it short).
    public var lowpassSeconds = 0.4

    public init() {}

    struct Curve {
        var beta: Double
        var tau: Double
        var t0: Double
    }

    struct Candidate {
        var curve: Curve
        var score: Double
        var logF0: Int
    }

    // Analysis: 4 kHz, 8192-sample windows (≈ 0.49 Hz bins), 0.5 s hop.
    static let analysisRate = 4_000.0
    static let window = 8_192
    static let hop = 2_000
    /// Log-frequency row spacing and the lowest Doppler ratio covered (ratios span ~0.6–1.6).
    static let delta = 0.002
    static let minRatio = 0.6
    static let maxRatio = 1.6

    public func process(_ x: [Double], sampleRate: Int) -> (output: [Double], summary: String) {
        let (low, rate) = DSP.decimate(x, sampleRate: Double(sampleRate), to: Self.analysisRate)
        let spec = WhitenedSpectrogram(low, sampleRate: rate, window: Self.window, hop: Self.hop,
                                       fMin: f0Min, fMax: f0Max * Self.maxRatio)
        let T = spec.times.count
        guard T >= 16 else { return (x, "scurve: clip too short") }
        let duration = Double(x.count) / Double(sampleRate)

        let delta = Self.delta
        let rowsMin = f0Min * Self.minRatio
        var rows = LogRows(spec, fMin: rowsMin, fMax: f0Max * Self.maxRatio, delta: delta)
        let J = rows.columns
        let jLo = Int((log(1 / Self.minRatio) / delta).rounded())
        let jHi = min(Int((log(f0Max / rowsMin) / delta).rounded()), J - 1)

        // The physical family on a grid.
        var curves: [Curve] = []
        var beta = 0.1
        while beta <= 0.8001 {
            var tau = 5.0
            while tau <= 240 {
                let step = max(2, tau / 4)
                let margin = min(2 * tau, 240)
                var t0 = -margin
                while t0 <= duration + margin {
                    curves.append(Curve(beta: beta, tau: tau, t0: t0))
                    t0 += step
                }
                tau *= 1.25
            }
            beta += 0.1
        }

        var acc = [Double](repeating: 0, count: J)
        func score(_ c: Curve) -> Candidate {
            let r = ratios(at: spec.times, c)
            for j in 0..<J { acc[j] = 0 }
            for t in 0..<T {
                let shift: Double = log(r[t]) / delta
                let s = Int(shift.rounded(.down))
                let w: Double = shift - Double(s)
                let row = t * J
                for j in jLo...jHi {
                    let a = j + s
                    if a >= 0 && a + 1 < J {
                        acc[j] += (1 - w) * rows.data[row + a] + w * rows.data[row + a + 1]
                    }
                }
            }
            var best = jLo
            for j in (jLo + 1)...jHi where acc[j] > acc[best] { best = j }
            return Candidate(curve: c, score: acc[best] / Double(T), logF0: best)
        }

        var scored: [Candidate] = []
        scored.reserveCapacity(curves.count)
        for c in curves { scored.append(score(c)) }
        var all = [Double](repeating: 0, count: scored.count)
        for i in scored.indices { all[i] = scored[i].score }
        let m = DSP.median(all[...])
        var deviations = [Double](repeating: 0, count: all.count)
        for i in all.indices { deviations[i] = abs(all[i] - m) }
        var mad = DSP.median(deviations[...]) * 1.4826
        if mad == 0 { mad = 1e-12 }
        func zScore(_ c: Candidate) -> Double { (c.score - m) / mad }

        // The grid is coarse (t0 steps of τ/4): refine each winner by coordinate descent before
        // cancelling, or fast close passes are cancelled along a slightly wrong curve.
        func refine(_ start: Candidate) -> Candidate {
            var best = start
            func attempt(_ c: Curve) {
                guard c.beta > 0.02, c.beta < 0.9, c.tau > 1 else { return }
                let s = score(c)
                if s.score > best.score { best = s }
            }
            var dt0: Double = max(2, start.curve.tau / 4) / 2
            var dTau = 0.12, dBeta = 0.05
            for _ in 0..<4 {
                for k in -3...3 { var c = best.curve; c.t0 += Double(k) * dt0 / 3; attempt(c) }
                for k in -3...3 { var c = best.curve; c.tau *= 1 + Double(k) * dTau / 3; attempt(c) }
                for k in -3...3 { var c = best.curve; c.beta += Double(k) * dBeta / 3; attempt(c) }
                dt0 /= 2; dTau /= 2; dBeta /= 2
            }
            return best
        }

        var pool = scored.filter { zScore($0) > z }
        pool.sort { zScore($0) > zScore($1) }
        if pool.count > 200 { pool.removeSubrange(200...) }

        var y = x
        var cancelled: [String] = []
        let halfWidth = Int((0.012 / delta).rounded(.up))
        while let top = pool.first, cancelled.count < maxCurves {
            let poolZ = zScore(top)
            let best = refine(top)
            let f0 = rowsMin * exp(Double(best.logF0) * delta)

            // Ratio on a 20 ms grid, interpolated per sample.
            let step = 0.02
            let gridCount = Int((duration / step).rounded(.up)) + 2
            var grid = [Double](repeating: 0, count: gridCount)
            for i in 0..<gridCount { grid[i] = Double(i) * step }
            let ratio = ratios(at: grid, best.curve)
            var frequency = [Double](repeating: 0, count: y.count)
            for i in 0..<y.count {
                let g: Double = Double(i) / Double(sampleRate) / step
                let k = min(Int(g), gridCount - 2)
                let w: Double = g - Double(k)
                frequency[i] = f0 * (ratio[k] + w * (ratio[k + 1] - ratio[k]))
            }
            Self.cancelTone(&y, frequency: frequency, sampleRate: sampleRate, lowpassSeconds: lowpassSeconds)
            cancelled.append(Self.describe(f0: f0, best.curve, z: poolZ))

            // Mask ±1.2 % around the cancelled path so it isn't found again.
            let r = ratios(at: spec.times, best.curve)
            for t in 0..<T {
                let center = best.logF0 + Int((log(r[t]) / delta).rounded())
                let lo = max(0, center - halfWidth), hi = min(J - 1, center + halfWidth)
                if lo > hi { continue }
                for j in lo...hi { rows.data[t * J + j] = 0 }
            }
            var next: [Candidate] = []
            for c in pool.dropFirst() {
                let s = score(c.curve)
                if zScore(s) > z { next.append(s) }
            }
            next.sort { zScore($0) > zScore($1) }
            pool = next
        }

        let detail = cancelled.isEmpty ? "" : ": " + cancelled.joined(separator: "; ")
        return (y, "scurve: searched \(curves.count) flyby curves; cancelled \(cancelled.count)\(detail)")
    }

    func ratios(at times: [Double], _ c: Curve) -> [Double] {
        let speed = c.beta * FlybyGeometry.speedOfSound
        return FlybyGeometry(f0: 1, speed: speed, t0: c.t0, distance: c.tau * speed).received(at: times).frequency
    }

    static func describe(f0: Double, _ c: Curve, z: Double) -> String {
        func fixed(_ v: Double, _ digits: Int) -> String {
            let scale = pow(10, Double(digits))
            let r = (v * scale).rounded() / scale
            return digits == 0 ? String(Int(r)) : String(r)
        }
        return "\(fixed(f0, 1)) Hz (τ \(fixed(c.tau, 0)) s, β \(fixed(c.beta, 1)), t0 \(fixed(c.t0, 0)) s, z \(fixed(z, 1)))"
    }

    /// Heterodyne-and-subtract one tone with known instantaneous frequency. `lowpassSeconds`
    /// sets the width removed around the curve (≈ ±1/lowpassSeconds Hz).
    static func cancelTone(_ y: inout [Double], frequency: [Double], sampleRate: Int, lowpassSeconds: Double) {
        let n = y.count
        let sr = Double(sampleRate)
        var cosP = [Double](repeating: 0, count: n), sinP = [Double](repeating: 0, count: n)
        var zr = [Double](repeating: 0, count: n), zi = [Double](repeating: 0, count: n)
        var phase = 0.0
        for i in 0..<n {
            phase += 2 * Double.pi * frequency[i] / sr
            cosP[i] = cos(phase); sinP[i] = sin(phase)
            zr[i] = y[i] * cosP[i]; zi[i] = -y[i] * sinP[i]
        }
        let L = max(2, Int((lowpassSeconds * sr).rounded()))
        let ar = DSP.movingAverage(DSP.movingAverage(zr, length: L), length: L)
        let ai = DSP.movingAverage(DSP.movingAverage(zi, length: L), length: L)
        for i in 0..<n { y[i] -= 2 * (ar[i] * cosP[i] - ai[i] * sinP[i]) }
    }
}

/// Log power, whitened per bin (removes steady tones and spectral tilt) and per frame (loudness).
/// Same as the harness's `whitenedSpectrogram`.
struct WhitenedSpectrogram {
    let times: [Double]
    let binHz: Double
    let bins: Int
    /// frames × bins, row-major.
    let data: [Double]

    init(_ x: [Double], sampleRate: Double, window n: Int, hop: Int, fMin: Double, fMax: Double) {
        let binHz = sampleRate / Double(n)
        let bins = min(Int((fMax / binHz).rounded(.up)) + 2, n / 2)
        let frames = x.count >= n ? (x.count - n) / hop + 1 : 0
        let win = DSP.hann(n)
        let fft = RealFFT(size: n)
        var frame = [Double](repeating: 0, count: n)
        var re = [Double](repeating: 0, count: fft.binCount), im = [Double](repeating: 0, count: fft.binCount)
        var power = [Double](repeating: 0, count: frames * bins)
        var times = [Double](repeating: 0, count: frames)
        for f in 0..<frames {
            for i in 0..<n { frame[i] = x[f * hop + i] * win[i] }
            fft.forward(frame, &re, &im)
            for k in 0..<bins { power[f * bins + k] = re[k] * re[k] + im[k] * im[k] + 1e-20 }
            times[f] = Double(f * hop + n / 2) / sampleRate
        }
        // Per-bin median over time, then per-frame median over frequency.
        var column = [Double](repeating: 0, count: frames)
        for k in 0..<bins {
            for f in 0..<frames { column[f] = power[f * bins + k] }
            let m = DSP.median(column[...])
            for f in 0..<frames { power[f * bins + k] /= m }
        }
        var data = [Double](repeating: 0, count: frames * bins)
        let lo = min(Int(fMin / binHz), bins - 1)
        for f in 0..<frames {
            let m = DSP.median(power[(f * bins + lo)..<((f + 1) * bins)])
            for k in 0..<bins { data[f * bins + k] = log(power[f * bins + k] / m) }
        }
        self.times = times
        self.binHz = binHz
        self.bins = bins
        self.data = data
    }
}

/// Log-frequency resampling of a spectrogram: row t, column j at f = fMin·e^(j·delta).
struct LogRows {
    let columns: Int
    var data: [Double]

    init(_ spec: WhitenedSpectrogram, fMin: Double, fMax: Double, delta: Double) {
        let J = Int((log(fMax / fMin) / delta).rounded(.down)) + 1
        let T = spec.times.count
        var data = [Double](repeating: 0, count: T * J)
        for t in 0..<T {
            for j in 0..<J {
                let b: Double = fMin * exp(Double(j) * delta) / spec.binHz
                let k = Int(b.rounded(.down))
                let w: Double = b - Double(k)
                if k + 1 < spec.bins {
                    data[t * J + j] = (1 - w) * spec.data[t * spec.bins + k] + w * spec.data[t * spec.bins + k + 1]
                }
            }
        }
        columns = J
        self.data = data
    }
}
