import Foundation
@testable import OctaveCamoKit

/// Scenes for measuring the check itself: how weak a tone it still finds, and how often it reports
/// a tone in noise that has none (ACOUSTICS.md §9). Strengths are in dB over the noise in a 1 Hz
/// band, so they mean the same at any sample rate.
enum DetectionScenes {
    /// White noise level (standard deviation) for the ladder.
    static let noiseSigma = 0.01

    /// Amplitude of a sine `snr` dB over white noise of `sigma` in a 1 Hz band at `rate`.
    /// Noise power per Hz (one-sided) is 2σ²/rate; a sine's power is A²/2.
    static func amplitude(snr: Double, sigma: Double = noiseSigma, rate: Int) -> Double {
        (4 * sigma * sigma * pow(10, snr / 10) / Double(rate)).squareRoot()
    }

    static func white(_ n: Int, sigma: Double = noiseSigma, seed: UInt64) -> [Double] {
        var rng = SeededRNG(seed: seed)
        return rng.normals(n).map { sigma * $0 }
    }

    /// A steady tone (with a slight ±0.02 % wander, as real sources have) in white noise.
    static func steady(hz: Double, snr: Double, rate: Int, seconds: Double = 20, seed: UInt64) -> Audio {
        var x = white(Int(Double(rate) * seconds), seed: seed)
        let a = amplitude(snr: snr, rate: rate)
        for i in x.indices {
            let t = Double(i) / Double(rate)
            x[i] += a * sin(2 * .pi * hz * (t + 0.0002 * 5 / (2 * .pi) * sin(2 * .pi * t / 5)) + Double(seed))
        }
        return Audio(sampleRate: rate, channels: [x])
    }

    /// A passing source's tone: f0 = `hz`, closest approach mid-clip (the frequency path of FlybyGeometry).
    static func drifting(hz: Double, snr: Double, rate: Int, speed: Double = 100, distance: Double = 1_000,
                         seconds: Double = 30, seed: UInt64) -> (audio: Audio, path: ClosedRange<Double>) {
        let n = Int(Double(rate) * seconds)
        var x = white(n, seed: seed)
        let geometry = FlybyGeometry(f0: hz, speed: speed, t0: seconds / 2, distance: distance)
        let t = (0..<n).map { Double($0) / Double(rate) }
        let f = geometry.received(at: t).frequency
        let a = amplitude(snr: snr, rate: rate)
        var phase = Double(seed)
        for i in 0..<n {
            phase += 2 * .pi * f[i] / Double(rate)
            x[i] += a * sin(phase)
        }
        return (Audio(sampleRate: rate, channels: [x]), f.min()!...f.max()!)
    }

    /// A tone that cycles on for 4 s and off for 6 s (a compressor, a pump), 30 s in all.
    static func intermittent(hz: Double, snr: Double, rate: Int, seed: UInt64) -> Audio {
        let n = rate * 30
        var x = white(n, seed: seed)
        let a = amplitude(snr: snr, rate: rate)
        for i in 0..<n {
            let t = Double(i) / Double(rate), local = t.truncatingRemainder(dividingBy: 10)
            guard local < 4 else { continue }
            let gate = min(1, local / 0.05, (4 - local) / 0.05)
            x[i] += a * gate * sin(2 * .pi * hz * t)
        }
        return Audio(sampleRate: rate, channels: [x])
    }

    /// Grid harmonics 120…1200 Hz of 60 Hz with no fundamental (a phone mic cuts it), each `snr`
    /// dB over the noise, all wandering together like the grid (±0.02 Hz at 60 Hz).
    static func gridFamily(snr: Double, rate: Int, seed: UInt64) -> Audio {
        let n = rate * 30
        var x = white(n, seed: seed)
        let a = amplitude(snr: snr, rate: rate)
        var phase = 0.0
        for i in 0..<n {
            let t = Double(i) / Double(rate)
            let grid = 60 + 0.02 * sin(2 * .pi * t / 11) + 0.01 * sin(2 * .pi * t / 3.7)
            phase += 2 * .pi * grid / Double(rate)
            for k in 2...20 { x[i] += a * sin(Double(k) * phase + Double(k)) }
        }
        return Audio(sampleRate: rate, channels: [x])
    }

    /// Noise with no tone in it, for counting false lines.
    static func noise(_ kind: String, rate: Int, seconds: Double = 60, seed: UInt64) -> Audio {
        let n = Int(Double(rate) * seconds)
        var rng = SeededRNG(seed: seed)
        let w = rng.normals(n)
        var x = [Double](repeating: 0, count: n)
        switch kind {
        case "white":
            for i in 0..<n { x[i] = 0.01 * w[i] }
        case "pink":
            // Paul Kellet's economy filter: about −3 dB per octave.
            var b0 = 0.0, b1 = 0.0, b2 = 0.0
            for i in 0..<n {
                b0 = 0.99765 * b0 + w[i] * 0.0990460
                b1 = 0.96300 * b1 + w[i] * 0.2965164
                b2 = 0.57000 * b2 + w[i] * 1.0526913
                x[i] = 0.01 * (b0 + b1 + b2 + w[i] * 0.1848)
            }
        case "wind":
            // Low rumble in gusts: noise low-passed near 150 Hz, its level swelling over seconds.
            var low = 0.0
            let k = 1 - exp(-2 * Double.pi * 150 / Double(rate))
            let g1 = rng.uniform(5...9), g2 = rng.uniform(2...4)
            for i in 0..<n {
                let t = Double(i) / Double(rate)
                low += k * (w[i] - low)
                let gust = 0.3 + 0.7 * pow(max(0, sin(2 * .pi * t / g1) * 0.6 + sin(2 * .pi * t / g2) * 0.4), 2)
                x[i] = 0.2 * gust * low + 0.002 * w[i]
            }
        case "traffic":
            // Distant road: brown-ish rumble with slow swells as cars pass, plus broadband hiss.
            var brown = 0.0
            for i in 0..<n {
                let t = Double(i) / Double(rate)
                brown = 0.998 * brown + 0.05 * w[i]
                let swell = 0.6 + 0.4 * sin(2 * .pi * t / 13) * sin(2 * .pi * t / 7)
                x[i] = 0.02 * swell * brown + 0.004 * swell * w[i]
            }
        default: fatalError("no noise \(kind)")
        }
        return Audio(sampleRate: rate, channels: [x])
    }
}

/// How the check did on one scene: whether it found the tone, and how much of it.
struct Detection {
    /// Tracks overlapping the tone's frequency band.
    let matches: [TrackReport]
    let toneSeconds: Double

    init(_ analysis: Analysis, band: ClosedRange<Double>, toneSeconds: Double) {
        let margin = { (f: Double) in max(3, 0.01 * f) }
        matches = analysis.tracks.filter { $0.maxFrequency + margin($0.maxFrequency) >= band.lowerBound && $0.minFrequency - margin($0.minFrequency) <= band.upperBound }
        self.toneSeconds = toneSeconds
    }

    var found: Bool { !matches.isEmpty }
    /// Share of the tone's time covered by matching tracks (overlaps counted once, roughly: capped at 1).
    var coverage: Double { min(1, matches.map(\.duration).reduce(0, +) / max(toneSeconds, 1e-9)) }
}
