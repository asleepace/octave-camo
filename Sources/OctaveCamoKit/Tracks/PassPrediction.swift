#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WASILibc)
import WASILibc
#endif

/// Where and when a recording was made, for predicting what aircraft it heard. Stays on the
/// device: only `ExpectedPass` curves (audio times and Doppler factors) reach the removal.
public struct Listener: Equatable {
    public var latitude: Double
    public var longitude: Double
    /// Height on the scale ADS-B uses (pressure altitude), m. From a phone's barometer when there
    /// is one; GPS height above sea level otherwise (off by the day's pressure, up to ~250 m,
    /// which moves the curves less than the archive's own timing does).
    public var altitude: Double
    /// Unix time of the audio's first sample, s.
    public var audioStart: Double
    /// Audio length, s.
    public var duration: Double
    /// Air temperature, °C, for the speed of sound.
    public var temperature: Double

    public init(latitude: Double, longitude: Double, altitude: Double = 0, audioStart: Double, duration: Double, temperature: Double = 15) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.audioStart = audioStart
        self.duration = duration
        self.temperature = temperature
    }

    var speedOfSound: Double { 331.3 + 0.606 * temperature }

    public var isValid: Bool {
        abs(latitude) <= 90 && abs(longitude) <= 180 && altitude.isFinite && abs(altitude) < 10_000
            && audioStart.isFinite && duration.isFinite && duration > 0 && temperature.isFinite && abs(temperature) < 60
    }
}

/// Predicts each nearby aircraft's Doppler curve at the listener from archived positions.
///
/// An archive position carries its 10 s block's time, not its own, so it can be a few seconds
/// old (on real passes: about 2 s on average, spread by 1–3 s). Velocity estimated from such
/// positions is noisy, and the curve's shape (what the attacker matches) depends on how they're
/// smoothed: on three real passes, no single estimate let removal beat an attacker holding the
/// exact tracks, but four together did. So each aircraft gets four curves:
///
/// 1. positions interpolated, velocity averaged over 10 s;
/// 2. the same over 20 s;
/// 3. a local straight-line fit over ±30 s (tricube weights);
/// 4. anchored to the archive's ground speed: direction from a ±45 s straight-line fit, speed
///    from the archive, positions placed by a ±60 s weighted fit along that path.
///
/// Removal tests each curve against its own null, so the extra curves cost time, not false
/// removals beyond each curve's own small chance.
public struct PassPrediction {
    /// Aircraft whose closest approach is farther than this are left out, m.
    public var maxDistance = 15_000.0
    /// ...and those whose closest approach is heard more than this outside the audio, s.
    public var closestMargin = 30.0
    /// Curves cover the audio and this much either side (the removal's null moves them a minute).
    public var span = 120.0
    /// Curve sample spacing, s.
    public var step = 0.1
    /// Positions from this far around the audio are used, s.
    public var positionMargin = 240.0

    public init() {}

    public enum Method: String, CaseIterable { case interpolated10, interpolated20, straight30, groundSpeed }

    /// One predicted curve: whose, how it was estimated, and the curve itself.
    public struct Prediction {
        public var aircraft: String
        public var method: Method
        public var closestDistance: Double
        public var pass: ExpectedPass
    }

    /// Every curve for every aircraft that comes close while the audio runs.
    public func predict(_ positions: [String: [AircraftPosition]], listener: Listener) -> [Prediction] {
        guard listener.isValid else { return [] }
        var out: [Prediction] = []
        for id in positions.keys.sorted() {
            let track = local(positions[id]!, listener)
            guard track.t.count >= 4 else { continue }
            for method in Method.allCases {
                guard let (te, q, v) = estimate(track, method) else { continue }
                if let p = curve(te, q, v, listener), p.distance <= maxDistance {
                    out.append(Prediction(aircraft: id, method: method, closestDistance: p.distance, pass: p.pass))
                }
            }
        }
        return out
    }

    /// Positions in metres east, north and up from the listener, at seconds from the audio's start.
    struct Local {
        var t: [Double] = []
        var p: [[Double]] = []        // [x, y, z] per position
        var speed: [Double?] = []     // ground speed, m/s
    }

    func local(_ positions: [AircraftPosition], _ l: Listener) -> Local {
        let cosLat = cos(l.latitude * .pi / 180), R = FlightArchive.earthRadius
        var out = Local(), lastT = -Double.infinity
        for a in positions.sorted(by: { $0.time < $1.time }) {
            let t = a.time - l.audioStart
            guard t > lastT, t >= -positionMargin, t <= l.duration + positionMargin else { continue }
            lastT = t
            out.t.append(t)
            out.p.append([(a.longitude - l.longitude) * .pi / 180 * R * cosLat, (a.latitude - l.latitude) * .pi / 180 * R,
                          a.altitudeFeet * 0.3048 - l.altitude])
            out.speed.append(a.groundSpeedKnots.map { $0 * 0.514_444 })
        }
        return out
    }

    /// Position and velocity on a regular grid by one method; nil when it can't run.
    func estimate(_ tr: Local, _ method: Method) -> (te: [Double], q: [[Double]], v: [[Double]])? {
        let te = Array(stride(from: tr.t.first!, to: tr.t.last!, by: step))
        guard te.count >= 10 else { return nil }
        let q = (0..<3).map { j in Self.interpolate(tr.t, tr.p.map { $0[j] }, te) }
        switch method {
        case .interpolated10, .interpolated20:
            let n = method == .interpolated10 ? 101 : 201
            let v = (0..<3).map { j in Self.movingAverage(Self.gradient(q[j], step), n) }
            return (te, Self.rows(q), Self.rows(v))
        case .straight30:
            let fit = Self.localLinear(tr.t, tr.p, te, half: 30)
            return (te, fit.q, fit.v)
        case .groundSpeed:
            let known = tr.speed.indices.filter { tr.speed[$0] != nil }
            guard known.count >= 4 else { return nil }
            let dir = Self.localLinear(tr.t, tr.p.map { [$0[0], $0[1]] }, te, half: 45).v
            let s = Self.movingAverage(Self.interpolate(known.map { tr.t[$0] }, known.map { tr.speed[$0]! }, te), 51)
            var path = [[Double]](repeating: [0, 0], count: te.count), vh = path
            var acc = [0.0, 0.0]
            for i in te.indices {
                let d = dir[i], n = (d[0] * d[0] + d[1] * d[1]).squareRoot()
                vh[i] = n > 0 && n.isFinite ? [s[i] * d[0] / n, s[i] * d[1] / n] : [0, 0]
                acc[0] += vh[i][0] * step
                acc[1] += vh[i][1] * step
                path[i] = acc
            }
            // Anchor the integrated path to the positions: a ±60 s weighted mean of the residuals.
            let px = Self.interpolate(te, path.map { $0[0] }, tr.t), py = Self.interpolate(te, path.map { $0[1] }, tr.t)
            let rx = tr.t.indices.map { tr.p[$0][0] - px[$0] }, ry = tr.t.indices.map { tr.p[$0][1] - py[$0] }
            let coarse = Array(stride(from: 0, to: te.count, by: 10))
            var ox: [Double] = [], oy: [Double] = [], ot: [Double] = []
            for i in coarse {
                var w = 0.0, sx = 0.0, sy = 0.0
                for k in tr.t.indices where abs(tr.t[k] - te[i]) < 60 {
                    let u = abs(tr.t[k] - te[i]) / 60, wk = pow(1 - u * u * u, 3)
                    w += wk; sx += wk * rx[k]; sy += wk * ry[k]
                }
                if w > 0 { ot.append(te[i]); ox.append(sx / w); oy.append(sy / w) }
            }
            guard ot.count >= 2 else { return nil }
            let fx = Self.interpolate(ot, ox, te), fy = Self.interpolate(ot, oy, te)
            let vert = Self.localLinear(tr.t, tr.p.map { [$0[2]] }, te, half: 30)
            let qq = te.indices.map { [path[$0][0] + fx[$0], path[$0][1] + fy[$0], vert.q[$0][0]] }
            let vv = te.indices.map { [vh[$0][0], vh[$0][1], vert.v[$0][0]] }
            return (te, qq, vv)
        }
    }

    /// The heard Doppler curve, closest approach and its distance; nil if it doesn't come near the audio.
    func curve(_ te: [Double], _ q: [[Double]], _ v: [[Double]], _ l: Listener) -> (pass: ExpectedPass, distance: Double)? {
        let c = l.speedOfSound
        var heard: [Double] = [], factor: [Double] = [], best = (r: Double.infinity, heard: 0.0)
        for i in te.indices {
            let p = q[i], u = v[i]
            guard p.allSatisfy(\.isFinite), u.allSatisfy(\.isFinite) else { continue }
            let r = (p[0] * p[0] + p[1] * p[1] + p[2] * p[2]).squareRoot()
            guard r > 1 else { continue }
            let vr = (p[0] * u[0] + p[1] * u[1] + p[2] * u[2]) / r
            let h = te[i] + r / c, f = 1 / (1 + vr / c)
            if r < best.r { best = (r, h) }
            guard h >= -span, h <= l.duration + span, f > 0.5, f < 2 else { continue }
            // Rounded to the millisecond and strictly increasing, as `ExpectedPass` requires.
            let hr = (h * 1_000).rounded() / 1_000
            if let last = heard.last, hr <= last { continue }
            heard.append(hr)
            factor.append((f * 1e7).rounded() / 1e7)
        }
        guard best.r.isFinite, best.heard > -closestMargin, best.heard < l.duration + closestMargin, heard.count >= 20 else { return nil }
        let pass = ExpectedPass(times: heard, factors: factor, closest: (best.heard * 1_000).rounded() / 1_000)
        return pass.isValid ? (pass, best.r) : nil
    }

    // MARK: Numerics

    static func rows(_ cols: [[Double]]) -> [[Double]] { cols[0].indices.map { i in cols.map { $0[i] } } }

    /// Linear interpolation of (xs, ys) at `at`, holding the end values outside.
    static func interpolate(_ xs: [Double], _ ys: [Double], _ at: [Double]) -> [Double] {
        guard let first = xs.first, let last = xs.last else { return at.map { _ in .nan } }
        var out = [Double](repeating: 0, count: at.count), j = 0
        for (i, t) in at.enumerated() {
            if t <= first { out[i] = ys[0]; continue }
            if t >= last { out[i] = ys[ys.count - 1]; continue }
            while j + 1 < xs.count && xs[j + 1] < t { j += 1 }
            while j > 0 && xs[j] > t { j -= 1 }
            let w = (t - xs[j]) / (xs[j + 1] - xs[j])
            out[i] = ys[j] + w * (ys[j + 1] - ys[j])
        }
        return out
    }

    /// Central differences inside, one-sided at the ends (numpy.gradient).
    static func gradient(_ y: [Double], _ dx: Double) -> [Double] {
        let n = y.count
        guard n >= 2 else { return [Double](repeating: 0, count: n) }
        var g = [Double](repeating: 0, count: n)
        g[0] = (y[1] - y[0]) / dx
        g[n - 1] = (y[n - 1] - y[n - 2]) / dx
        for i in 1..<(n - 1) { g[i] = (y[i + 1] - y[i - 1]) / (2 * dx) }
        return g
    }

    /// Centred moving average over `n` samples, edges extended (scipy uniform_filter1d, nearest).
    static func movingAverage(_ y: [Double], _ n: Int) -> [Double] {
        let count = y.count, h = n / 2
        guard count > 0 else { return y }
        var prefix = [Double](repeating: 0, count: count + 2 * h + 1)
        for i in 0..<(count + 2 * h) {
            let k = min(max(i - h, 0), count - 1)
            prefix[i + 1] = prefix[i] + y[k]
        }
        return (0..<count).map { (prefix[$0 + n] - prefix[$0]) / Double(n) }
    }

    /// A tricube-weighted straight-line fit around each grid time: position and velocity.
    static func localLinear(_ t: [Double], _ p: [[Double]], _ te: [Double], half: Double) -> (q: [[Double]], v: [[Double]]) {
        let d = p.first?.count ?? 0
        var q = [[Double]](repeating: [Double](repeating: .nan, count: d), count: te.count), v = q
        var lo = 0
        for (i, c) in te.enumerated() {
            while lo < t.count && t[lo] <= c - half { lo += 1 }
            var sw = 0.0, sx = 0.0, sxx = 0.0, n = 0
            var sy = [Double](repeating: 0, count: d), sxy = sy
            var k = lo
            while k < t.count && t[k] < c + half {
                let x = t[k] - c, u = abs(x) / half, w = pow(1 - u * u * u, 3)
                sw += w; sx += w * x; sxx += w * x * x; n += 1
                for j in 0..<d { sy[j] += w * p[k][j]; sxy[j] += w * x * p[k][j] }
                k += 1
            }
            let det = sw * sxx - sx * sx
            guard n >= 3, det > 1e-9 else { continue }
            for j in 0..<d {
                v[i][j] = (sw * sxy[j] - sx * sy[j]) / det
                q[i][j] = (sy[j] - v[i][j] * sx) / sw
            }
        }
        return (q, v)
    }
}
