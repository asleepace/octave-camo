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

/// mono → hum → subtract → scurve → lowband (→ wobble). Each stage is configurable and can be
/// switched off. The default matches the harness's recommended chain `hum+subtract+scurve+lowband`
/// (scurve catches faint tones above the lowband cutoff, such as train wheels); the pitch wobble
/// is opt-in, since benchmarks showed it adds little once `lowband` runs.
public struct ScrubPipeline {
    public static let defaultSteps: Set<ScrubStep> = [.mono, .hum, .subtract, .scurve, .lowband]

    public var steps: Set<ScrubStep> = ScrubPipeline.defaultSteps
    public var hum = HumNotch()
    public var subtraction = ToneSubtraction()
    public var scurve = SCurveCancel()
    public var lowband = LowBandRegeneration()
    public var wobble = BandWobble()
    /// Output is scaled down if it would exceed this peak.
    public var peakCeiling = 0.99

    public init() {}

    public func run(_ input: Audio) -> ScrubResult {
        var log: [String] = []
        // One NaN or Inf would spread through every filter and FFT and silence (or blow up) the
        // whole output; a corrupt decode can produce them.
        var input = input
        var replaced = 0
        for c in input.channels.indices where !input.channels[c].allSatisfy(\.isFinite) {
            for i in input.channels[c].indices where !input.channels[c][i].isFinite {
                input.channels[c][i] = 0
                replaced += 1
            }
        }
        if replaced > 0 { log.append("input: replaced \(replaced) non-finite sample(s) with silence") }

        var y: [Double]
        if steps.contains(.mono) {
            y = input.mono
            log.append("mono: averaged \(input.channels.count) channel(s)")
        } else {
            y = input.channels[0]
            if input.channels.count > 1 { log.append("mono: off, kept channel 0 of \(input.channels.count)") }
        }

        let stages: [any ScrubStage] = [hum, subtraction, scurve, lowband, wobble]
        for stage in stages where steps.contains(stage.step) {
            let result = stage.process(y, sampleRate: input.sampleRate)
            y = result.output
            log.append(result.summary)
        }

        DSP.limitPeak(&y, to: peakCeiling)
        return ScrubResult(audio: Audio(sampleRate: input.sampleRate, channels: [y]), log: log)
    }
}
