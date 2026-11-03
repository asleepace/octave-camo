public enum ScrubStep: String, CaseIterable, Codable {
    /// Average channels: removes direction of arrival from multi-mic recordings.
    case mono
    /// Notch mains harmonics: removes the ENF clock.
    case hum
    /// Track and cancel long tones.
    case subtract
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

/// mono → hum → subtract → wobble. Each stage is configurable and can be switched off.
public struct ScrubPipeline {
    public var steps: Set<ScrubStep> = Set(ScrubStep.allCases)
    public var hum = HumNotch()
    public var subtraction = ToneSubtraction()
    public var wobble = BandWobble()
    /// Output is scaled down if it would exceed this peak.
    public var peakCeiling = 0.99

    public init() {}

    public func run(_ input: Audio) -> ScrubResult {
        var log: [String] = []
        var y: [Double]
        if steps.contains(.mono) {
            y = input.mono
            log.append("mono: averaged \(input.channels.count) channel(s)")
        } else {
            y = input.channels[0]
            if input.channels.count > 1 { log.append("mono: off, kept channel 0 of \(input.channels.count)") }
        }

        let stages: [any ScrubStage] = [hum, subtraction, wobble]
        for stage in stages where steps.contains(stage.step) {
            let result = stage.process(y, sampleRate: input.sampleRate)
            y = result.output
            log.append(result.summary)
        }

        DSP.limitPeak(&y, to: peakCeiling)
        return ScrubResult(audio: Audio(sampleRate: input.sampleRate, channels: [y]), log: log)
    }
}
