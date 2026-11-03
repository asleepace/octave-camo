import Foundation

/// Generates a known-truth test clip: one flyby (tone + 2 harmonics), mains hum with ENF wander,
/// pink noise and speech-like syllables, as fake stereo.
public struct FlybySynth {
    public var flyby = FlybyGeometry(f0: 120, speed: 75, t0: 30, distance: 1_500)
    public var duration = 60.0
    public var sampleRate = 48_000
    /// Adds turbulence jitter and a ground reflection (moving comb fades).
    public var hard = false
    public var seed: UInt64 = 1

    public init() {}

    /// Relative amplitudes of the engine tone's harmonics.
    static let harmonics: [(multiple: Double, gain: Double)] = [(1, 1.0), (2, 0.6), (3, 0.4)]

    public func render() -> Audio {
        var rng = SeededRNG(seed: seed)
        let n = Int(Double(sampleRate) * duration)
        let t = (0..<n).map { Double($0) / Double(sampleRate) }

        var x = engine(t, &rng)
        if hard { x = groundReflection(x, t) }
        let hum = mainsHum(t)
        let noise = pinkNoise(n, &rng)
        let speech = syllables(n, &rng)
        for i in x.indices { x[i] += hum[i] + noise[i] + speech[i] }

        // Fake stereo: right is a slightly quieter copy with its own noise.
        let right = x.map { $0 * 0.9 + 0.002 * rng.normal() }
        let g = 1 / (max(DSP.peakMagnitude(x), DSP.peakMagnitude(right)) * 1.1)
        return Audio(sampleRate: sampleRate, channels: [x.map { $0 * g }, right.map { $0 * g }])
    }

    // MARK: Components

    /// Doppler-shifted tone with 1/r spreading and slow atmospheric amplitude wander.
    func engine(_ t: [Double], _ rng: inout SeededRNG) -> [Double] {
        let n = t.count
        let received = flyby.received(at: t)
        var f = received.frequency
        let wander = DSP.resample(DSP.movingAverage(rng.normals(n / 4_800 + 10), length: 5).map { 1 + 0.3 * $0 },
                                  over: duration, at: t)
        if hard {
            // Turbulence: ~0.3% frequency jitter band-limited to a few Hz.
            let raw = DSP.movingAverage(rng.normals(n / 480 + 10), length: 8)
            let s = DSP.standardDeviation(raw)
            let jitter = DSP.resample(raw.map { $0 * 0.003 / s }, over: duration, at: t)
            for i in 0..<n { f[i] *= 1 + jitter[i] }
        }
        let amplitude = (0..<n).map { flyby.distance / received.range[$0] * wander[$0] }

        var x = [Double](repeating: 0, count: n)
        for h in Self.harmonics {
            let phase = DSP.cumulativePhase(f.map { $0 * h.multiple }, dt: 1 / Double(sampleRate))
            for i in 0..<n { x[i] += 0.05 * h.gain * amplitude[i] * sin(phase[i]) }
        }
        return x
    }

    /// Delayed copy whose delay drifts with geometry, producing moving comb-filter fades.
    func groundReflection(_ x: [Double], _ t: [Double]) -> [Double] {
        let n = x.count, sr = Double(sampleRate)
        return (0..<n).map { i in
            let delay = 0.004 + 0.003 * cos(Double.pi * (t[i] - flyby.t0) / duration)
            let pos = DSP.clamp(Double(i) - delay * sr, 0, Double(n - 1))
            let i0 = Int(pos), i1 = min(i0 + 1, n - 1)
            return x[i] + 0.7 * (x[i0] + (pos - Double(i0)) * (x[i1] - x[i0]))
        }
    }

    /// 60 Hz with two slow ENF wanders, plus 2nd and 3rd harmonics.
    func mainsHum(_ t: [Double]) -> [Double] {
        let enf = t.map { 60 + 0.02 * sin(2 * Double.pi * $0 / 17) + 0.01 * sin(2 * Double.pi * $0 / 5.3) }
        return DSP.cumulativePhase(enf, dt: 1 / Double(sampleRate)).map {
            0.004 * (sin($0) + 0.5 * sin(2 * $0) + 0.3 * sin(3 * $0))
        }
    }

    /// White noise shaped by 1/sqrt(f), normalized to 0.01 RMS.
    func pinkNoise(_ n: Int, _ rng: inout SeededRNG) -> [Double] {
        let size = DSP.nextPowerOfTwo(atLeast: n)
        var re = rng.normals(size)
        var im = [Double](repeating: 0, count: size)
        let fft = FFT(size: size)
        fft.forward(&re, &im)
        re[0] = 0; im[0] = 0
        let binHz = Double(sampleRate) / Double(size)
        for i in 1..<size {
            let g = 1 / (Double(min(i, size - i)) * binHz).squareRoot()
            re[i] *= g; im[i] *= g
        }
        fft.inverse(&re, &im)
        let pink = Array(re[0..<n])
        let s = DSP.standardDeviation(pink)
        return pink.map { $0 * 0.01 / s }
    }

    /// Short harmonic stacks with 100–220 Hz fundamentals and a slight pitch bend.
    func syllables(_ n: Int, _ rng: inout SeededRNG) -> [Double] {
        let sr = Double(sampleRate)
        var out = [Double](repeating: 0, count: n)
        var at = 0.5
        while at < duration - 1 {
            let length = rng.uniform(0.15...0.4)
            let m = Int(length * sr), start = Int(at * sr)
            let pitch = rng.uniform(100...220), bend = rng.uniform(-1...1)
            // Pitch glides linearly from (1 − 0.1·bend) to (1 + 0.1·bend) × pitch over the syllable.
            let span = Double(max(m - 1, 1))
            let f: [Double] = (0..<m).map { i -> Double in
                let position: Double = 2 * Double(i) / span - 1
                return pitch * (1 + 0.1 * position * bend)
            }
            let phase = DSP.cumulativePhase(f, dt: 1 / sr)
            for i in 0..<m where start + i < n {
                let envelope = pow(sin(Double.pi * Double(i) / Double(m)), 2)
                var stack = 0.0
                for k in 1..<25 {
                    let kd = Double(k)
                    stack += (0.6 / kd) * sin(kd * phase[i]) * (kd * 180 > 300 ? 1 : 0.5)
                }
                out[start + i] += 0.03 * envelope * stack
            }
            at += length + rng.uniform(0.05...0.6)
        }
        return out
    }
}
