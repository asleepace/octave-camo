#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WASILibc)
import WASILibc
#endif

/// One aircraft position from a flight archive.
public struct AircraftPosition: Equatable {
    /// Unix time, s.
    public var time: Double
    public var latitude: Double
    public var longitude: Double
    /// Barometric altitude, ft (pressure altitude, as ADS-B reports it).
    public var altitudeFeet: Double
    /// Ground speed, knots; nil when the archive doesn't say.
    public var groundSpeedKnots: Double?

    public init(time: Double, latitude: Double, longitude: Double, altitudeFeet: Double, groundSpeedKnots: Double? = nil) {
        self.time = time
        self.latitude = latitude
        self.longitude = longitude
        self.altitudeFeet = altitudeFeet
        self.groundSpeedKnots = groundSpeedKnots
    }
}

/// adsb.lol's worldwide archive for one half hour (`globe_history/YYYY/MM/DD/heatmap/NN.bin.ttf`,
/// NN = half hours since 00:00 UTC): every aircraft's position about every 10 s. One file covers
/// the whole world, so fetching it reveals the time and nothing about the place.
///
/// The file (once un-gzipped) is little-endian Int32 records of four: a marker record
/// (`0x0E7F7C9D`, then the time in ms as high and low words) starts each 10 s block; the records
/// after it are an aircraft's ICAO address, latitude·1e6, longitude·1e6, and its altitude in 25 ft
/// units (−123 on the ground) in the low 16 bits with ground speed·10 kt in the high 16. Other
/// records (callsigns, addresses with flag bits) don't decode to a plausible position and are
/// skipped. Each position carries its block's time, not its own: it can be a few seconds old.
public enum FlightArchive {
    static let marker: Int32 = 0x0E7F_7C9D
    static let groundAltitude: Int16 = -123

    /// Positions of airborne aircraft within `radiusKm` of a point (horizontally) and between `from`
    /// and `to` (Unix s), by ICAO address (6 hex digits), in time order.
    public static func positions(_ bytes: [UInt8], near latitude: Double, _ longitude: Double, radiusKm: Double,
                                 from: Double, to: Double) -> [String: [AircraftPosition]] {
        var out: [String: [AircraftPosition]] = [:]
        let count = bytes.count / 16
        guard count > 0 else { return out }
        let cosLat = cos(latitude * .pi / 180), r = radiusKm * 1_000
        var time: Double? = nil
        bytes.withUnsafeBufferPointer { raw in
            func word(_ i: Int) -> Int32 {
                let b = raw.baseAddress! + i * 4
                return Int32(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24)
            }
            for rec in 0..<count {
                let id = word(rec * 4), a = word(rec * 4 + 1), b = word(rec * 4 + 2), packed = word(rec * 4 + 3)
                if id == marker {
                    let ms = Double(Int64(a) << 32 | Int64(UInt32(bitPattern: b)))
                    time = ms / 1_000
                    continue
                }
                guard let t = time, t >= from, t <= to, id >= 0, id < 1 << 24 else { continue }
                let lat = Double(a) / 1e6, lon = Double(b) / 1e6
                let alt = Int16(truncatingIfNeeded: packed)
                guard abs(lat) <= 90, abs(lon) <= 180, alt != groundAltitude else { continue }
                let feet = Double(alt) * 25
                guard feet >= -2_000, feet <= 60_000 else { continue }
                let dx = (lon - longitude) * .pi / 180 * earthRadius * cosLat, dy = (lat - latitude) * .pi / 180 * earthRadius
                guard dx * dx + dy * dy <= r * r else { continue }
                let gs = Double(UInt16(truncatingIfNeeded: packed >> 16)) / 10
                out[hex(id), default: []].append(AircraftPosition(time: t, latitude: lat, longitude: lon, altitudeFeet: feet,
                                                                  groundSpeedKnots: gs > 0 ? gs : nil))
            }
        }
        for key in out.keys { out[key]!.sort { $0.time < $1.time } }
        return out
    }

    static let earthRadius = 6_371_000.0

    static func hex(_ id: Int32) -> String {
        let digits = Array("0123456789abcdef")
        var s = "", v = Int(id)
        for _ in 0..<6 { s = String(digits[v & 15]) + s; v >>= 4 }
        return s
    }

    /// The archive file holding a moment: its half hour of the UTC day, and its path on adsb.lol.
    public static func file(for unix: Double) -> (halfHour: Int, path: String) {
        let day = (unix / 86_400).rounded(.down), seconds = unix - day * 86_400
        let half = Int(seconds / 1_800)
        let (y, m, d) = civil(days: Int(day))
        func two(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }
        return (half, "globe_history/\(y)/\(two(m))/\(two(d))/heatmap/\(two(half)).bin.ttf")
    }

    /// The UTC calendar date of a day count since 1970-01-01 (Howard Hinnant's civil_from_days).
    static func civil(days: Int) -> (Int, Int, Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }
}
