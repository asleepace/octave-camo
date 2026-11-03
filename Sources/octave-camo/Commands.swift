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
    Command(name: "scrub", options: ["steps", "mains", "passes", "cutoff", "lowband-mode", "depth", "wobble-top", "seed"],
            flags: ["no-keep-voice"], run: scrub),
]

let usage = """
octave-camo — find and remove aircraft Doppler curves from audio

USAGE
  octave-camo synth   <out.wav> [--hard] [--f0 120] [--speed 75] [--distance 1500]
                        [--t0 30] [--duration 60] [--seed 1]
  octave-camo analyze <in.wav>  [--threshold 10] [--json]
  octave-camo scrub   <in.wav> <out.wav> [--steps mono,hum,subtract,scurve,lowband[,wobble]]
                        [--mains 60] [--passes 3] [--cutoff 300] [--lowband-mode regenerate|highpass]
                        [--no-keep-voice] [--depth 0.015] [--wobble-top 600] [--seed N]

COMMANDS
  synth    Write a known-truth test clip (one flyby, hum, noise, speech-like syllables).
  analyze  The attacker: track long tones, fit the flyby model, report distance/speed/time.
           Lower --threshold to simulate a more sensitive attacker (try 6 or 3).
  scrub    The defense: mono downmix, hum notches, tone subtraction, per-band wobble.
           --wobble-top 400 is gentler on voices but can leave a usable distance (see README).
           Output is mono 32-bit float WAV. Use scripts/scrub-video.sh for video files.
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
    pipeline.wobble.depth = try args.value("depth", default: pipeline.wobble.depth)
    pipeline.wobble.top = try args.value("wobble-top", default: pipeline.wobble.top)
    pipeline.wobble.seed = try args.value("seed", default: pipeline.wobble.seed)
    pipeline.lowband.seed = pipeline.wobble.seed
    pipeline.hum.seed = pipeline.wobble.seed
    try require(pipeline.subtraction.passes >= 0, "--passes must be 0 or more")
    try require(pipeline.wobble.depth >= 0 && pipeline.wobble.depth <= 0.1, "--depth must be between 0 and 0.1")
    try require(pipeline.lowband.cutoff > 20 && pipeline.lowband.cutoff.isFinite, "--cutoff must be above 20 Hz")

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
