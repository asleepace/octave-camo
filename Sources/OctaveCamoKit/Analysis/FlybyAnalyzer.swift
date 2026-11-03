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
        public var minPlausibleDistance = 50.0

        public init() {}
    }

    public var config: Config
    public var tracker: ToneTracker
    var optimizer = NelderMead()

    public init(config: Config = Config(), tracker: ToneTracker = ToneTracker()) {
        self.config = config
        self.tracker = tracker
    }

    public func analyze(_ audio: Audio) -> Analysis {
        let reports = tracker.tracks(in: audio.mono, sampleRate: audio.sampleRate).map(classify)
        return Analysis(tracks: reports.sorted { $0.duration > $1.duration })
    }

    public func classify(_ track: Track) -> TrackReport {
        func report(_ kind: TrackKind, _ fit: DopplerFit? = nil) -> TrackReport {
            TrackReport(kind: kind, meanFrequency: track.meanFrequency, minFrequency: track.minFrequency,
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
            && fit.geometry.distance >= config.minPlausibleDistance
    }

    func isHum(_ track: Track) -> Bool {
        let m = track.meanFrequency
        guard DSP.standardDeviation(track.frequencies) <= config.humMaxStandardDeviation,
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
