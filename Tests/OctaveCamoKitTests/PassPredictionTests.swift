import Foundation
import XCTest
@testable import OctaveCamoKit

/// Curves predicted from adsb.lol's half-hour archive: decoding it, and predicting each nearby
/// aircraft's Doppler curve well enough that removal driven by it beats an attacker who holds the
/// exact track.
final class PassPredictionTests: XCTestCase {
    /// A made-up place and time (nobody's location): the audio starts at 2026-11-05 08:38:25 UTC.
    static let lat = 40.0, lon = -100.0, start = 1_793_867_905.0

    // MARK: An archive file, written the way adsb.lol writes it

    struct Writer {
        var words: [Int32] = []
        mutating func block(_ unix: Double) {
            let ms = Int64((unix * 1_000).rounded())
            words += [FlightArchive.marker, Int32(truncatingIfNeeded: ms >> 32), Int32(truncatingIfNeeded: ms), 0]
        }
        mutating func aircraft(_ id: Int32, lat: Double, lon: Double, feet: Double?, knots: Double) {
            let alt = feet.map { Int16(($0 / 25).rounded()) } ?? FlightArchive.groundAltitude
            let packed = Int32(bitPattern: UInt32(UInt16(bitPattern: alt)) | UInt32(UInt16((knots * 10).rounded())) << 16)
            words += [id, Int32((lat * 1e6).rounded()), Int32((lon * 1e6).rounded()), packed]
        }
        var bytes: [UInt8] { words.flatMap { w in (0..<4).map { UInt8(truncatingIfNeeded: UInt32(bitPattern: w) >> (8 * $0)) } } }
    }

    /// Metres east/north of the test place as latitude and longitude.
    static func place(east: Double, north: Double) -> (Double, Double) {
        let R = FlightArchive.earthRadius
        return (lat + north / R * 180 / .pi, lon + east / (R * cos(lat * .pi / 180)) * 180 / .pi)
    }

    func testDecodesPositionsAndSkipsWhatIsntOne() {
        var w = Writer()
        let (la, lo) = Self.place(east: 1_000, north: 2_000)
        w.block(Self.start)
        w.aircraft(0xABC123, lat: la, lon: lo, feet: 4_500, knots: 250.5)
        w.aircraft(0x00A0FF, lat: la, lon: lo, feet: nil, knots: 12)                  // on the ground
        w.aircraft(0xABC124, lat: Self.lat + 1, lon: Self.lon, feet: 4_500, knots: 250) // 111 km away
        w.aircraft(1 << 24 | 0x123, lat: la, lon: lo, feet: 4_500, knots: 250)          // flagged address
        w.words += [0x4141_4141, 0x4242_4242, 0x4343_4343, 0x4444_4444]                // a callsign record
        w.block(Self.start + 10)
        w.aircraft(0xABC123, lat: la, lon: lo, feet: 4_600, knots: 0)
        w.block(Self.start + 10_000)                                                    // outside the window
        w.aircraft(0xABC123, lat: la, lon: lo, feet: 4_700, knots: 250)
        let p = FlightArchive.positions(w.bytes, near: Self.lat, Self.lon, radiusKm: 40, from: Self.start - 1, to: Self.start + 100)
        XCTAssertEqual(Array(p.keys), ["abc123"])
        let a = p["abc123"]!
        XCTAssertEqual(a.map(\.time), [Self.start, Self.start + 10])
        XCTAssertEqual(a[0].altitudeFeet, 4_500)
        XCTAssertEqual(a[0].groundSpeedKnots!, 250.5, accuracy: 1e-9)
        XCTAssertNil(a[1].groundSpeedKnots, "0 kt means not reported")
        XCTAssertEqual(a[0].latitude, la, accuracy: 1e-6)
        // A truncated file (not a whole record) decodes what's whole.
        XCTAssertEqual(FlightArchive.positions(Array(w.bytes.dropLast(3)), near: Self.lat, Self.lon, radiusKm: 40,
                                               from: Self.start - 1, to: Self.start + 100)["abc123"]?.count, 2)
        XCTAssertTrue(FlightArchive.positions([], near: 0, 0, radiusKm: 40, from: 0, to: 1).isEmpty)
    }

    func testNamesTheFileForAMoment() {
        XCTAssertEqual(FlightArchive.file(for: Self.start).path, "globe_history/2026/11/05/heatmap/17.bin.ttf")
        XCTAssertEqual(FlightArchive.file(for: 951_868_799).path, "globe_history/2000/02/29/heatmap/47.bin.ttf")
        XCTAssertEqual(FlightArchive.file(for: 1_799).path, "globe_history/1970/01/01/heatmap/00.bin.ttf")
        XCTAssertEqual(FlightArchive.file(for: 1_798_718_400).halfHour, 24)
    }

    // MARK: Prediction

    /// The flyby of `LineFillTests.fanTone`: 141 m/s, 2 km at closest (1.5 km up, 1.32 km to the
    /// side), closest emission at seconds/2 − 6 into the audio, flying east. Archive positions
    /// every 10 s, each up to 5 s stale (the block's time, not the position's), as on real data.
    static func archive(seconds: Double = 60, stale: ClosedRange<Double> = 0...5, seed: UInt64 = 3, speedKnots: Double? = nil) -> [UInt8] {
        let v = 141.0, up = 1_500.0, side = (2_000.0 * 2_000 - up * up).squareRoot(), tc = seconds / 2 - 6
        var rng = SeededRNG(seed: seed), w = Writer()
        for k in -30...36 {
            let block = Self.start + Double(k) * 10
            w.block(block)
            let age = Double.random(in: stale, using: &rng)
            let (la, lo) = place(east: v * (block - age - Self.start - tc), north: side)
            w.aircraft(0xA1B2C3, lat: la, lon: lo, feet: up / 0.3048, knots: speedKnots ?? v / 0.514_444)
        }
        return w.bytes
    }

    static func predictions(seconds: Double = 60, stale: ClosedRange<Double> = 0...5, seed: UInt64 = 3) -> [PassPrediction.Prediction] {
        let l = Listener(latitude: lat, longitude: lon, audioStart: start, duration: seconds, temperature: 15)
        let p = FlightArchive.positions(archive(seconds: seconds, stale: stale, seed: seed), near: lat, lon, radiusKm: 40,
                                        from: start - 240, to: start + seconds + 240)
        return PassPrediction().predict(p, listener: l)
    }

    /// Every curve finds the pass (distance, closest approach within the staleness); their shapes
    /// differ, as on real data: the ground-speed curve follows the truth within 2.5 % (after the
    /// timing slip the search allows), the straight-line fit within 12 %, the interpolated ones
    /// within 15 % (positions up to 5 s stale move a 141 m/s aircraft by up to 700 m).
    func testFourCurvesFindThePassAndOneFollowsItClosely() {
        let ps = Self.predictions()
        XCTAssertEqual(ps.map(\.method), PassPrediction.Method.allCases)
        let c = 331.3 + 0.606 * 15, tc = 24.0
        let tolerance: [PassPrediction.Method: Double] = [.groundSpeed: 0.025, .straight30: 0.12, .interpolated10: 0.15, .interpolated20: 0.15]
        for p in ps {
            XCTAssertTrue(p.pass.isValid)
            XCTAssertEqual(p.closestDistance, 2_000, accuracy: 150, "\(p.method)")
            // Stale positions put the aircraft behind where it was: the closest approach late.
            XCTAssertEqual(p.pass.closest!, tc + 2_000 / c, accuracy: 5, "\(p.method)")
            var best = Double.infinity
            for slip in stride(from: -6.0, through: 6, by: 0.25) {
                var worst = 0.0
                for t in stride(from: tc - 25, through: tc + 25, by: 0.5) {
                    guard let f = p.pass.factor(at: t + slip) else { continue }
                    worst = max(worst, abs(f - Self.truth(t, c: c)))
                }
                best = min(best, worst)
            }
            XCTAssertLessThan(best, tolerance[p.method]!, "\(p.method)")
        }
    }

    /// Heard frequency ÷ emitted at audio time t, for the test flyby (Newton on the emission time).
    static func truth(_ t: Double, c: Double) -> Double {
        let v = 141.0, d = 2_000.0, tc = 24.0
        var te = t - d / c
        for _ in 0..<20 { te = t - hypot(d, v * (te - tc)) / c }
        let x = v * (te - tc)
        return 1 / (1 + v * x / (c * hypot(d, x)))
    }

    func testLeavesOutWhatDoesntComeNear() {
        let l = Listener(latitude: Self.lat, longitude: Self.lon, audioStart: Self.start, duration: 60)
        var w = Writer()
        for k in -30...36 {
            w.block(Self.start + Double(k) * 10)
            let (la, lo) = Self.place(east: 141 * Double(k) * 10, north: 20_000)        // 20 km off: too far
            w.aircraft(0x111111, lat: la, lon: lo, feet: 5_000, knots: 274)
            let (lb, lob) = Self.place(east: 141 * (Double(k) * 10 - 400), north: 1_000) // closest 7 min later
            w.aircraft(0x222222, lat: lb, lon: lob, feet: 5_000, knots: 274)
        }
        let p = FlightArchive.positions(w.bytes, near: Self.lat, Self.lon, radiusKm: 40, from: Self.start - 240, to: Self.start + 300)
        XCTAssertEqual(p.count, 2)
        XCTAssertTrue(PassPrediction().predict(p, listener: l).isEmpty)
        // No usable place or time: nothing.
        var bad = l
        bad.latitude = 91
        XCTAssertTrue(PassPrediction().predict(Self.positionsOfTestFlyby(), listener: bad).isEmpty)
        bad = l
        bad.duration = .nan
        XCTAssertTrue(PassPrediction().predict(Self.positionsOfTestFlyby(), listener: bad).isEmpty)
    }

    static func positionsOfTestFlyby() -> [String: [AircraftPosition]] {
        FlightArchive.positions(archive(), near: lat, lon, radiusKm: 40, from: start - 240, to: start + 300)
    }

    /// Without ground speed the fourth curve is skipped; the other three remain.
    func testWithoutGroundSpeedThreeCurves() {
        let p = FlightArchive.positions(Self.archive(speedKnots: 0), near: Self.lat, Self.lon, radiusKm: 40,
                                        from: Self.start - 240, to: Self.start + 300)
        let l = Listener(latitude: Self.lat, longitude: Self.lon, audioStart: Self.start, duration: 60)
        XCTAssertEqual(PassPrediction().predict(p, listener: l).map(\.method), [.interpolated10, .interpolated20, .straight30])
    }

    func testDeterministic() {
        XCTAssertEqual(Self.predictions().map(\.pass), Self.predictions().map(\.pass))
    }

    // MARK: Removal driven by the archive

    /// The page's path end to end: a pass too faint for the blind check, removal driven only by
    /// stale archive positions, judged by an attacker holding the exact curve. (The background is
    /// one where that attacker finds nothing on the noise alone: on some white-noise draws the
    /// best of ~45,000 rest-and-timing combinations along a fixed curve scores z 4 by chance, which
    /// no removal driven by different curves can be expected to touch.)
    func testRemovalFromTheArchiveBeatsTheExactTrack() {
        let rate = TrackFillTests.rate
        let exact = TrackFillTests.stage([TrackFillTests.expected()])
        XCTAssertLessThan(TrackFillTests.verdict(DetectionScenes.white(rate * 60, seed: 22), exact)?.z ?? 0, 1.5)
        for (snr, seed) in [(13.0, UInt64(3)), (20, 6)] {
            let x = LineFillTests.fanTone(rate: rate, snr: snr, seed: 22).mono
            var stage = TrackFill()
            stage.expected = Self.predictions(seed: seed).map(\.pass)
            stage.seed = 5
            XCTAssertGreaterThan(TrackFillTests.verdict(x, exact)?.z ?? 0, exact.stopZ + 2)
            let r = stage.process(x, sampleRate: rate)
            XCTAssertLessThan(TrackFillTests.verdict(r.output, exact)?.z ?? 0, exact.stopZ, "\(snr) dB: \(r.summary)")
        }
    }
}
