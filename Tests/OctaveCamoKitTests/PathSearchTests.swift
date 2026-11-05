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

    func testHarmlessScenesGiveNoPasses() {
        for name in Scenes.harmless + ["held-notes", "tone-1200", "tone-4500", "hum-50-harmonics"] {
            let audio = Scenes.make(name)
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
        XCTAssertTrue(passes(after).isEmpty || doppler(after).isEmpty)
    }
}
