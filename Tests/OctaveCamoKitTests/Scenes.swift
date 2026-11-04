import Foundation
@testable import OctaveCamoKit

/// Synthetic recordings for behavior snapshots and invariants: the clues the cloak must remove,
/// and the ordinary sounds it must leave alone. Deterministic (fixed seeds).
enum Scenes {
    /// Every scene, by name. `rate` is the sample rate; durations are fixed per scene.
    static let names = [
        "plane", "plane-hard", "hum-60", "hum-50-harmonics", "speech", "singing", "whistle", "birdsong",
        "held-notes", "footsteps", "silence", "tone-1200", "tone-4500",
    ]
    /// Scenes with no location clue: the cloak should change them as little as possible.
    static let harmless = ["speech", "singing", "whistle", "birdsong", "footsteps", "silence"]

    static func make(_ name: String, rate: Int = 32_000) -> Audio {
        switch name {
        case "plane", "plane-hard":
            var synth = FlybySynth()
            synth.flyby = FlybyGeometry(f0: 120, speed: 75, t0: 10, distance: 800)
            synth.duration = 20
            synth.sampleRate = rate
            synth.hard = name == "plane-hard"
            synth.seed = 3
            return synth.render()
        case "hum-60": return mono(rate, 15, seed: 21) { t, x, _ in x + hum(t, base: 60, from: 60, to: 600) }
        case "hum-50-harmonics":
            // A phone mic cuts the fundamental: only 100 Hz and up, with the grid's wander.
            return mono(rate, 15, seed: 22) { t, x, _ in x + hum(t, base: 50, from: 100, to: 1_000) }
        case "speech": return mono(rate, 15, seed: 23) { t, x, s in x + speech(t, state: &s) }
        case "singing": return mono(rate, 15, seed: 24) { t, x, s in x + singing(t, state: &s) }
        case "whistle": return mono(rate, 15, seed: 25) { t, x, s in x + whistle(t, state: &s) }
        case "birdsong": return mono(rate, 15, seed: 26) { t, x, _ in x + birdsong(t) }
        case "held-notes": return mono(rate, 15, seed: 27) { t, x, _ in x + heldNotes(t) }
        case "footsteps": return mono(rate, 15, seed: 28) { t, x, _ in x + footsteps(t) }
        case "silence": return Audio(sampleRate: rate, channels: [[Double](repeating: 0, count: rate * 10)])
        case "tone-1200": return mono(rate, 15, seed: 29) { t, x, _ in x + 0.02 * sin(2 * .pi * (1_200 * t + 0.6 * sin(2 * .pi * t / 9))) }
        case "tone-4500": return mono(rate, 15, seed: 30) { t, x, _ in x + 0.01 * sin(2 * .pi * 4_500 * t) }
        default: fatalError("no scene \(name)")
        }
    }

    /// Light noise plus `add(t, noise, phase)` per sample; `phase` is a running phase (radians)
    /// that gliding sounds advance by 2π·f·dt.
    private static func mono(_ rate: Int, _ seconds: Double, seed: UInt64,
                             _ add: (Double, Double, inout Phase) -> Double) -> Audio {
        let n = Int(Double(rate) * seconds)
        var rng = SeededRNG(seed: seed)
        let noise = rng.normals(n).map { 0.004 * $0 }
        var phase = Phase(dt: 1 / Double(rate))
        var x = [Double](repeating: 0, count: n)
        for i in 0..<n { x[i] = add(Double(i) / Double(rate), noise[i], &phase) }
        return Audio(sampleRate: rate, channels: [x])
    }

    struct Phase {
        let dt: Double
        var value = 0.0
        mutating func advance(_ hz: Double) -> Double { value += 2 * .pi * hz * dt; return value }
    }

    // MARK: Sounds

    /// Mains harmonics between `from` and `to` Hz, drifting together like the grid (±0.03 %).
    static func hum(_ t: Double, base: Double, from: Double, to: Double) -> Double {
        let drift = 1 + 0.0003 * sin(2 * .pi * t / 7)
        var y = 0.0, h = from
        while h <= to {
            y += 0.004 * sin(2 * .pi * h * drift * t)
            h += base
        }
        return y
    }

    /// Syllables of a gliding voice (f0 ≈ 140 Hz): 0.25 s on, 0.15 s off.
    static func speech(_ t: Double, state: inout Phase) -> Double {
        let f0 = 140 * (1 + 0.08 * sin(2 * .pi * 0.7 * t) + 0.02 * sin(2 * .pi * 5 * t))
        let phase = state.advance(f0)
        let cycle = t.truncatingRemainder(dividingBy: 0.4)
        guard cycle < 0.25 else { return 0 }
        let gate = sin(.pi * cycle / 0.25)
        var y = 0.0
        for h in 1...20 where Double(h) * f0 < 7_000 {
            let formants = exp(-pow((Double(h) * f0 - 600) / 300, 2)) + 0.5 * exp(-pow((Double(h) * f0 - 1_700) / 400, 2)) + 0.1
            y += 0.04 * formants * gate * sin(Double(h) * phase)
        }
        return y
    }

    /// Sung notes of 1.2 s with vibrato (5.5 Hz, ±1.5 %), 0.1 s apart.
    static func singing(_ t: Double, state: inout Phase) -> Double {
        let notes = [220.0, 262, 294, 330, 294, 262]
        let k = Int(t / 1.3) % notes.count, local = t.truncatingRemainder(dividingBy: 1.3)
        guard local < 1.2 else { return 0 }
        let f0 = notes[k]
        let phase = state.advance(f0 * (1 + 0.015 * sin(2 * .pi * 5.5 * t)))
        let gate = min(1, local / 0.05, (1.2 - local) / 0.05)
        var y = 0.0
        for h in 1...12 {
            let formants = exp(-pow((Double(h) * f0 - 700) / 350, 2)) + 0.4 * exp(-pow((Double(h) * f0 - 2_600) / 500, 2)) + 0.05
            y += 0.05 * formants * gate * sin(Double(h) * phase)
        }
        return y
    }

    /// A whistled tune: notes of 0.4 s between 1.8 and 2.4 kHz with vibrato, in 2.4 s phrases.
    static func whistle(_ t: Double, state: inout Phase) -> Double {
        let notes = [1_800.0, 2_000, 2_250, 2_400, 2_250, 2_000]
        let phraseTime = t.truncatingRemainder(dividingBy: 3.2)
        guard phraseTime < 2.4 else { return 0 }
        let f = notes[Int(phraseTime / 0.4) % notes.count] * (1 + 0.01 * sin(2 * .pi * 6 * t))
        let phase = state.advance(f)
        let gate = min(1, phraseTime / 0.03, (2.4 - phraseTime) / 0.03)
        return 0.03 * gate * sin(phase)
    }

    /// Chirps: 150 ms rising sweeps from 3 to 5.5 kHz, in bursts of five.
    static func birdsong(_ t: Double) -> Double {
        let burst = t.truncatingRemainder(dividingBy: 2.5)
        guard burst < 1.5 else { return 0 }
        let local = burst.truncatingRemainder(dividingBy: 0.3)
        guard local < 0.15 else { return 0 }
        let gate = sin(.pi * local / 0.15)
        // Phase of a linear sweep 3 → 5.5 kHz over 0.15 s.
        let phase = 2 * .pi * (3_000 * local + 0.5 * (2_500 / 0.15) * local * local)
        return 0.02 * gate * sin(phase)
    }

    /// Organ-like chords held for 3 s (tones the attacker model can follow, but no clue).
    static func heldNotes(_ t: Double) -> Double {
        let chords: [[Double]] = [[262, 330, 392], [294, 370, 440], [220, 277, 330]]
        let k = Int(t / 3.2) % chords.count, local = t.truncatingRemainder(dividingBy: 3.2)
        guard local < 3 else { return 0 }
        let gate = min(1, local / 0.05, (3 - local) / 0.05)
        var y = 0.0
        for f in chords[k] { for h in 1...6 { y += 0.012 / Double(h) * gate * sin(2 * .pi * Double(h) * f * t) } }
        return y
    }

    /// Footsteps: a damped 80 Hz thump with a click, every 0.55 s.
    static func footsteps(_ t: Double) -> Double {
        let local = t.truncatingRemainder(dividingBy: 0.55)
        let thump = 0.15 * exp(-local / 0.03) * sin(2 * .pi * 80 * local)
        let click = local < 0.002 ? 0.1 * (1 - local / 0.002) : 0
        return thump + click
    }
}

/// What a scene measures, before → after the default cloak.
struct SceneMetrics: Codable, Equatable {
    /// Attacker's counts [long tones, Doppler tracks, hum lines, fitted flybys].
    var before: [Int]
    var after: [Int]
    /// Similarity of the sound above the cloak's low band (1 = unchanged).
    var kept: Double
    /// Level change per octave (center Hz → dB), where the input has sound.
    var octaves: [String: Double]

    static func counts(_ audio: Audio) -> [Int] {
        let a = FlybyAnalyzer().analyze(audio)
        return [a.tracks.count, a.flybys.count, a.hum.count, a.flybys.filter { $0.fit != nil }.count]
    }

    static func measure(_ input: Audio, _ output: Audio) -> SceneMetrics {
        let x = input.mono, y = output.channels[0], rate = input.sampleRate
        func r2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
        var octaves: [String: Double] = [:]
        for center in [63.0, 125, 250, 500, 1_000, 2_000, 4_000, 8_000] where center * 1.42 < 0.45 * Double(rate) {
            let e0 = Spectra.bandEnergy(x, rate: rate, center / 1.414, center * 1.414)
            let e1 = Spectra.bandEnergy(y, rate: rate, center / 1.414, center * 1.414)
            guard e0 > 1e-9 * Double(x.count) else { continue }        // nothing there to change
            octaves[String(Int(center))] = r2(10 * log10(max(e1, 1e-30) / e0))
        }
        return SceneMetrics(before: counts(input), after: counts(output), kept: r2(Spectra.kept(x, y, rate: rate)), octaves: octaves)
    }
}

enum Spectra {
    /// Energy between `lo` and `hi` Hz (whole-signal FFT).
    static func bandEnergy(_ x: [Double], rate: Int, _ lo: Double, _ hi: Double) -> Double {
        let size = DSP.nextPowerOfTwo(atLeast: max(x.count, 4))
        var re = x + [Double](repeating: 0, count: size - x.count), im = [Double](repeating: 0, count: size)
        FFT(size: size).forward(&re, &im)
        let binHz = Double(rate) / Double(size)
        var e = 0.0
        for k in Int(lo / binHz)...min(Int(hi / binHz), size / 2) { e += re[k] * re[k] + im[k] * im[k] }
        return e
    }

    /// Third-octave band levels (dB) per 64 ms frame from 315 Hz up to 8 kHz (or near Nyquist).
    static func bands(_ x: [Double], rate: Int) -> [[Double]] {
        let n = 2_048, hop = 1_024, window = DSP.hann(n), fft = FFT(size: n), binHz = Double(rate) / Double(n)
        var centers: [Double] = []
        var c = 315.0
        while c * 1.12 < min(8_000, 0.45 * Double(rate)) { centers.append(c); c *= pow(2, 1.0 / 3) }
        var out: [[Double]] = []
        var start = 0
        while start + n <= x.count {
            var re = (0..<n).map { x[start + $0] * window[$0] }, im = [Double](repeating: 0, count: n)
            fft.forward(&re, &im)
            out.append(centers.map { c in
                var e = 1e-12
                for k in max(1, Int(c / 1.12 / binHz))...Int(c * 1.12 / binHz) { e += re[k] * re[k] + im[k] * im[k] }
                return 10 * log10(e)
            })
            start += hop
        }
        return out
    }

    /// Correlation of the third-octave levels above the low band, over cells where the input has
    /// sound (within 50 dB of its loudest cell). 1 for a silent input.
    static func kept(_ x: [Double], _ y: [Double], rate: Int) -> Double {
        let a = bands(x, rate: rate), b = bands(y, rate: rate)
        let top = a.joined().max() ?? -120
        var u: [Double] = [], v: [Double] = []
        for (ra, rb) in zip(a, b) { for (p, q) in zip(ra, rb) where p > top - 50 { u.append(p); v.append(q) } }
        guard u.count > 10, top > -100 else { return 1 }
        let mu = DSP.mean(u), mv = DSP.mean(v)
        var cov = 0.0, su = 0.0, sv = 0.0
        for i in u.indices { cov += (u[i] - mu) * (v[i] - mv); su += pow(u[i] - mu, 2); sv += pow(v[i] - mv, 2) }
        return su > 0 && sv > 0 ? cov / sqrt(su * sv) : 1
    }
}
