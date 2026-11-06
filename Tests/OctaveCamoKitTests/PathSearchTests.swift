import XCTest
@testable import OctaveCamoKit

/// The check's path search: finds the fast fan-tone sweeps the frame tracker smears, and only those.
final class PathSearchTests: XCTestCase {
    let check = FlybyAnalyzer()

    private func passes(_ audio: Audio) -> [Track] {
        PathSearch().tracks(in: audio.mono, sampleRate: audio.sampleRate)
    }

    private func doppler(_ audio: Audio) -> [TrackReport] {
        check.analyze(audio).tracks.filter { $0.kind == .doppler }
    }

    func testFindsAFanToneTheTrackerMisses() {
        for rate in [16_000, 48_000] {
            let audio = LineFillTests.fanTone(rate: rate, snr: 20)
            var trackerOnly = check
            trackerOnly.paths = nil
            XCTAssertFalse(trackerOnly.analyze(audio).tracks.contains { $0.kind == .doppler && $0.maxFrequency > 1_100 },
                           "the frame tracker alone already sees it at \(rate) Hz: this test lost its point")
            let found = doppler(audio).filter { $0.maxFrequency > 1_100 && $0.minFrequency < 1_700 }
            XCTAssertEqual(found.count, 1, "rate \(rate): \(check.analyze(audio).tracks)")
            if let fit = found.first?.fit {
                XCTAssertEqual(fit.geometry.f0, 1_234, accuracy: 25, "rate \(rate)")
                XCTAssertEqual(fit.geometry.speed, 141, accuracy: 40, "rate \(rate)")
            }
        }
    }

    /// The white-noise null is cached across searches; searching from several threads at once
    /// (a library caller could) must give each the same passes as searching alone.
    func testSearchesFromSeveralThreadsAgree() {
        let audio = LineFillTests.fanTone(rate: 16_000, snr: 20)
        let alone = passes(audio).map(\.frequencies)
        let results = Locked<[[[Double]]]>([])
        DispatchQueue.concurrentPerform(iterations: 6) { _ in
            let found = PathSearch().tracks(in: audio.mono, sampleRate: audio.sampleRate).map(\.frequencies)
            results.withLock { $0.append(found) }
        }
        XCTAssertFalse(alone.isEmpty)
        XCTAssertEqual(results.withLock { $0 }, Array(repeating: alone, count: 6))
    }

    func testHarmlessScenesGiveNoPasses() {
        // The scenes are 10–15 s; a pass needs 12 s and a span 10 s, so each runs four times over
        // (else the search would barely get a chance to be wrong).
        for name in Scenes.harmless + ["held-notes", "tone-1200", "tone-4500", "hum-50-harmonics"] {
            let one = Scenes.make(name)
            let audio = Audio(sampleRate: one.sampleRate, channels: [Array([one.mono, one.mono, one.mono, one.mono].joined())])
            XCTAssertTrue(passes(audio).allSatisfy { check.classify($0).kind != .doppler }, name)
            XCTAssertTrue(doppler(audio).isEmpty, "\(name): \(check.analyze(audio).tracks)")
        }
        for kind in ["white", "pink"] {
            let audio = DetectionScenes.noise(kind, rate: 32_000, seed: 5)
            XCTAssertTrue(passes(audio).isEmpty, "\(kind) noise")
        }
    }

    /// Falling sweeps that aren't flybys: the search may find them, the shape test must drop them.
    func testFallingNotesAndSirensAreNotFlybys() {
        let rate = 32_000, n = rate * 40
        var x = DetectionScenes.white(n, seed: 9), phase = 0.0
        let a = DetectionScenes.amplitude(snr: 30, rate: rate)
        for i in 0..<n {
            let t = Double(i) / Double(rate)
            // A descending scale (a step every 0.5 s) for 20 s, then a siren wail.
            let f = t < 20 ? 1_800 * pow(2, -floor(t / 0.5) / 24) : 1_200 + 400 * sin(2 * .pi * t / 4)
            phase += 2 * .pi * f / Double(rate)
            x[i] += a * sin(phase)
        }
        let audio = Audio(sampleRate: rate, channels: [x])
        XCTAssertFalse(passes(audio).isEmpty, "the search should find these sweeps, or the shape test is never exercised")
        XCTAssertTrue(doppler(audio).isEmpty, "\(check.analyze(audio).tracks)")
    }

    /// A pass lasts longer than one span: every false pass on the recorder sessions fit in one 10 s
    /// span, a real pass bends over 20–30 s. The same fan tone heard for only 8 s isn't reported.
    func testAPassNeedsMoreThanOneSpan() {
        let full = LineFillTests.fanTone(rate: 16_000, snr: 30)
        let rate = full.sampleRate, x = full.mono, noise = DetectionScenes.white(x.count, seed: 33)
        let on = Double(rate) * 20 ..< Double(rate) * 28
        let gated = x.indices.map { on.contains(Double($0)) ? x[$0] : noise[$0] }
        XCTAssertEqual(passes(full).count, 1)
        XCTAssertTrue(passes(Audio(sampleRate: rate, channels: [gated])).isEmpty)
    }

    func testDeterministic() {
        let audio = LineFillTests.fanTone(rate: 16_000, snr: 20)
        let a = passes(audio), b = passes(audio)
        XCTAssertEqual(a.map(\.frequencies), b.map(\.frequencies))
        XCTAssertEqual(a.map(\.times), b.map(\.times))
    }

    func testShortClipsAreSkipped() {
        let audio = Audio(sampleRate: 16_000, channels: [DetectionScenes.white(16_000 * 5, seed: 1)])
        XCTAssertTrue(passes(audio).isEmpty)
    }

    /// The fill stage removes what the search finds: after `lines`, the pass is gone.
    func testLineFillRemovesTheFoundPass() {
        let audio = LineFillTests.fanTone(rate: 16_000, snr: 20)
        var stage = LineFill()
        stage.seed = 1
        let r = stage.process(audio.mono, sampleRate: audio.sampleRate)
        let after = Audio(sampleRate: audio.sampleRate, channels: [r.output])
        XCTAssertTrue(doppler(after).filter { $0.maxFrequency > 1_100 }.isEmpty, "\(check.analyze(after).tracks)")
        XCTAssertFalse(passes(after).contains { $0.maxFrequency > 1_100 && check.classify($0).kind == .doppler })
    }

    // MARK: Invariants

    /// Level-blind: each bin is compared with its own running median, so boosting the audio (or
    /// turning it down) changes nothing. Boosting can't help a detector like this one, and
    /// attenuating can't hide from it.
    func testGainChangesNothing() {
        let x = LineFillTests.fanTone(rate: 16_000, snr: 20).mono
        let base = PathSearch().tracks(in: x, sampleRate: 16_000)
        XCTAssertEqual(base.count, 1)
        for gain in [0.01, 100.0] {
            let other = PathSearch().tracks(in: x.map { $0 * gain }, sampleRate: 16_000)
            XCTAssertEqual(other.map(\.frequencies), base.map(\.frequencies), "gain \(gain)")
            XCTAssertEqual(other.map(\.times), base.map(\.times), "gain \(gain)")
        }
    }

    /// Starting the clip later moves the pass by the same time, and nowhere in frequency.
    func testDelayMovesThePassInTimeOnly() {
        let x = LineFillTests.fanTone(rate: 16_000, snr: 20).mono
        let pad = DetectionScenes.white(16_000 * 5, seed: 77)
        guard let a = PathSearch().tracks(in: x, sampleRate: 16_000).first,
              let b = PathSearch().tracks(in: pad + x, sampleRate: 16_000).first else { return XCTFail("pass not found") }
        XCTAssertEqual(b.times.first! - a.times.first!, 5, accuracy: 1.5)
        XCTAssertEqual(b.minFrequency, a.minFrequency, accuracy: 0.02 * a.minFrequency)
        XCTAssertEqual(b.maxFrequency, a.maxFrequency, accuracy: 0.02 * a.maxFrequency)
    }

    /// A pass played backwards rises: a straight flyby is never heard rising, so it isn't a pass.
    func testARisingSweepIsNotAPass() {
        let x = LineFillTests.fanTone(rate: 16_000, snr: 25).mono
        XCTAssertTrue(PathSearch().tracks(in: x.reversed(), sampleRate: 16_000).isEmpty)
    }

    /// Noise fill along a curve sits at its surroundings' level. A matched filter integrating
    /// along the exact curve sees ~0.1 dB, so a biased strip is itself a trace; today the bias is
    /// about ±0.3 dB (docs/EXPERIMENTS.md, track-driven removal), and this guards against it growing.
    func testTheFillSitsNearTheBackgroundLevel() {
        for sr in [16_000, 48_000] {
            let x = DetectionScenes.white(sr * 60, seed: 3)
            let geom = FlybyGeometry(f0: 700, speed: 133, t0: 30, distance: 3_900)
            let t = Array(stride(from: 5.0, through: 55, by: 0.05))
            let line = Track(times: t, frequencies: geom.received(at: t).frequency, levels: t.map { _ in 0 })
            var y = x, rng = SeededRNG(seed: 1), fill = LineFill()
            fill.marginHz = 8
            XCTAssertTrue(fill.fill(&y, line, sampleRate: sr, rng: &rng))
            // Power along the curve (±2 bins), before and after, from 12 to 48 s.
            let n = LineFill.fftSize(sampleRate: sr), w = DSP.hann(n), fft = RealFFT(size: n)
            var re = [Double](repeating: 0, count: n / 2 + 1), im = re, before = 0.0, after = 0.0
            for start in stride(from: sr * 12, to: sr * 48 - n, by: n / 4) {
                let tc = (Double(start) + Double(n) / 2) / Double(sr)
                let k = Int((geom.received(at: [tc]).frequency[0] * Double(n) / Double(sr)).rounded())
                fft.forward((0..<n).map { x[start + $0] * w[$0] }, &re, &im)
                for kk in (k - 2)...(k + 2) { before += re[kk] * re[kk] + im[kk] * im[kk] }
                fft.forward((0..<n).map { y[start + $0] * w[$0] }, &re, &im)
                for kk in (k - 2)...(k + 2) { after += re[kk] * re[kk] + im[kk] * im[kk] }
            }
            XCTAssertEqual(10 * log10(after / before), 0, accuracy: 0.5, "rate \(sr)")
        }
    }
}
