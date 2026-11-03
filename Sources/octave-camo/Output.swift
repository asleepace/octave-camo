import OctaveCamoKit
import Foundation

struct Stopwatch: CustomStringConvertible {
    private let start: Date
    init() { start = Date() }
    var description: String { Output.seconds(Date().timeIntervalSince(start)) }
}

enum Output {
    static func stderr(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    static func seconds(_ s: Double) -> String { String(format: "%.1fs", s) }

    static func describe(_ g: FlybyGeometry) -> String {
        String(format: "f0 %.0f Hz, speed %.0f m/s, closest %.0f m at t=%.1fs", g.f0, g.speed, g.distance, g.t0)
    }

    // MARK: Analysis

    static func printTable(_ a: Analysis, source: String, elapsed: String) {
        print("\(source): \(a.tracks.count) long tones (\(elapsed))")
        print(columns(["kind", "freq(Hz)", "range(Hz)", "dur(s)", "f0(Hz)", "speed(m/s)", "t0(s)", "dist(m)", "rms(Hz)"]))
        for r in a.tracks {
            var cells = [
                r.kind.rawValue,
                String(format: "%.2f", r.meanFrequency),
                String(format: "%.1f–%.1f", r.minFrequency, r.maxFrequency),
                String(format: "%.1f", r.duration),
            ]
            if let fit = r.fit {
                let g = fit.geometry
                cells += [String(format: "%.2f", g.f0), String(format: "%.1f", g.speed),
                          String(format: "%.2f", g.t0), String(format: "%.0f", g.distance),
                          String(format: "%.3f", fit.rms)]
            }
            print(columns(cells))
        }
        print("")
        if let g = a.consensus {
            print("verdict: LOCATION RISK — \(a.flybys.count) flyby fit(s), consensus \(describe(g))")
        } else {
            print("verdict: no usable flyby curve found")
        }
        if let hum = a.hum.first {
            print(String(format: "         mains hum present (%.0f Hz): ENF timestamp risk", hum.meanFrequency))
        }
    }

    static func printJSON(_ a: Analysis) throws {
        struct Payload: Encodable {
            let tracks: [TrackReport]
            let consensus: FlybyGeometry?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Payload(tracks: a.tracks, consensus: a.consensus))
        print(String(decoding: data, as: UTF8.self))
    }

    /// Left-aligned fixed-width columns, sized to the header.
    private static let widths = [8, 10, 15, 8, 9, 12, 8, 9, 8]

    private static func columns(_ cells: [String]) -> String {
        zip(cells, widths).map { cell, width in
            cell.count >= width ? cell + " " : cell + String(repeating: " ", count: width - cell.count)
        }.joined()
    }
}
