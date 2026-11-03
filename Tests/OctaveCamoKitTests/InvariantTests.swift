import Foundation
import XCTest
@testable import OctaveCamoKit

/// Properties every cloak must have, whatever the input: right length, finite, bounded, seeded,
/// and every stage doing its job at every sample rate a browser can hand us.
final class InvariantTests: XCTestCase {
    static let rates = [8_000, 11_025, 16_000, 22_050, 32_000, 44_100, 48_000, 88_200, 96_000, 176_400, 192_000]

    private func seeded(_ steps: Set<ScrubStep> = ScrubPipeline.defaultSteps, seed: UInt64 = 11) -> ScrubPipeline {
        var p = ScrubPipeline()
        p.steps = steps
        p.hum.seed = seed
        p.lowband.seed = seed
        p.wobble.seed = seed
        return p
    }

    /// Noise, a voice-ish harmonic stack and mains hum (both families), per channel.
    private func scene(rate: Int, seconds: Double, channels: Int = 1, mains: [Double] = [60], tone: Bool = true,
                       seed: UInt64 = 5) -> Audio {
        let n = Int(Double(rate) * seconds)
        var rng = SeededRNG(seed: seed)
        var out: [[Double]] = []
        for c in 0..<channels {
            var x = rng.normals(n).map { 0.02 * $0 }
            for i in 0..<n {
                let t = Double(i) / Double(rate)
                for base in mains {
                    var h = base
                    while h < min(400, 0.45 * Double(rate)) {
                        x[i] += 0.02 * sin(2 * .pi * (h * t + 0.01 * sin(2 * .pi * t / 3)) + Double(c))
                        h += base
                    }
                }
                if tone { x[i] += 0.05 * sin(2 * .pi * 220 * t) * (0.5 + 0.5 * sin(2 * .pi * 3 * t)) }
            }
            out.append(x)
        }
        return Audio(sampleRate: rate, channels: out)
    }

    private func assertSound(_ result: ScrubResult, frames: Int, ceiling: Double = 0.99,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(result.audio.channels.count, 1, "output must be mono", file: file, line: line)
        XCTAssertEqual(result.audio.frameCount, frames, "output length must match input", file: file, line: line)
        let y = result.audio.channels[0]
        XCTAssertTrue(y.allSatisfy(\.isFinite), "non-finite sample in output", file: file, line: line)
        XCTAssertLessThanOrEqual(DSP.peakMagnitude(y), ceiling + 1e-12, file: file, line: line)
    }

    /// Mean DFT power within ±0.5 Hz of `f` relative to the mean 3–8 Hz either side (averaging
    /// several bins keeps a single noisy bin from deciding).
    static func lineToNeighboursDB(_ x: [Double], _ f: Double, rate: Int) -> Double {
        func power(_ g: Double) -> Double {
            let w = 2 * Double.pi * g / Double(rate)
            let wr = cos(w), wi = -sin(w)
            var re = 0.0, im = 0.0, cr = 1.0, ci = 0.0
            for v in x {
                re += v * cr; im += v * ci
                (cr, ci) = (cr * wr - ci * wi, cr * wi + ci * wr)
            }
            return re * re + im * im
        }
        let binHz = Double(rate) / Double(max(x.count, 1))
        var line = 0.0, lineCount = 0.0
        for g in stride(from: f - 0.5, through: f + 0.5, by: binHz) { line += power(g); lineCount += 1 }
        var side = 0.0, sideCount = 0.0
        for d in stride(from: 3.0, through: 8.0, by: max(binHz, 0.5)) { side += power(f - d) + power(f + d); sideCount += 2 }
        return 10 * log10((line / lineCount) / max(side / sideCount, 1e-30))
    }

    private func lineToNeighboursDB(_ x: [Double], _ f: Double, rate: Int) -> Double {
        Self.lineToNeighboursDB(x, f, rate: rate)
    }

    /// Energy between `lo` and `hi` Hz (whole-signal FFT).
    private func bandEnergy(_ x: [Double], rate: Int, _ lo: Double, _ hi: Double) -> Double {
        let size = DSP.nextPowerOfTwo(atLeast: x.count)
        var re = x + [Double](repeating: 0, count: size - x.count), im = [Double](repeating: 0, count: size)
        FFT(size: size).forward(&re, &im)
        let binHz = Double(rate) / Double(size)
        var e = 0.0
        for k in Int(lo / binHz)...min(Int(hi / binHz), size / 2) { e += re[k] * re[k] + im[k] * im[k] }
        return e
    }

    /// Syllables of a gliding harmonic voice (f0 ≈ 140 Hz, 0.25 s on, 0.15 s off) over light noise.
    private func voice(rate: Int, seconds: Double) -> [Double] {
        let n = Int(Double(rate) * seconds)
        var rng = SeededRNG(seed: 12)
        var x = rng.normals(n).map { 0.005 * $0 }
        var phase = 0.0
        for i in 0..<n {
            let t = Double(i) / Double(rate)
            let wobble: Double = 0.08 * sin(2 * Double.pi * 0.7 * t) + 0.02 * sin(2 * Double.pi * 5 * t)
            let f0: Double = 140 * (1 + wobble)
            phase += 2 * .pi * f0 / Double(rate)
            let cycle = t.truncatingRemainder(dividingBy: 0.4)
            guard cycle < 0.25 else { continue }
            let gate = sin(.pi * cycle / 0.25)
            for h in 1...20 where Double(h) * f0 < 0.45 * Double(rate) {
                x[i] += 0.1 / Double(h) * gate * sin(Double(h) * phase)
            }
        }
        return x
    }

    // MARK: Shape and range

    func testEverySampleRateAndChannelCountGivesMonoFiniteSameLengthOutput() {
        for rate in Self.rates {
            for channels in [1, 2, 6] {
                let audio = scene(rate: rate, seconds: 2, channels: channels)
                let result = seeded().run(audio)
                assertSound(result, frames: audio.frameCount)
                XCTAssertEqual(result.log.count, ScrubPipeline.defaultSteps.count, "\(rate) Hz × \(channels): \(result.log)")
            }
        }
    }

    func testDegenerateLengthsDoNotCrash() {
        for frames in [0, 1, 2, 7, 255, 1_000, 4_095, 8_193] {
            var rng = SeededRNG(seed: UInt64(frames + 1))
            let audio = Audio(sampleRate: 48_000, channels: [rng.normals(frames).map { 0.1 * $0 }])
            assertSound(seeded().run(audio), frames: frames)
        }
    }

    func testPathologicalSignals() {
        let rate = 48_000, n = rate * 2
        var rng = SeededRNG(seed: 2)
        let cases: [(String, [Double])] = [
            ("silence", [Double](repeating: 0, count: n)),
            ("dc", [Double](repeating: 0.5, count: n)),
            ("full-scale square", (0..<n).map { ($0 / 40) % 2 == 0 ? 1 : -1 }),
            ("clipped noise", rng.normals(n).map { max(-1, min(1, 3 * $0)) }),
            ("impulse", (0..<n).map { $0 == n / 2 ? 1 : 0 }),
            ("nyquist", (0..<n).map { $0 % 2 == 0 ? 0.5 : -0.5 }),
            ("denormal", [Double](repeating: 1e-310, count: n)),
            ("over full scale", rng.normals(n).map { 8 * $0 }),
        ]
        for (name, x) in cases {
            let result = seeded().run(Audio(sampleRate: rate, channels: [x]))
            XCTAssertTrue(result.audio.channels[0].allSatisfy(\.isFinite), name)
            assertSound(result, frames: n)
        }
    }

    func testNonFiniteInputSamplesNeverReachTheOutput() {
        let rate = 48_000, n = rate * 2
        var rng = SeededRNG(seed: 4)
        var x = rng.normals(n).map { 0.1 * $0 }
        x[100] = .nan
        x[n / 2] = .infinity
        x[n - 3] = -.infinity
        let result = seeded().run(Audio(sampleRate: rate, channels: [x, x]))
        assertSound(result, frames: n)
        XCTAssertTrue(result.log.contains { $0.contains("non-finite") }, "the log should say samples were replaced: \(result.log)")
    }

    func testSilenceStaysQuiet() {
        let rate = 48_000
        let result = seeded().run(Audio(sampleRate: rate, channels: [[Double](repeating: 0, count: rate * 2)]))
        XCTAssertLessThan(DSP.peakMagnitude(result.audio.channels[0]), 1e-6, "the cloak invented sound from silence")
    }

    // MARK: Seeding

    func testSameSeedSameOutputDifferentSeedDifferentOutput() {
        let audio = scene(rate: 48_000, seconds: 3, channels: 2)
        let a = seeded(seed: 21).run(audio).audio.channels[0]
        let b = seeded(seed: 21).run(audio).audio.channels[0]
        let c = seeded(seed: 22).run(audio).audio.channels[0]
        XCTAssertEqual(a, b, "same seed must give the same output")
        XCTAssertNotEqual(a, c, "a different seed must give different noise")
    }

    func testUnseededRunsDiffer() {
        let audio = scene(rate: 48_000, seconds: 2)
        XCTAssertNotEqual(ScrubPipeline().run(audio).audio.channels[0], ScrubPipeline().run(audio).audio.channels[0],
                          "default seeds must be random, or every user's noise would be identical")
    }

    func testMonoIgnoresChannelOrder() {
        let audio = scene(rate: 48_000, seconds: 2, channels: 3)
        let swapped = Audio(sampleRate: 48_000, channels: audio.channels.reversed())
        let a = seeded().run(audio).audio.channels[0], b = seeded().run(swapped).audio.channels[0]
        let maxError = zip(a, b).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThan(maxError, 1e-9, "the output reveals channel order")
    }

    // MARK: Each stage works at every rate

    /// Every harmonic of either grid, at every rate, is knocked down by at least 25 dB or to within
    /// 4 dB of its neighbours, right to the clip's edges. (A notch removes a steady line outright;
    /// the hum here wanders a little, as grids do, and the part that wanders off the notch's centre
    /// is attenuated rather than removed. Below 300 Hz `lowband` regenerates the band anyway.)
    func testHumIsRemovedAtEverySampleRate() {
        for rate in Self.rates {
            for base in [50.0, 60.0] {
                let audio = scene(rate: rate, seconds: 6, mains: [base], tone: false)
                let result = seeded([.mono, .hum]).run(audio)
                let y = result.audio.channels[0]
                var h = base
                while h < min(400, 0.45 * Double(rate)) {
                    let before = lineToNeighboursDB(audio.channels[0], h, rate: rate)
                    let after = lineToNeighboursDB(y, h, rate: rate)
                    XCTAssertGreaterThan(before, 15, "test scene lacks a \(h) Hz line at \(rate) Hz")
                    XCTAssertTrue(after < 4 || before - after > 25,
                                  "\(h) Hz hum survived at \(rate) Hz: \(before) → \(after) dB; \(result.log)")
                    h += base
                }
            }
        }
    }

    /// The edges specifically: the first and last half second carry no more hum than the middle.
    func testHumIsGoneAtTheClipEdges() {
        let rate = 16_000, n = rate * 8
        var x = [Double](repeating: 0, count: n)
        for i in 0..<n { x[i] = 0.1 * sin(2 * .pi * 60 * Double(i) / Double(rate)) }
        var stage = HumNotch()
        stage.refill = false
        let y = stage.process(x, sampleRate: rate).output
        let edge = (y[0..<(rate / 2)] + y[(n - rate / 2)...]).map(abs).max() ?? 0
        XCTAssertLessThan(edge, 0.001, "a 60 Hz line survives at the clip's edges")
    }

    func testLowbandRemovesASteadyLowToneAtEverySampleRate() {
        for rate in Self.rates {
            let n = rate * 6
            var rng = SeededRNG(seed: 8)
            var x = rng.normals(n).map { 0.02 * $0 }
            for i in 0..<n { x[i] += 0.05 * sin(2 * .pi * 137.3 * Double(i) / Double(rate)) }
            let result = seeded([.mono, .lowband]).run(Audio(sampleRate: rate, channels: [x]))
            let y = result.audio.channels[0]
            XCTAssertGreaterThan(lineToNeighboursDB(x, 137.3, rate: rate), 20)
            XCTAssertLessThan(lineToNeighboursDB(y, 137.3, rate: rate), 6, "137 Hz tone survived lowband at \(rate) Hz; \(result.log)")
        }
    }

    func testCloakKeepsTheVoiceAboveTheLowBand() {
        for rate in [16_000, 48_000] {
            let x = voice(rate: rate, seconds: 6)
            let y = seeded().run(Audio(sampleRate: rate, channels: [x])).audio.channels[0]
            for (lo, hi) in [(500.0, 1_000.0), (1_000.0, 3_000.0)] {
                let change = 10 * log10(bandEnergy(y, rate: rate, lo, hi) / bandEnergy(x, rate: rate, lo, hi))
                XCTAssertLessThan(abs(change), 2, "\(Int(lo))–\(Int(hi)) Hz changed by \(change) dB at \(rate) Hz")
            }
        }
    }

    func testCloakDoesNotShiftTheSoundInTime() {
        let rate = 48_000
        let x = voice(rate: rate, seconds: 4)
        let y = seeded().run(Audio(sampleRate: rate, channels: [x])).audio.channels[0]
        var best = (lag: 0, value: -Double.infinity)
        for lag in -48...48 {
            var c = 0.0
            for i in 1_000..<(x.count - 1_000) { c += x[i] * y[i + lag] }
            if c > best.value { best = (lag, c) }
        }
        XCTAssertEqual(best.lag, 0, "the output is \(best.lag) samples out of sync with the input")
    }

    func testLowbandDoesNotKeepAPassingEngineAsVoice() {
        // A lone engine tone gliding through the low band, as a plane passes: periodic, so the
        // voice tracker sees it, but it must not be kept.
        let rate = 48_000, seconds = 24.0
        let pass = FlybyGeometry(f0: 150, speed: 80, t0: 12, distance: 600)
        let t = (0..<Int(Double(rate) * seconds)).map { Double($0) / Double(rate) }
        let f = pass.received(at: t).frequency
        var rng = SeededRNG(seed: 3)
        var x = rng.normals(t.count).map { 0.01 * $0 }
        var phase = 0.0
        for i in x.indices { phase += 2 * .pi * f[i] / Double(rate); x[i] += 0.05 * sin(phase) }
        let before = FlybyAnalyzer().analyze(Audio(sampleRate: rate, channels: [x]))
        XCTAssertNotNil(before.consensus, "test clip: the pass should be recoverable before the cloak")
        for steps: Set<ScrubStep> in [[.mono, .lowband], [.mono, .hum, .lowband]] {
            let y = seeded(steps).run(Audio(sampleRate: rate, channels: [x])).audio.channels[0]
            let after = FlybyAnalyzer().analyze(Audio(sampleRate: rate, channels: [y]))
            XCTAssertNil(after.consensus, "\(steps.map(\.rawValue).sorted()): pass still recoverable")
            XCTAssertTrue(after.flybys.isEmpty, "\(steps.map(\.rawValue).sorted()): \(after.flybys.count) Doppler tracks left")
        }
    }

    func testOutOfRangeSettingsNeverTrap() {
        let audio = scene(rate: 8_000, seconds: 2)
        for cutoff in [6_000.0, 10, 0.5, 1e20, .infinity, .nan] {
            var p = seeded()
            p.lowband.cutoff = cutoff
            assertSound(p.run(audio), frames: audio.frameCount)
        }
        var p = seeded()
        p.hum.mains = [0.01, -60, .infinity]
        p.scurve.f0Max = 10
        assertSound(p.run(audio), frames: audio.frameCount)
    }

    func testOneAbsurdSampleDoesNotSilenceTheClip() {
        let audio = scene(rate: 48_000, seconds: 2)
        var x = audio.channels[0]
        x[5_000] = 1e10
        let result = seeded().run(Audio(sampleRate: 48_000, channels: [x]))
        assertSound(result, frames: x.count)
        let rms = (result.audio.channels[0].reduce(0) { $0 + $1 * $1 } / Double(x.count)).squareRoot()
        XCTAssertGreaterThan(rms, 0.01, "the output was scaled to nothing")
        XCTAssertTrue(result.log.contains { $0.contains("out-of-range") }, "\(result.log)")
    }

    func testEverySeededStageUsesTheSeed() {
        let audio = scene(rate: 48_000, seconds: 3)
        for steps: Set<ScrubStep> in [[.mono, .hum], [.mono, .lowband], [.mono, .wobble]] {
            let a = seeded(steps, seed: 1).run(audio).audio.channels[0]
            let b = seeded(steps, seed: 2).run(audio).audio.channels[0]
            XCTAssertNotEqual(a, b, "\(steps.map(\.rawValue).sorted()) ignores its seed")
            XCTAssertEqual(a, seeded(steps, seed: 1).run(audio).audio.channels[0])
        }
    }

    func testDefaultChainRemovesAFlybyAtOtherSampleRates() {
        for rate in [22_050, 96_000] {
            var synth = FlybySynth()
            synth.duration = 30
            synth.flyby.t0 = 15
            synth.sampleRate = rate
            let audio = synth.render()
            XCTAssertNotNil(FlybyAnalyzer().analyze(audio).consensus, "test clip at \(rate) Hz")
            let y = seeded().run(audio).audio
            XCTAssertNil(FlybyAnalyzer().analyze(y).consensus, "flyby still recoverable at \(rate) Hz")
        }
    }

    /// Per-stage cost and how it scales with length (printed for CI logs: "perf-stage" lines).
    func testPerStageTimingsScale() {
        for seconds in [60.0, 120.0] {
            let audio = scene(rate: 48_000, seconds: seconds)
            var line = "perf-stage: \(Int(seconds)) s mono 48 kHz:"
            for step in [ScrubStep.hum, .subtract, .scurve, .lowband] {
                let start = Date()
                _ = seeded([step]).run(audio)
                line += " \(step.rawValue) \(String(format: "%.1f", Date().timeIntervalSince(start))) s"
            }
            print(line)
        }
    }

    /// Not a benchmark, a tripwire: a minute of audio must cloak in a sane time (printed for CI logs).
    func testOneMinuteCloaksInReasonableTime() {
        let audio = scene(rate: 48_000, seconds: 60, channels: 2)
        let start = Date()
        _ = seeded().run(audio)
        let seconds = Date().timeIntervalSince(start)
        print("perf: default chain on 60 s of 48 kHz stereo took \(String(format: "%.1f", seconds)) s")
        XCTAssertLessThan(seconds, 120)
    }

    func testEveryStepCombinationIsSound() {
        let audio = scene(rate: 22_050, seconds: 2, channels: 2)
        let all = ScrubStep.allCases
        for mask in 0..<(1 << all.count) {
            let steps = Set(all.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element))
            assertSound(seeded(steps).run(audio), frames: audio.frameCount)
        }
    }

    // MARK: Flicker

    private func flickerProfiles(frames K: Int, strips S: Int = 6, rows R: Int = 120, fill: (Int, Int, Int) -> Double) -> FlickerScan.Profiles {
        var values = [Double](repeating: 0, count: K * S * R)
        for k in 0..<K { for s in 0..<S { for r in 0..<R { values[(k * S + s) * R + r] = fill(k, s, r) } } }
        return FlickerScan.Profiles(frames: K, strips: S, rows: R, values: values, times: (0..<K).map { Double($0) / 30 })
    }

    /// Log-brightness of a 100 Hz rolling band (readout half a frame) at 30 fps.
    private static func band(_ k: Int, _ r: Int) -> Double {
        let t: Double = Double(k) / 30 + 0.5 / 30 * Double(r) / 120
        return -0.5 + 0.04 * cos(2 * Double.pi * 100 * t)
    }

    func testFlickerGainsAreFiniteBoundedAndShaped() {
        var rng = SeededRNG(seed: 6)
        let cases: [(String, FlickerScan.Profiles)] = [
            ("flat", flickerProfiles(frames: 300) { _, _, _ in -1 }),
            ("noise", flickerProfiles(frames: 300) { _, _, _ in rng.normal() }),
            ("banded", flickerProfiles(frames: 600) { k, _, r in Self.band(k, r) }),
            ("short", flickerProfiles(frames: 8, strips: 1, rows: 8) { _, _, r in Double(r) }),
        ]
        let scan = FlickerScan()
        for (name, p) in cases {
            let cleaned = scan.clean(p)
            XCTAssertEqual(cleaned.gains.count, p.frames * p.rows, name)
            XCTAssertTrue(cleaned.gains.allSatisfy { $0.isFinite && $0 > 0 }, name)
            // Gains are applied to linear brightness: never more than the depth cap per pass.
            let bound = exp(scan.maxDepth * Double(scan.passes)) + 1e-9
            XCTAssertTrue(cleaned.gains.allSatisfy { $0 <= bound && $0 >= 1 / bound }, "\(name): gain outside the depth cap")
            XCTAssertTrue(cleaned.after.z.isFinite && cleaned.findings.allSatisfy { $0.z.isFinite }, name)
        }
    }

    func testFlickerFlatOrNoisePicturesAreNotFlagged() {
        var rng = SeededRNG(seed: 9)
        XCTAssertFalse(FlickerScan().scan(flickerProfiles(frames: 300) { _, _, _ in -1 }).detected)
        XCTAssertFalse(FlickerScan().scan(flickerProfiles(frames: 600) { _, _, _ in 0.01 * rng.normal() }).detected)
    }

    func testFlickerSaysWhenItCouldNotLook() {
        // Fewer frames than one 4 s segment.
        let short = FlickerScan().scan(flickerProfiles(frames: 90) { k, _, r in Self.band(k, r) })
        XCTAssertFalse(short.checked)
        XCTAssertFalse(short.detected)
        // 240 fps: a 100/120 Hz band would be under half a cycle per frame.
        var values = [Double](repeating: -0.5, count: 2_400 * 6 * 120)
        for k in 0..<2_400 {
            for s in 0..<6 {
                for r in 0..<120 {
                    let t: Double = Double(k) / 240 + 0.5 / 240 * Double(r) / 120
                    values[(k * 6 + s) * 120 + r] += 0.04 * cos(2 * Double.pi * 120 * t)
                }
            }
        }
        let fast = FlickerScan().scan(FlickerScan.Profiles(frames: 2_400, strips: 6, rows: 120, values: values,
                                                           times: (0..<2_400).map { Double($0) / 240 }))
        XCTAssertTrue(fast.detected || !fast.checked, "high frame rate read as clean")
        XCTAssertTrue(fast.z.isFinite)
    }

    func testFlickerNoDetectionMeansUnitGains() {
        let cleaned = FlickerScan().clean(flickerProfiles(frames: 300) { _, s, r in -1 + 0.01 * Double(s + r) })
        XCTAssertTrue(cleaned.gains.allSatisfy { $0 == 1 }, "nothing found, so nothing may change")
    }

    func testFlickerSurvivesNonFiniteProfiles() {
        var p = flickerProfiles(frames: 300) { k, _, r in -0.5 + 0.03 * cos(2 * .pi * (100 * Double(k) / 30 + Double(r) / 240)) }
        p.values[17] = .nan
        p.values[400] = -.infinity
        let cleaned = FlickerScan().clean(p)
        XCTAssertTrue(cleaned.gains.allSatisfy(\.isFinite))
        XCTAssertTrue(cleaned.after.z.isFinite)
    }
}
