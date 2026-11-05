#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WASILibc)
import WASILibc
#endif

public enum TrackKind: String, Codable {
    /// Steady near a 50/60 Hz multiple: ENF timestamp risk.
    case hum
    /// Long tone with no sweep (HVAC, fridge): no geometry to recover.
    case steady
    /// Good flyby fit: location risk.
    case doppler
    /// Swept, but the flyby model doesn't fit.
    case noFit
}

public struct DopplerFit: Codable {
    public let geometry: FlybyGeometry
    /// RMS fit residual, Hz.
    public let rms: Double
}

public struct TrackReport: Codable {
    public let kind: TrackKind
    /// When the track begins, seconds into the clip.
    public let start: Double
    public let meanFrequency: Double
    public let minFrequency: Double
    public let maxFrequency: Double
    public let duration: Double
    public let fit: DopplerFit?
}

public struct Analysis {
    /// All long tones, longest first.
    public let tracks: [TrackReport]

    public var flybys: [TrackReport] { tracks.filter { $0.kind == .doppler } }
    public var hum: [TrackReport] { tracks.filter { $0.kind == .hum } }

    /// Duration-weighted consensus of speed, t0 and distance across good flyby fits
    /// (harmonics of one plane should agree on these). f0 is the lowest fitted tone,
    /// since each harmonic is fitted separately and their f0s are multiples, not estimates
    /// of one value.
    public var consensus: FlybyGeometry? {
        let fits = flybys.compactMap { r in r.fit.map { ($0.geometry, r.duration) } }
        guard let fundamental = fits.map({ $0.0.f0 }).min() else { return nil }
        let w = fits.map { $0.1 }
        func avg(_ value: (FlybyGeometry) -> Double) -> Double {
            DSP.weightedMean(fits.map { value($0.0) }, weights: w)
        }
        return FlybyGeometry(f0: fundamental, speed: avg(\.speed), t0: avg(\.t0), distance: avg(\.distance))
    }
}

/// The attacker: classify each long tone and fit the flyby model to the swept ones.
public struct FlybyAnalyzer {
    public struct Config {
        public var humBaseFrequencies: [Double] = [50, 60]
        public var humToleranceHz = 1.0
        /// Above this, a steady tone near a 50/60 Hz multiple is not called hum: multiples are
        /// so dense up there that ±1 Hz would catch many unrelated tones.
        public var humMaxFrequency = 1_000.0
        public var humMaxStandardDeviation = 0.6
        public var humMaxSweep = 0.05
        /// Below this sweep a tone carries no usable Doppler shape.
        public var steadyMaxSweep = 0.01
        /// A fit counts as a flyby when rms / f0 is below this.
        public var maxRelativeRMS = 0.005
        /// Multi-start multipliers on the initial distance guess.
        public var distanceStarts: [Double] = [0.5, 1, 2]
        public var speedLimits: ClosedRange<Double> = 5...340
        /// A good fit only counts as a flyby when it is physically plausible for an aircraft.
        /// Rejects fits pinned at the optimizer's limits, e.g. "5 m/s at 2 m" from a voice harmonic.
        public var plausibleSpeed: ClosedRange<Double> = 20...300
        /// …and within earshot. A slight drift in a steady sound (footsteps' 80 Hz thud, looped)
        /// fits a "pass" 10¹⁷ m away whose closest approach is outside the clip; a real engine tone
        /// is inaudible well before 30 km.
        public var plausibleDistance: ClosedRange<Double> = 50...30_000

        public init() {}
    }

    public var config: Config
    public var tracker: ToneTracker
    /// Finds weak steady lines by integrating over seconds (nil: the frame tracker alone).
    public var integrator: LineIntegrator? = LineIntegrator()
    /// Finds fast falling sweeps the tracker smears (nil: off). Only those its flyby fit accepts
    /// are kept, so a falling note or a siren is never reported, or filled, from here.
    public var paths: PathSearch? = PathSearch()
    var optimizer = NelderMead()

    /// The attacker's tracker: the scrubber's range (40 Hz–1 kHz), plus 1–8 kHz with its own peak
    /// budget, where a jet's fan whine or an electrical whine can sit. The page's counts come
    /// from this, so they cover more than the cloak removes: a tone up there is counted, not hidden.
    public static var attackerTracker: ToneTracker {
        var t = ToneTracker()
        t.config.extraRanges = [1_000...8_000]
        return t
    }

    public init(config: Config = Config(), tracker: ToneTracker = FlybyAnalyzer.attackerTracker) {
        self.config = config
        self.tracker = tracker
    }

    public func analyze(_ audio: Audio) -> Analysis {
        let found = lines(in: audio)
        let reports = found.tracked.map(classify) + found.integrated.map(classifyLine)
        return Analysis(tracks: reports.sorted { $0.duration > $1.duration })
    }

    /// Every line the check reports, with its frequency path: the frame tracker's tracks and the
    /// path search's flyby passes, then the integrator's weak steady lines that no tracker track
    /// already covers (where both found the same line, the tracker's version is kept). `analyze`
    /// classifies exactly these; the `lines` scrub stage fills them in.
    public func lines(in audio: Audio) -> (tracked: [Track], integrated: [Track]) {
        let mono = audio.mono
        let framed = tracker.tracks(in: mono, sampleRate: audio.sampleRate)
        var passes: [Track] = []
        if let paths {
            for pass in paths.tracks(in: mono, sampleRate: audio.sampleRate)
            where !framed.contains(where: { Self.follows($0, pass) }) && classify(pass).kind == .doppler {
                passes.append(pass)
            }
        }
        guard let integrator else { return (framed + passes, []) }
        // A pass's box spans its whole sweep, so it isn't used here: it would hide the steady
        // lines it crosses (the integrator's lines drift too slowly to be a pass themselves).
        var boxes = framed.map(Self.box), integrated: [Track] = []
        for line in integrator.tracks(in: mono, sampleRate: audio.sampleRate) where !boxes.contains(where: { Self.sameLine($0, line) }) {
            integrated.append(line)
            boxes.append(Self.box(line))
        }
        return (framed + passes, integrated)
    }

    /// `a` follows `b`: for at least half of `b`'s points, `a` (interpolated, inside its own span)
    /// is within max(9 Hz, 1 %) of it. A box test would let a steady hum crossing a sweep's range
    /// hide the sweep.
    static func follows(_ a: Track, _ b: Track) -> Bool {
        guard let a0 = a.times.first, let a1 = a.times.last, a.times.count > 1 else { return false }
        var inside = 0, close = 0, j = 0
        for (t, f) in zip(b.times, b.frequencies) where t >= a0 && t <= a1 {
            inside += 1
            while j + 1 < a.times.count && a.times[j + 1] < t { j += 1 }
            let k = min(j + 1, a.times.count - 1)
            let w = a.times[k] > a.times[j] ? (t - a.times[j]) / (a.times[k] - a.times[j]) : 0
            let fa = a.frequencies[j] + w * (a.frequencies[k] - a.frequencies[j])
            if abs(fa - f) <= max(9, 0.01 * f) { close += 1 }
        }
        return inside > 0 && 2 * close >= b.times.count
    }

    /// A track's time and frequency extent (the fields `sameLine` compares).
    static func box(_ track: Track) -> TrackReport {
        TrackReport(kind: .steady, start: track.times.first ?? 0, meanFrequency: track.meanFrequency,
                    minFrequency: track.minFrequency, maxFrequency: track.maxFrequency, duration: track.duration, fit: nil)
    }

    /// A line from the integrator: hum, or a steady tone. Its drift is slow by construction, so a
    /// Doppler fit would only invent geometry; passing sources are the frame tracker's.
    public func classifyLine(_ track: Track) -> TrackReport {
        TrackReport(kind: isHum(track) ? .hum : .steady, start: track.times.first ?? 0, meanFrequency: track.meanFrequency,
                    minFrequency: track.minFrequency, maxFrequency: track.maxFrequency, duration: track.duration, fit: nil)
    }

    /// Overlapping in time, and in frequency within max(3 Hz, 1 %).
    static func sameLine(_ r: TrackReport, _ t: Track) -> Bool {
        let margin = max(3, 0.01 * t.meanFrequency)
        let timeOverlap = r.start <= (t.times.last ?? 0) && (t.times.first ?? 0) <= r.start + r.duration
        return timeOverlap && r.minFrequency - margin <= t.maxFrequency && t.minFrequency <= r.maxFrequency + margin
    }

    public func classify(_ track: Track) -> TrackReport {
        func report(_ kind: TrackKind, _ fit: DopplerFit? = nil) -> TrackReport {
            TrackReport(kind: kind, start: track.times.first ?? 0, meanFrequency: track.meanFrequency, minFrequency: track.minFrequency,
                        maxFrequency: track.maxFrequency, duration: track.duration, fit: fit)
        }
        if isHum(track) { return report(.hum) }
        if track.sweep < config.steadyMaxSweep { return report(.steady) }
        let fit = fitFlyby(track)
        return report(isFlyby(fit) ? .doppler : .noFit, fit)
    }

    func isFlyby(_ fit: DopplerFit) -> Bool {
        fit.rms / fit.geometry.f0 < config.maxRelativeRMS
            && config.plausibleSpeed.contains(fit.geometry.speed)
            && config.plausibleDistance.contains(fit.geometry.distance)
    }

    func isHum(_ track: Track) -> Bool {
        let m = track.meanFrequency
        guard m <= config.humMaxFrequency, DSP.standardDeviation(track.frequencies) <= config.humMaxStandardDeviation,
              track.sweep <= config.humMaxSweep else { return false }
        return config.humBaseFrequencies.contains { abs(m - $0 * (m / $0).rounded()) < config.humToleranceHz }
    }

    func fitFlyby(_ track: Track) -> DopplerFit {
        let t = track.times, f = track.frequencies
        let start = initialGuess(t, f)

        // Parameters: [f0, speed, t0, ln distance]; log keeps distance positive and well scaled.
        func loss(_ p: [Double]) -> Double {
            guard config.speedLimits.contains(p[1]) else { return 1e9 }
            let model = FlybyGeometry(f0: p[0], speed: p[1], t0: p[2], distance: exp(p[3])).received(at: t).frequency
            var sum = 0.0
            for i in f.indices { let e = model[i] - f[i]; sum += e * e }
            let mse = sum / Double(f.count)
            return mse.isFinite ? mse : 1e9   // exp(ln d) can overflow at extreme simplex points
        }

        let scale = [0.02 * start.f0, 0.2 * start.speed, 1.0, 0.5]
        let results = config.distanceStarts.map { multiplier in
            optimizer.minimize(loss, start: [start.f0, start.speed, start.t0, log(start.distance * multiplier)],
                               scale: scale)
        }
        let best = results.min(by: { $0.value < $1.value })
            ?? optimizer.minimize(loss, start: [start.f0, start.speed, start.t0, log(start.distance)], scale: scale)
        let p = best.point
        return DopplerFit(geometry: FlybyGeometry(f0: p[0], speed: p[1], t0: p[2], distance: exp(p[3])),
                          rms: best.value.squareRoot())
    }

    /// Reads a starting point off the curve's shape.
    func initialGuess(_ t: [Double], _ f: [Double]) -> FlybyGeometry {
        let n = f.count
        let c = FlybyGeometry.speedOfSound
        // Closest approach is where the frequency falls fastest.
        let slope = DSP.gradient(DSP.movingAverage(f, length: 5), t)
        var k = n / 2
        if n > 7 {
            k = (3..<(n - 3)).min(by: { slope[$0] < slope[$1] }) ?? k
        }
        // Approach and recede plateaus give speed and true frequency.
        let edge = max(3, n / 10)
        let fHigh = DSP.mean(f.prefix(edge))
        let fLow = DSP.mean(f.suffix(edge))
        let beta = DSP.clamp((fHigh - fLow) / (fHigh + fLow), 0.01, 0.9)
        let f0 = 0.5 * (fHigh + fLow)
        let speed = DSP.clamp(beta * c, 10, 330)
        // At closest approach |df/dt| = f0·beta·speed / distance.
        let distance = DSP.clamp(f0 * beta * speed / max(abs(slope[k]), 1e-3), 20, 30_000)
        return FlybyGeometry(f0: f0, speed: speed, t0: t[k], distance: distance)
    }
}
