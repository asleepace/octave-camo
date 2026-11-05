public enum ScrubStep: String, CaseIterable, Codable {
    /// Average channels: removes direction of arrival from multi-mic recordings.
    case mono
    /// Notch mains harmonics: removes the ENF clock.
    case hum
    /// Track and cancel long tones.
    case subtract
    /// Blind search for flyby pitch curves (no flight data), cancelled.
    case scurve
    /// Regenerate the band below the cutoff as information-free texture.
    case lowband
    /// Per-band random pitch drift on whatever is left.
    case wobble
    /// Fill every line the check still finds, at any frequency it looks at, with noise.
    case lines
}

/// A mono signal-processing step in the pipeline.
protocol ScrubStage {
    var step: ScrubStep { get }
    /// Returns the processed signal and a one-line summary for logs.
    func process(_ x: [Double], sampleRate: Int) -> (output: [Double], summary: String)
}

public struct ScrubResult {
    /// Mono output.
    public let audio: Audio
    /// One line per stage that ran.
    public let log: [String]
}

/// mono → hum → subtract → scurve → lowband (→ tracks → wobble → lines). Each stage is
/// configurable and can be switched off; `tracks` runs only when given expected passes. The default
/// matches the harness's recommended chain `hum+subtract+scurve+lowband`
/// (scurve catches faint tones above the lowband cutoff, such as train wheels); the pitch wobble
/// is opt-in, since benchmarks showed it adds little once `lowband` runs.
public struct ScrubPipeline {
    public static let defaultSteps: Set<ScrubStep> = [.mono, .hum, .subtract, .scurve, .lowband]
    /// Input samples beyond this (60 dB over full scale) are corrupt, not loud.
    public static let maxSampleMagnitude = 1_000.0

    public var steps: Set<ScrubStep> = ScrubPipeline.defaultSteps
    public var hum = HumNotch()
    public var subtraction = ToneSubtraction()
    public var scurve = SCurveCancel()
    public var lowband = LowBandRegeneration()
    public var wobble = BandWobble()
    public var lines = LineFill()
    /// Removes the tones flight tracks predict (runs only when given expected passes, before
    /// `wobble` and `lines`).
    public var tracks = TrackFill()
    /// Output is scaled down if it would exceed this peak.
    public var peakCeiling = 0.99

    public init() {}

    public func run(_ input: Audio) -> ScrubResult {
        var log: [String] = []
        // One NaN or Inf would spread through every filter and FFT and silence (or blow up) the
        // whole output, and one absurd value (a corrupt float file) would make the peak limiter
        // scale everything else to nothing.
        var input = input
        var replaced = 0
        let usable = { (v: Double) in v.isFinite && abs(v) <= Self.maxSampleMagnitude }
        for c in input.channels.indices where !input.channels[c].allSatisfy(usable) {
            for i in input.channels[c].indices where !usable(input.channels[c][i]) {
                input.channels[c][i] = 0
                replaced += 1
            }
        }
        if replaced > 0 { log.append("input: replaced \(replaced) non-finite or out-of-range sample(s) with silence") }

        var y: [Double]
        if steps.contains(.mono) {
            y = input.mono
            log.append("mono: averaged \(input.channels.count) channel(s)")
        } else {
            y = input.channels[0]
            if input.channels.count > 1 { log.append("mono: off, kept channel 0 of \(input.channels.count)") }
        }

        // Track removal (when given expected passes) goes after the low band is replaced and
        // before anything moves pitches (wobble) or fills what the check still finds (lines).
        let before: [any ScrubStage] = [hum, subtraction, scurve, lowband], after: [any ScrubStage] = [wobble, lines]
        for stage in before where steps.contains(stage.step) { run(stage, &y, &log, sampleRate: input.sampleRate) }
        runTracks(&y, &log, sampleRate: input.sampleRate)
        for stage in after where steps.contains(stage.step) { run(stage, &y, &log, sampleRate: input.sampleRate) }

        DSP.limitPeak(&y, to: peakCeiling)
        return ScrubResult(audio: Audio(sampleRate: input.sampleRate, channels: [y]), log: log)
    }
}

extension ScrubPipeline {
    func run(_ stage: any ScrubStage, _ y: inout [Double], _ log: inout [String], sampleRate: Int) {
        let result = stage.process(y, sampleRate: sampleRate)
        y = result.output
        log.append(result.summary)
    }

    func runTracks(_ y: inout [Double], _ log: inout [String], sampleRate: Int) {
        guard !tracks.expected.isEmpty else { return }
        var tracks = tracks
        if steps.contains(.lowband), lowband.cutoff < tracks.band.upperBound - 100 {
            tracks.band = max(tracks.band.lowerBound, lowband.cutoff)...tracks.band.upperBound
        }
        let result = tracks.process(y, sampleRate: sampleRate)
        y = result.output
        log.append(result.summary)
    }
}
