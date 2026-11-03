import Foundation

/// A straight-line, constant-speed flyby past a stationary microphone.
/// Shared by the synthesizer (what to render) and the fitter (what it estimated).
public struct FlybyGeometry: Codable, Equatable {
    public static let speedOfSound = 343.0

    /// True (unshifted) tone, Hz.
    public var f0: Double
    /// Ground speed, m/s.
    public var speed: Double
    /// Receive time of closest approach, seconds into the clip.
    public var t0: Double
    /// Closest-approach distance, m.
    public var distance: Double

    public init(f0: Double, speed: Double, t0: Double, distance: Double) {
        self.f0 = f0
        self.speed = speed
        self.t0 = t0
        self.distance = distance
    }

    /// Received frequency and source range at each receive time, including propagation delay:
    /// sound heard at t left the aircraft at the emission time tau, where tau + range(tau)/c = t.
    public func received(at t: [Double]) -> (frequency: [Double], range: [Double]) {
        let c = Self.speedOfSound
        let emissionT0 = t0 - distance / c
        var frequency = [Double](repeating: 0, count: t.count)
        var range = [Double](repeating: 0, count: t.count)

        // Newton's method on g(tau) = tau + r(tau)/c - t; g' > 0 because speed < c.
        // Warm-started from the previous sample, so it usually converges in 1–2 steps.
        var tau = (t.first ?? 0) - distance / c
        var previousT = t.first ?? 0
        for i in t.indices {
            tau += t[i] - previousT
            previousT = t[i]
            for _ in 0..<8 {
                let dx = speed * (tau - emissionT0)
                let r = (dx * dx + distance * distance).squareRoot()
                let g = tau + r / c - t[i]
                tau -= g / (1 + speed * dx / (c * r))
                if abs(g) < 1e-12 { break }
            }
            let dx = speed * (tau - emissionT0)
            let r = (dx * dx + distance * distance).squareRoot()
            // Radial velocity toward the mic is -speed·dx/r.
            frequency[i] = f0 / (1 + speed * dx / (r * c))
            range[i] = r
        }
        return (frequency, range)
    }
}
