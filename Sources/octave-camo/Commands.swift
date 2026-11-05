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
    Command(name: "scrub", options: ["steps", "mains", "passes", "cutoff", "lowband-mode", "flatten", "depth", "wobble-top", "seed", "expect"],
            flags: ["no-keep-voice"], run: scrub),
]

let usage = """
octave-camo — remove the location and time clues from a recording's sound

USAGE
  octave-camo synth   <out.wav> [--hard] [--f0 120] [--speed 75] [--distance 1500]
                        [--t0 30] [--duration 60] [--seed 1]
  octave-camo analyze <in.wav>  [--threshold 10] [--json]
  octave-camo scrub   <in.wav> <out.wav> [--steps mono,hum,subtract,scurve,lowband[,wobble][,lines]]
                        [--mains 50,60] [--passes 3] [--cutoff 300] [--lowband-mode regenerate|highpass]
                        [--flatten 5] (experimental: flatten low-band swells slower than N s)
                        [--no-keep-voice] [--depth 0.015] [--wobble-top 600] [--seed N]
                        [--expect passes.json] (remove what these predicted Doppler curves carry,
                        until a known-path attacker's test fails: [{"times": [s…], "factors":
                        [received/emitted…], "closest": s}, …], ±2 min around the audio)
  octave-camo --version

COMMANDS
  synth    Write a known-truth test clip (one flyby, hum, noise, speech-like syllables).
  analyze  The attacker: track long tones, fit the flyby model, report distance/speed/time.
           Lower --threshold to simulate a more sensitive attacker (try 6 or 3).
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
    pipeline.lowband.flattenSeconds = try args.value("flatten", default: pipeline.lowband.flattenSeconds)
    pipeline.wobble.depth = try args.value("depth", default: pipeline.wobble.depth)
    pipeline.wobble.top = try args.value("wobble-top", default: pipeline.wobble.top)
    pipeline.wobble.seed = try args.value("seed", default: pipeline.wobble.seed)
    pipeline.lowband.seed = pipeline.wobble.seed
    pipeline.hum.seed = pipeline.wobble.seed
    pipeline.lines.seed = pipeline.wobble.seed
    pipeline.tracks.seed = pipeline.wobble.seed
    if let path = args.string("expect") {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        pipeline.tracks.expected = try JSONDecoder().decode([ExpectedPass].self, from: data)
        try require(pipeline.tracks.expected.allSatisfy(\.isValid),
                    "--expect: each pass needs ≥ 2 finite, strictly increasing times and as many factors in 0.5–2")
    }
    try require(pipeline.subtraction.passes >= 0, "--passes must be 0 or more")
    try require(pipeline.wobble.depth >= 0 && pipeline.wobble.depth <= 0.1, "--depth must be between 0 and 0.1")
    try require(pipeline.lowband.cutoff > 20 && pipeline.lowband.cutoff.isFinite, "--cutoff must be above 20 Hz")
    try require(pipeline.lowband.flattenSeconds >= 0 && pipeline.lowband.flattenSeconds <= 120, "--flatten must be between 0 and 120 s")

    let clock = Stopwatch()
    let audio = try WAV.read(from: input)
    try require(pipeline.wobble.top.isFinite && pipeline.wobble.top > 0
                    && pipeline.wobble.top < Double(audio.sampleRate) / 4,
                "--wobble-top must be positive and below a quarter of the sample rate")
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
