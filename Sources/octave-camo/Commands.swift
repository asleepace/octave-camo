import Foundation
import OctaveCamoKit
import OctaveCamoIO

struct Command {
    let name: String
    let options: Set<String>
    let flags: Set<String>
    let run: (Arguments) throws -> Void
}

let commands = [
    Command(name: "synth", options: ["f0", "speed", "distance", "t0", "duration", "seed"],
            flags: ["hard"], run: synth),
    Command(name: "analyze", options: ["threshold"], flags: ["json"], run: analyze),
    Command(name: "scrub", options: ["steps", "mains", "passes", "cutoff", "lowband-mode", "flatten", "depth", "wobble-top", "seed", "expect",
                                     "archive", "at", "start", "temp", "track-stop", "track-max-tones", "track-tolerance-hz", "track-tolerance", "track-windows", "track-target"],
            flags: ["no-keep-voice"], run: scrub),
    Command(name: "predict", options: ["at", "start", "duration", "temp"], flags: [], run: predict),
]

let usage = """
octave-camo — remove the location and time clues from a recording's sound

USAGE
  octave-camo synth   <out.wav> [--hard] [--f0 120] [--speed 75] [--distance 1500]
                        [--t0 30] [--duration 60] [--seed 1]
  octave-camo analyze <in.wav>  [--threshold 10] [--json]
  octave-camo scrub   <in.wav> <out.wav> [--steps mono,hum,subtract,scurve,lowband[,wobble][,lines]]
                        [--mains 50,60] [--passes 3] [--cutoff 300] [--lowband-mode regenerate|highpass]
                        [--flatten off|gentle|strong|N] (low-band swells slower than 10 s
                        (gentle, the default), 5 s (strong) or N s flattened)
                        [--no-keep-voice] [--depth 0.015] [--wobble-top 600] [--seed N]
                        [--expect passes.json] (remove what these predicted Doppler curves carry,
                        until a known-path attacker's test fails: [{"times": [s…], "factors":
                        [received/emitted…], "closest": s}, …], ±2 min around the audio)
                        [--archive heatmap.bin[,next.bin] --at lat,lon[,alt] --start unix [--temp 15]]
                        (or predict those curves from adsb.lol's half-hour archive: where and
                        when the audio starts, alt in metres on the pressure-altitude scale)
                        [--track-stop 1] (remove until each pass's attacker z is below this)
                        [--track-max-tones 24] [--track-tolerance-hz 0] [--track-tolerance 0] [--track-windows 0.17] [--track-target fixed|null]
                        (tones per pass; the stopping test's slack off the curve, Hz and fraction)
  octave-camo predict <heatmap.bin> --at lat,lon[,alt] --start unix --duration s [--temp 15]
  octave-camo --version

COMMANDS
  synth    Write a known-truth test clip (one flyby, hum, noise, speech-like syllables).
  analyze  The attacker: track long tones, fit the flyby model, report distance/speed/time.
           Lower --threshold to simulate a more sensitive attacker (try 6 or 3).
  predict  The curves --archive would use, as JSON: each nearby aircraft's predicted Doppler
           curves (audio times and factors only; no positions) and closest distance.
  scrub    The defense, by default mono → hum → subtract → scurve → lowband (the web app's
           Full preset); --steps picks stages (wobble is opt-in). --seed makes the noise
           repeatable. Output is mono 32-bit float WAV. Use scripts/scrub-video.sh for video.
"""

func synth(_ args: Arguments) throws {
    let path = try args.positional(at: 0, named: "<out.wav>")
    var s = FlybySynth()
    s.flyby.f0 = try args.value("f0", default: s.flyby.f0)
    s.flyby.speed = try args.value("speed", default: s.flyby.speed)
    s.flyby.distance = try args.value("distance", default: s.flyby.distance)
    s.flyby.t0 = try args.value("t0", default: s.flyby.t0)
    s.duration = try args.value("duration", default: s.duration)
    s.seed = try args.value("seed", default: s.seed)
    s.hard = args.flag("hard")
    try require(s.duration >= 1, "--duration must be at least 1 second")
    try require(s.flyby.f0 > 0 && s.flyby.f0.isFinite, "--f0 must be positive")
    try require(s.flyby.distance > 0 && s.flyby.distance.isFinite, "--distance must be positive")
    try require(s.flyby.speed > 0 && s.flyby.speed < FlybyGeometry.speedOfSound,
                "--speed must be between 0 and the speed of sound (\(FlybyGeometry.speedOfSound) m/s)")
    try require(s.flyby.t0.isFinite, "--t0 must be a number")

    let clock = Stopwatch()
    try WAV.write(s.render(), to: path)
    print("wrote \(path): \(Output.describe(s.flyby))\(s.hard ? ", turbulence + multipath" : "") (\(clock))")
}

func analyze(_ args: Arguments) throws {
    let path = try args.positional(at: 0, named: "<in.wav>")
    var analyzer = FlybyAnalyzer()
    analyzer.tracker.config.thresholdDB = try args.value("threshold", default: analyzer.tracker.config.thresholdDB)

    let clock = Stopwatch()
    let result = analyzer.analyze(try WAV.read(from: path))
    if args.flag("json") {
        try Output.printJSON(result)
    } else {
        Output.printTable(result, source: path, elapsed: clock.description)
    }
}

func scrub(_ args: Arguments) throws {
    let input = try args.positional(at: 0, named: "<in.wav>")
    let output = try args.positional(at: 1, named: "<out.wav>")
    var pipeline = ScrubPipeline()
    if let raw = args.string("steps") {
        pipeline.steps = try parseSteps(raw)
    }
    if let raw = args.string("mains") {
        pipeline.hum.mains = try raw.split(separator: ",").map { part -> Double in
            guard let v = Double(part.trimmingCharacters(in: .whitespaces)), v >= 0, v.isFinite else {
                throw UsageError("--mains takes a comma-separated list such as 50,60 (0 disables)")
            }
            return v
        }.filter { $0 > 0 }
    }
    pipeline.subtraction.passes = try args.value("passes", default: pipeline.subtraction.passes)
    pipeline.lowband.cutoff = try args.value("cutoff", default: pipeline.lowband.cutoff)
    if let raw = args.string("lowband-mode") {
        guard let mode = LowBandRegeneration.Mode(rawValue: raw) else {
            throw UsageError("--lowband-mode must be \(LowBandRegeneration.Mode.allCases.map(\.rawValue).joined(separator: " or "))")
        }
        pipeline.lowband.mode = mode
    }
    pipeline.lowband.keepVoice = !args.flag("no-keep-voice")
    if let raw = args.string("flatten") {
        if let named = LowBandRegeneration.Flatten(rawValue: raw) { pipeline.lowband.flattenSeconds = named.seconds }
        else if let seconds = Double(raw) { pipeline.lowband.flattenSeconds = seconds }
        else { throw UsageError("--flatten takes \(LowBandRegeneration.Flatten.allCases.map(\.rawValue).joined(separator: ", ")) or seconds") }
    }
    pipeline.wobble.depth = try args.value("depth", default: pipeline.wobble.depth)
    pipeline.wobble.top = try args.value("wobble-top", default: pipeline.wobble.top)
    pipeline.wobble.seed = try args.value("seed", default: pipeline.wobble.seed)
    pipeline.lowband.seed = pipeline.wobble.seed
    pipeline.hum.seed = pipeline.wobble.seed
    pipeline.lines.seed = pipeline.wobble.seed
    pipeline.tracks.seed = pipeline.wobble.seed
    pipeline.tracks.stopZ = try args.value("track-stop", default: pipeline.tracks.stopZ)
    pipeline.tracks.maxTones = try args.value("track-max-tones", default: pipeline.tracks.maxTones)
    pipeline.tracks.toleranceHz = try args.value("track-tolerance-hz", default: pipeline.tracks.toleranceHz)
    pipeline.tracks.relativeTolerance = try args.value("track-tolerance", default: pipeline.tracks.relativeTolerance)
    if let w = args.string("track-target") {
        guard let t = TrackFill.Target(rawValue: w) else { throw UsageError("--track-target takes fixed or null") }
        pipeline.tracks.target = t
    }
    if let w = args.string("track-windows") {
        pipeline.tracks.windows = w.split(separator: ",").compactMap { Double($0) }
        try require(!pipeline.tracks.windows.isEmpty && pipeline.tracks.windows.allSatisfy { (0.02...1).contains($0) },
                    "--track-windows takes seconds, comma-separated, 0.02-1")
    }
    if let path = args.string("expect") {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        pipeline.tracks.expected = try JSONDecoder().decode([ExpectedPass].self, from: data)
        try require(pipeline.tracks.expected.allSatisfy(\.isValid),
                    "--expect: each pass needs ≥ 2 finite, strictly increasing times and as many factors in 0.5–2")
    }
    let archive = args.string("archive")
    try require(archive == nil || args.string("expect") == nil, "--archive and --expect are alternatives")
    try require(pipeline.tracks.stopZ.isFinite, "--track-stop must be a number")
    try require((1...64).contains(pipeline.tracks.maxTones), "--track-max-tones must be 1-64")
    try require((0...60).contains(pipeline.tracks.toleranceHz), "--track-tolerance-hz must be 0-60")
    try require((0...0.05).contains(pipeline.tracks.relativeTolerance), "--track-tolerance must be 0-0.05")
    try require(pipeline.subtraction.passes >= 0, "--passes must be 0 or more")
    try require(pipeline.wobble.depth >= 0 && pipeline.wobble.depth <= 0.1, "--depth must be between 0 and 0.1")
    try require(pipeline.lowband.cutoff > 20 && pipeline.lowband.cutoff.isFinite, "--cutoff must be above 20 Hz")
    try require(pipeline.lowband.flattenSeconds >= 0 && pipeline.lowband.flattenSeconds <= 120, "--flatten must be between 0 and 120 s")

    let clock = Stopwatch()
    let audio = try WAV.read(from: input)
    try require(pipeline.wobble.top.isFinite && pipeline.wobble.top > 0
                    && pipeline.wobble.top < Double(audio.sampleRate) / 4,
                "--wobble-top must be positive and below a quarter of the sample rate")
    if let archive {
        let listener = try listenerOptions(args, duration: audio.duration)
        let predictions = PassPrediction().predict(try archivePositions(archive, listener), listener: listener)
        pipeline.tracks.expected = predictions.map(\.pass)
        Output.stderr("archive: \(Set(predictions.map(\.aircraft)).count) aircraft within \(Int(PassPrediction().maxDistance / 1_000)) km, \(predictions.count) predicted curves")
    }
    Output.stderr("scrubbing \(input) (\(audio.sampleRate) Hz, \(audio.channels.count) ch, \(Output.seconds(audio.duration)))")
    let result = pipeline.run(audio)
    result.log.forEach { Output.stderr("  " + $0) }
    try WAV.write(result.audio, to: output)
    print("wrote \(output) (\(clock))")
}

func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw UsageError(message()) }
}

func parseSteps(_ raw: String) throws -> Set<ScrubStep> {
    var steps = Set<ScrubStep>()
    for name in raw.split(separator: ",") {
        guard let step = ScrubStep(rawValue: String(name)) else {
            let valid = ScrubStep.allCases.map(\.rawValue).joined(separator: ", ")
            throw UsageError("unknown step '\(name)' (valid: \(valid))")
        }
        steps.insert(step)
    }
    return steps
}

/// Where and when, from --at lat,lon[,alt] --start unix [--temp C].
func listenerOptions(_ args: Arguments, duration: Double) throws -> Listener {
    guard let at = args.string("at") else { throw UsageError("--at lat,lon[,alt] is required") }
    let parts = at.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard (2...3).contains(parts.count), parts.allSatisfy({ $0 != nil }) else { throw UsageError("--at takes lat,lon or lat,lon,alt") }
    guard let raw = args.string("start"), let start = Double(raw) else { throw UsageError("--start unix-seconds is required") }
    let l = Listener(latitude: parts[0]!, longitude: parts[1]!, altitude: parts.count == 3 ? parts[2]! : 0,
                     audioStart: start, duration: duration, temperature: try args.value("temp", default: 15.0))
    try require(l.isValid, "--at, --start or --temp is out of range")
    return l
}

/// The archives' positions near the listener: comma-separated files (a clip can span two half
/// hours), un-gzipped first if needed (with gzip).
func archivePositions(_ paths: String, _ l: Listener) throws -> [String: [AircraftPosition]] {
    var all: [String: [AircraftPosition]] = [:]
    for path in paths.split(separator: ",").map(String.init) {
        for (id, list) in try archivePositions(file: path, l) { all[id, default: []] += list }
    }
    return all.mapValues { $0.sorted { $0.time < $1.time } }
}

func archivePositions(file path: String, _ l: Listener) throws -> [String: [AircraftPosition]] {
    var data = try Data(contentsOf: URL(fileURLWithPath: path))
    if data.starts(with: [0x1F, 0x8B]) {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["gzip", "-dc", path]
        p.standardOutput = out
        try p.run()
        data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        try require(p.terminationStatus == 0, "couldn't un-gzip \(path)")
    }
    let m = PassPrediction().positionMargin
    return FlightArchive.positions([UInt8](data), near: l.latitude, l.longitude, radiusKm: 40,
                                   from: l.audioStart - m, to: l.audioStart + l.duration + m)
}

func predict(_ args: Arguments) throws {
    let path = try args.positional(at: 0, named: "<heatmap.bin>")
    let duration: Double = try args.value("duration", default: 0)
    try require(duration > 0, "--duration (s) is required")
    let listener = try listenerOptions(args, duration: duration)
    let predictions = PassPrediction().predict(try archivePositions(path, listener), listener: listener)
    struct Row: Encodable { let aircraft: String; let method: String; let closest_m: Int; let times: [Double]; let factors: [Double]; let closest: Double? }
    let enc = JSONEncoder()
    let rows = predictions.map { Row(aircraft: $0.aircraft, method: $0.method.rawValue, closest_m: Int($0.closestDistance.rounded()),
                                     times: $0.pass.times, factors: $0.pass.factors, closest: $0.pass.closest) }
    print(String(decoding: try enc.encode(rows), as: UTF8.self))
}
