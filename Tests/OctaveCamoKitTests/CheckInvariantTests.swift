import Foundation
import XCTest
@testable import OctaveCamoKit

/// Properties of the check itself (FlybyAnalyzer: the frame tracker plus the line integrator), for
/// any input: what it reports is well-formed and deterministic, a line is found where and when it
/// is, and finding it doesn't depend on things that shouldn't matter (time direction, a delay, the
/// sample rate, an unrelated sound elsewhere), while a stronger tone is never harder to find.
final class CheckInvariantTests: XCTestCase {
    private let check = FlybyAnalyzer()

    /// The line nearest `hz`, if one covers it (within max(2 Hz, 0.2 %)).
    private func line(near hz: Double, in a: Analysis) -> TrackReport? {
        let margin = max(2, 0.002 * hz)
        return a.tracks.filter { $0.minFrequency - margin <= hz && hz <= $0.maxFrequency + margin }
            .min { abs($0.meanFrequency - hz) < abs($1.meanFrequency - hz) }
    }

    private func audio(_ x: [Double], _ rate: Int) -> Audio { Audio(sampleRate: rate, channels: [x]) }

    // MARK: Well-formed

    /// Every report is finite, inside the clip and the search range, ordered sensibly, and the
    /// counts nest (fitted flybys ⊆ Doppler tracks ⊆ long tones; hum ⊆ long tones).
    func testReportsAreWellFormed() {
        for rate in [16_000, 48_000] {
            for name in Scenes.names {
                let input = Scenes.make(name, rate: rate), a = check.analyze(input)
                for t in a.tracks {
                    let numbers = [t.start, t.duration, t.meanFrequency, t.minFrequency, t.maxFrequency]
                    XCTAssertTrue(numbers.allSatisfy(\.isFinite), "\(name) @\(rate): \(numbers)")
                    XCTAssertGreaterThanOrEqual(t.start, -0.01, "\(name) @\(rate)")
                    XCTAssertGreaterThanOrEqual(t.duration, 0, "\(name) @\(rate)")
                    XCTAssertLessThanOrEqual(t.start + t.duration, input.duration + 1.5, "\(name) @\(rate): ends after the clip")
                    XCTAssertLessThanOrEqual(t.minFrequency, t.meanFrequency + 1e-9, "\(name) @\(rate)")
                    XCTAssertLessThanOrEqual(t.meanFrequency, t.maxFrequency + 1e-9, "\(name) @\(rate)")
                    XCTAssertGreaterThanOrEqual(t.minFrequency, 30, "\(name) @\(rate): below the search range")
                    XCTAssertLessThanOrEqual(t.maxFrequency, min(8_100, 0.5 * Double(rate)), "\(name) @\(rate): above the search range")
                }
                XCTAssertLessThanOrEqual(a.flybys.filter { $0.fit != nil }.count, a.flybys.count)
                XCTAssertLessThanOrEqual(a.flybys.count + a.hum.count, a.tracks.count, name)
                // Longest first, as the page and the counts expect.
                XCTAssertEqual(a.tracks.map(\.duration), a.tracks.map(\.duration).sorted(by: >), name)
            }
        }
    }

    func testTheSameInputGivesTheSameReport() {
        let input = Scenes.make("plane-hard", rate: 32_000)
        let describe = { (a: Analysis) in a.tracks.map { "\($0.kind) \($0.start) \($0.duration) \($0.meanFrequency)" } }
        XCTAssertEqual(describe(check.analyze(input)), describe(check.analyze(input)))
    }

    // MARK: Where and when

    /// Delaying the sound by 5 s (with more of the same noise in front) delays the line by 5 s and
    /// leaves its frequency alone.
    func testADelayMovesTheLineInTimeOnly() {
        let rate = 16_000
        let tone = DetectionScenes.steady(hz: 1_200, snr: 12, rate: rate, seed: 7).channels[0]
        let delayed = DetectionScenes.white(rate * 5, seed: 70) + tone
        guard let a = line(near: 1_200, in: check.analyze(audio(tone, rate))),
              let b = line(near: 1_200, in: check.analyze(audio(delayed, rate))) else { return XCTFail("tone not found") }
        XCTAssertEqual(b.meanFrequency, a.meanFrequency, accuracy: 0.5)
        XCTAssertEqual(b.start - a.start, 5, accuracy: 1.1)
    }

    /// A steady line is the same line played backwards; a grid family too.
    func testTimeDirectionDoesNotMatter() {
        let rate = 16_000
        for x in [DetectionScenes.steady(hz: 700, snr: 10, rate: rate, seed: 8).channels[0],
                  DetectionScenes.steady(hz: 3_300, snr: 12, rate: rate, seed: 9).channels[0]] {
            let forward = check.analyze(audio(x, rate)), backward = check.analyze(audio(Array(x.reversed()), rate))
            guard let f = forward.tracks.first, let b = line(near: f.meanFrequency, in: backward) else { return XCTFail("not found both ways") }
            XCTAssertEqual(b.meanFrequency, f.meanFrequency, accuracy: 1)
        }
        let grid = DetectionScenes.gridFamily(snr: 8, rate: rate, seed: 3).channels[0]
        let hum = check.analyze(audio(grid, rate)).hum.count, humBackward = check.analyze(audio(Array(grid.reversed()), rate)).hum.count
        XCTAssertEqual(Double(humBackward), Double(hum), accuracy: max(1, 0.15 * Double(hum)), "grid family: \(hum) forward, \(humBackward) backward")
    }

    /// The same tone is found at the same frequency (within a bin) at every common rate.
    func testTheSampleRateDoesNotMoveALine() {
        for rate in [16_000, 32_000, 44_100, 48_000] {
            let a = check.analyze(DetectionScenes.steady(hz: 1_200, snr: 12, rate: rate, seed: 4))
            guard let l = line(near: 1_200, in: a) else { XCTFail("\(rate) Hz: not found"); continue }
            XCTAssertEqual(l.meanFrequency, 1_200, accuracy: 1.5, "\(rate) Hz")
        }
    }

    // MARK: Strength and company

    /// Detection is monotone in strength: a tone found at some level is found at every higher one.
    func testAStrongerToneIsNeverHarderToFind() {
        for rate in [16_000, 48_000] {
            for seed: UInt64 in [1, 2, 3] {
                let found = [6.0, 9, 12, 15, 20].map { snr in
                    line(near: 1_200, in: check.analyze(DetectionScenes.steady(hz: 1_200, snr: snr, rate: rate, seed: seed))) != nil
                }
                if let first = found.firstIndex(of: true) {
                    XCTAssertFalse(found[first...].contains(false), "\(rate) Hz seed \(seed): found at 6/9/12/15/20 dB = \(found)")
                }
                XCTAssertTrue(found.last!, "\(rate) Hz seed \(seed): a 20 dB tone")
            }
        }
    }

    /// An unrelated sound elsewhere (a loud tone at 3 kHz, a burst at 500 Hz) doesn't hide a line.
    func testAnotherSoundElsewhereDoesNotHideALine() {
        let rate = 16_000
        var x = DetectionScenes.steady(hz: 1_200, snr: 12, rate: rate, seed: 5).channels[0]
        let loud = DetectionScenes.amplitude(snr: 30, rate: rate)
        for i in x.indices {
            let t = Double(i) / Double(rate)
            x[i] += loud * sin(2 * .pi * 3_000 * t)
            if t > 8 && t < 8.3 { x[i] += 10 * loud * sin(2 * .pi * 500 * t) }
        }
        let a = check.analyze(audio(x, rate))
        XCTAssertNotNil(line(near: 1_200, in: a), "the 1.2 kHz line: \(a.tracks.map(\.meanFrequency))")
        XCTAssertNotNil(line(near: 3_000, in: a), "the 3 kHz tone")
    }
}
