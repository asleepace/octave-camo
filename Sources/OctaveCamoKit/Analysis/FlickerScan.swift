#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WASILibc)
import WASILibc
#endif

/// Mains flicker in video: the picture's copy of the ENF clock, found and removed blind.
///
/// Lights on AC power flicker at twice the mains frequency (100 or 120 Hz). A rolling-shutter
/// camera reads rows top to bottom over the readout time, so each row samples a different moment
/// and the flicker becomes horizontal bands. Row r of frame k sees (log brightness)
///
///     m · cos(2π F (t_k + readout · r / R) + φ(t))
///
/// where φ(t) drifts with the grid frequency: the trace an attacker wants. The band has
/// C = F · readout cycles per frame height, so each frame's row profile is projected onto
/// e^{-i2πC r/R}, and a temporal DFT at F turns the frame sequence into a line in (F, C). That's
/// the attacker's search; the defender runs the same search, estimates the band's slowly varying
/// amplitude and divides it out of every row.
///
/// Three things keep scene content from looking like flicker:
/// - flicker brightens whole rows evenly, so only what the column strips share counts (median
///   over strips);
/// - whatever doesn't move over `staticSeconds` is removed before scanning (static scene, or
///   flicker so steady it carries no clock);
/// - each temporal-frequency row is judged against its own spread over C: scene motion is broad
///   in C, a band is narrow.
///
/// Port of reference/video_flicker.py.
public struct FlickerScan {
    public var mains: [Double] = [50, 60]
    /// Plausible readout time as a fraction of the frame period.
    public var readout: ClosedRange<Double> = 0.3...0.95
    /// Search ± this around 2 × mains, Hz (covers ENF wander).
    public var spanHz = 0.6
    public var stepHz = 0.02
    /// Spatial-frequency grid step, cycles per frame height.
    public var cyclesStep = 0.04
    /// Frames are summed coherently in segments this long, then segments add in power.
    public var segmentSeconds = 4.0
    /// Band amplitude smoothing for removal, s.
    public var smoothSeconds = 0.5
    public var staticSeconds = 20.0
    /// Removal never exceeds this log-brightness depth (about ±5 %).
    public var maxDepth = 0.05
    public var detectZ = 60.0
    /// Scan-and-remove passes at most (a residual, a harmonic or a second light).
    public var passes = 3

    public init() {}

    /// Row profiles: log brightness per frame, column strip and row band (row 0 at the top).
    public struct Profiles {
        public let frames: Int
        public let strips: Int
        public let rows: Int
        /// frames × strips × rows, row-major.
        public var values: [Double]
        /// Presentation time of each frame, s.
        public let times: [Double]

        public init(frames: Int, strips: Int, rows: Int, values: [Double], times: [Double]) {
            precondition(values.count == frames * strips * rows && times.count == frames, "profile size mismatch")
            precondition(rows >= 8 && strips >= 1 && frames >= 1, "too few rows, strips or frames")
            self.frames = frames
            self.strips = strips
            self.rows = rows
            self.values = Self.repaired(values, frames: frames, perFrame: strips * rows)
            self.times = Self.repaired(times)
        }

        /// One NaN would spread through the running sums and quietly turn detection off (reading as
        /// "no flicker"). A bad value takes the same position's value in the previous frame, or the
        /// mean of the good values.
        static func repaired(_ values: [Double], frames: Int, perFrame: Int) -> [Double] {
            guard !values.allSatisfy(\.isFinite) else { return values }
            let good = values.filter(\.isFinite)
            let fallback = good.isEmpty ? 0 : good.reduce(0, +) / Double(good.count)
            var out = values
            for k in 0..<frames {
                for i in 0..<perFrame where !out[k * perFrame + i].isFinite {
                    out[k * perFrame + i] = k > 0 ? out[(k - 1) * perFrame + i] : fallback
                }
            }
            return out
        }

        /// Frame times with bad entries interpolated from their neighbours' spacing.
        static func repaired(_ times: [Double]) -> [Double] {
            guard !times.allSatisfy(\.isFinite) else { return times }
            var out = times
            let steps = zip(times.dropFirst(), times).map { $0 - $1 }.filter { $0.isFinite && $0 > 0 }.sorted()
            let step = steps.isEmpty ? 1.0 / 30 : steps[steps.count / 2]
            for k in out.indices where !out[k].isFinite { out[k] = k > 0 ? out[k - 1] + step : 0 }
            return out
        }

        var fps: Double {
            guard frames > 1, let first = times.first, let last = times.last, last > first else { return 30 }
            return Double(frames - 1) / (last - first)
        }
    }

    public struct Finding: Equatable {
        /// Line strength (robust z within its temporal-frequency row).
        public var z: Double
        /// Flicker frequency, Hz.
        public var flicker: Double
        /// Band cycles per frame height.
        public var cycles: Double
        /// Implied rolling-shutter readout time, s.
        public var readoutSeconds: Double
        public var detected: Bool
        /// False when the scan couldn't look: fewer frames than one segment, or a frame rate so
        /// high the band would be under half a cycle per frame (it looks like a gradient). Not
        /// checked is not the same as clean.
        public var checked = true
    }

    public struct Cleaned {
        /// Multiplicative brightness gain per frame and row band (frames × rows), 1 where untouched.
        public var gains: [Double]
        /// One finding per scan pass that ran.
        public var findings: [Finding]
        /// The attacker's scan on the corrected profiles.
        public var after: Finding
    }

    // MARK: Scan

    public func scan(_ p: Profiles) -> Finding {
        let fps = p.fps, frameDuration = 1 / fps
        let flickers: [Double] = mains.map { 2 * $0 }
        let maxFlicker = flickers.max() ?? 120
        var cycles: [Double] = []
        var c = 0.5
        while c <= 2 * maxFlicker * readout.upperBound * frameDuration + 1e-9 {
            cycles.append(c)
            c += cyclesStep
        }
        let (re, im) = phasors(p, cycles: cycles, removeStaticAt: fps)
        let NC = cycles.count, K = p.frames
        let segment = max(4, Int((segmentSeconds * fps).rounded()))

        var best = Finding(z: -.infinity, flicker: 0, cycles: 0, readoutSeconds: 0, detected: false)
        var candidates = 0
        var power = [Double](repeating: 0, count: NC)
        var accRe = [Double](repeating: 0, count: NC), accIm = [Double](repeating: 0, count: NC)
        var row = [Double](repeating: 0, count: NC)
        for base in flickers {
            let lo = base * readout.lowerBound * frameDuration - 1e-9
            let hi = base * readout.upperBound * frameDuration + 1e-9
            var f = base - spanHz
            while f <= base + spanHz + 1e-9 {
                for j in 0..<NC { power[j] = 0 }
                var start = 0
                while start + segment <= K {
                    for j in 0..<NC { accRe[j] = 0; accIm[j] = 0 }
                    for k in start..<(start + segment) {
                        let angle: Double = -2 * Double.pi * f * p.times[k]
                        let er = cos(angle), ei = sin(angle)
                        let offset = k * NC
                        for j in 0..<NC {
                            let a = re[offset + j], b = im[offset + j]
                            accRe[j] += a * er - b * ei
                            accIm[j] += a * ei + b * er
                        }
                    }
                    for j in 0..<NC { power[j] += accRe[j] * accRe[j] + accIm[j] * accIm[j] }
                    start += segment
                }
                // Whiten across C within this temporal frequency.
                let median = DSP.median(power[...])
                for j in 0..<NC { row[j] = abs(power[j] - median) }
                let mad = DSP.median(row[...]) * 1.4826 + 1e-30
                for j in 0..<NC where cycles[j] >= lo && cycles[j] <= hi {
                    candidates += 1
                    let z = (power[j] - median) / mad
                    if z > best.z {
                        best = Finding(z: z, flicker: f, cycles: cycles[j], readoutSeconds: cycles[j] / f, detected: false)
                    }
                }
                f += stepHz
            }
        }
        guard candidates > 0, K >= segment, best.z.isFinite else {
            return Finding(z: 0, flicker: 0, cycles: 0, readoutSeconds: 0, detected: false, checked: false)
        }
        best.detected = best.z > detectZ
        return best
    }

    // MARK: Removal

    /// Iteratively removes detected flicker components.
    public func clean(_ p: Profiles) -> Cleaned {
        let K = p.frames, S = p.strips, R = p.rows
        var total = [Double](repeating: 0, count: K * R)
        var residual = p
        var findings: [Finding] = []
        for _ in 0..<passes {
            let finding = scan(residual)
            findings.append(finding)
            if !finding.detected { break }
            let (flicker, cycles) = refine(residual, flicker: finding.flicker, cycles: finding.cycles)
            let m = model(residual, flicker: flicker, cycles: cycles)
            for k in 0..<K {
                for r in 0..<R {
                    total[k * R + r] += m[k * R + r]
                    for s in 0..<S { residual.values[(k * S + s) * R + r] -= m[k * R + r] }
                }
            }
        }
        let after = findings.last.map { $0.detected ? scan(residual) : $0 } ?? scan(residual)
        var gains = [Double](repeating: 1, count: K * R)
        for i in 0..<(K * R) { gains[i] = exp(-total[i]) }
        return Cleaned(gains: gains, findings: findings, after: after)
    }

    /// Per-frame band amplitude at `cycles` (complex, one per frame): least squares jointly with
    /// the gradient terms (unbiased even with one or two band cycles per frame, where a windowed
    /// projection picks up the band's mirror image), median over strips, minus its moving mean
    /// over `staticSeconds` (static scene, or flicker too steady to carry a clock).
    func amplitudes(_ p: Profiles, cycles: Double) -> (re: [Double], im: [Double]) {
        let K = p.frames, S = p.strips, R = p.rows
        let solve = Self.leastSquares(rows: R, cycles: cycles)      // 5 × R
        var alpha = [Double](repeating: 0, count: S), beta = [Double](repeating: 0, count: S)
        var re = [Double](repeating: 0, count: K), im = [Double](repeating: 0, count: K)
        for k in 0..<K {
            for s in 0..<S {
                let base = (k * S + s) * R
                var a = 0.0, b = 0.0
                for r in 0..<R {
                    let v = p.values[base + r]
                    a += solve[3 * R + r] * v
                    b += solve[4 * R + r] * v
                }
                alpha[s] = a
                beta[s] = b
            }
            // y = α cos θ + β sin θ = Re((α − iβ) e^{iθ})
            re[k] = DSP.median(alpha[...])
            im[k] = -DSP.median(beta[...])
        }
        let length = max(1, Int((staticSeconds * p.fps).rounded()))
        let slowRe = Self.normalizedAverage(re, length: length), slowIm = Self.normalizedAverage(im, length: length)
        for k in 0..<K { re[k] -= slowRe[k]; im[k] -= slowIm[k] }
        return (re, im)
    }

    /// Fine (F, C) around a detection, maximizing segment-summed coherent power.
    func refine(_ p: Profiles, flicker: Double, cycles: Double) -> (flicker: Double, cycles: Double) {
        let K = p.frames
        let segment = max(4, Int((segmentSeconds * p.fps).rounded()))
        var best = (power: -1.0, flicker: flicker, cycles: cycles)
        for i in -30...30 {
            let c = cycles + Double(i) * 0.01
            if c <= 0.1 { continue }
            let (re, im) = amplitudes(p, cycles: c)
            for j in -12...12 {
                let f = flicker + Double(j) * 0.005
                var power = 0.0
                var start = 0
                while start + segment <= K {
                    var sumRe = 0.0, sumIm = 0.0
                    for k in start..<(start + segment) {
                        let angle: Double = -2 * Double.pi * f * p.times[k]
                        let er = cos(angle), ei = sin(angle)
                        sumRe += re[k] * er - im[k] * ei
                        sumIm += re[k] * ei + im[k] * er
                    }
                    power += sumRe * sumRe + sumIm * sumIm
                    start += segment
                }
                if power > best.power { best = (power, f, c) }
            }
        }
        return (best.flicker, best.cycles)
    }

    /// Smoothed band estimate (log brightness), frames × rows, depth capped.
    func model(_ p: Profiles, flicker: Double, cycles: Double) -> [Double] {
        let K = p.frames, R = p.rows
        let (re, im) = amplitudes(p, cycles: cycles)
        // Demodulate: a_k ≈ m e^{iφ(t)}, the band's slowly varying complex amplitude.
        var aRe = [Double](repeating: 0, count: K), aIm = [Double](repeating: 0, count: K)
        for k in 0..<K {
            let angle: Double = -2 * Double.pi * flicker * p.times[k]
            let er = cos(angle), ei = sin(angle)
            aRe[k] = re[k] * er - im[k] * ei
            aIm[k] = re[k] * ei + im[k] * er
        }
        let length = max(1, Int((smoothSeconds * p.fps).rounded()))
        aRe = Self.normalizedAverage(aRe, length: length)
        aIm = Self.normalizedAverage(aIm, length: length)

        var out = [Double](repeating: 0, count: K * R)
        for k in 0..<K {
            var ar = aRe[k], ai = aIm[k]
            let magnitude = (ar * ar + ai * ai).squareRoot()
            if magnitude > maxDepth { ar *= maxDepth / magnitude; ai *= maxDepth / magnitude }
            for r in 0..<R {
                let angle: Double = 2 * Double.pi * (flicker * p.times[k] + cycles * Double(r) / Double(R))
                out[k * R + r] = ar * cos(angle) - ai * sin(angle)
            }
        }
        return out
    }

    /// Centered moving average that stays unbiased at the ends (divides by the samples present).
    static func normalizedAverage(_ x: [Double], length: Int) -> [Double] {
        let sums = DSP.movingAverage(x, length: length)
        let counts = DSP.movingAverage([Double](repeating: 1, count: x.count), length: length)
        var out = [Double](repeating: 0, count: x.count)
        for i in x.indices { out[i] = counts[i] > 0 ? sums[i] / counts[i] : 0 }
        return out
    }

    /// Least-squares solver for y ≈ [1, u, u², cos θ, sin θ]·coef over R rows, θ = 2πC r/R:
    /// returns (XᵀX)⁻¹Xᵀ, 5 × R row-major.
    static func leastSquares(rows R: Int, cycles: Double) -> [Double] {
        let n = 5
        var X = [Double](repeating: 0, count: R * n)
        for r in 0..<R {
            let u: Double = R > 1 ? -1 + 2 * Double(r) / Double(R - 1) : 0
            let theta: Double = 2 * Double.pi * cycles * Double(r) / Double(R)
            X[r * n + 0] = 1
            X[r * n + 1] = u
            X[r * n + 2] = u * u
            X[r * n + 3] = cos(theta)
            X[r * n + 4] = sin(theta)
        }
        // Normal equations, augmented with the identity, solved by Gauss–Jordan elimination.
        var A = [Double](repeating: 0, count: n * 2 * n)
        for i in 0..<n {
            for j in 0..<n {
                var sum = 0.0
                for r in 0..<R { sum += X[r * n + i] * X[r * n + j] }
                A[i * 2 * n + j] = sum
            }
            A[i * 2 * n + n + i] = 1
        }
        for col in 0..<n {
            var pivot = col
            for row in (col + 1)..<n where abs(A[row * 2 * n + col]) > abs(A[pivot * 2 * n + col]) { pivot = row }
            if pivot != col {
                for j in 0..<(2 * n) { A.swapAt(col * 2 * n + j, pivot * 2 * n + j) }
            }
            let d = A[col * 2 * n + col]
            if abs(d) < 1e-12 { continue }
            for j in 0..<(2 * n) { A[col * 2 * n + j] /= d }
            for row in 0..<n where row != col {
                let factor = A[row * 2 * n + col]
                if factor == 0 { continue }
                for j in 0..<(2 * n) { A[row * 2 * n + j] -= factor * A[col * 2 * n + j] }
            }
        }
        var out = [Double](repeating: 0, count: n * R)
        for i in 0..<n {
            for r in 0..<R {
                var sum = 0.0
                for j in 0..<n { sum += A[i * 2 * n + n + j] * X[r * n + j] }
                out[i * R + r] = sum
            }
        }
        return out
    }

    // MARK: Phasors

    /// Band phasors per frame, frames × cycles (re, im): the median over column strips of each
    /// detrended, Hann-windowed row profile's projection onto e^{-i2πC r/R}. With `removeStaticAt`
    /// (the frame rate), each phasor's moving mean over `staticSeconds` is subtracted.
    func phasors(_ p: Profiles, cycles: [Double], removeStaticAt fps: Double?) -> (re: [Double], im: [Double]) {
        let K = p.frames, S = p.strips, R = p.rows, NC = cycles.count
        let window = DSP.hann(R)
        var basisCos = [Double](repeating: 0, count: R * NC), basisSin = [Double](repeating: 0, count: R * NC)
        for r in 0..<R {
            for j in 0..<NC {
                let angle: Double = 2 * Double.pi * cycles[j] * Double(r) / Double(R)
                basisCos[r * NC + j] = window[r] * cos(angle)
                basisSin[r * NC + j] = -window[r] * sin(angle)
            }
        }
        let trend = Self.trendBasis(R)

        var re = [Double](repeating: 0, count: K * NC), im = [Double](repeating: 0, count: K * NC)
        var profile = [Double](repeating: 0, count: R)
        var stripRe = [Double](repeating: 0, count: S * NC), stripIm = [Double](repeating: 0, count: S * NC)
        var column = [Double](repeating: 0, count: S)
        for k in 0..<K {
            for s in 0..<S {
                let base = (k * S + s) * R
                for r in 0..<R { profile[r] = p.values[base + r] }
                Self.removeTrend(&profile, trend)
                for j in 0..<NC { stripRe[s * NC + j] = 0; stripIm[s * NC + j] = 0 }
                for r in 0..<R {
                    let v = profile[r]
                    if v == 0 { continue }
                    let offset = r * NC
                    for j in 0..<NC {
                        stripRe[s * NC + j] += v * basisCos[offset + j]
                        stripIm[s * NC + j] += v * basisSin[offset + j]
                    }
                }
            }
            for j in 0..<NC {
                for s in 0..<S { column[s] = stripRe[s * NC + j] }
                re[k * NC + j] = DSP.median(column[...])
                for s in 0..<S { column[s] = stripIm[s * NC + j] }
                im[k * NC + j] = DSP.median(column[...])
            }
        }

        if let fps {
            let length = max(1, Int((staticSeconds * fps).rounded()))
            let ones = [Double](repeating: 1, count: K)
            let counts = DSP.movingAverage(ones, length: length)
            var series = [Double](repeating: 0, count: K)
            for j in 0..<NC {
                for part in 0..<2 {
                    for k in 0..<K { series[k] = part == 0 ? re[k * NC + j] : im[k * NC + j] }
                    let slow = DSP.movingAverage(series, length: length)
                    for k in 0..<K {
                        let mean = counts[k] > 0 ? slow[k] / counts[k] : 0
                        if part == 0 { re[k * NC + j] -= mean } else { im[k * NC + j] -= mean }
                    }
                }
            }
        }
        return (re, im)
    }

    /// Orthonormal basis of {1, u, u²} over R rows (u from −1 to 1), for removing gradients.
    static func trendBasis(_ R: Int) -> [[Double]] {
        var basis: [[Double]] = []
        for degree in 0..<3 {
            var v = [Double](repeating: 0, count: R)
            for r in 0..<R {
                let u: Double = R > 1 ? -1 + 2 * Double(r) / Double(R - 1) : 0
                v[r] = pow(u, Double(degree))
            }
            for q in basis {
                var dot = 0.0
                for r in 0..<R { dot += v[r] * q[r] }
                for r in 0..<R { v[r] -= dot * q[r] }
            }
            var norm = 0.0
            for r in 0..<R { norm += v[r] * v[r] }
            norm = norm.squareRoot()
            if norm > 1e-12 {
                for r in 0..<R { v[r] /= norm }
                basis.append(v)
            }
        }
        return basis
    }

    static func removeTrend(_ y: inout [Double], _ basis: [[Double]]) {
        for q in basis {
            var dot = 0.0
            for r in y.indices { dot += y[r] * q[r] }
            for r in y.indices { y[r] -= dot * q[r] }
        }
    }
}
