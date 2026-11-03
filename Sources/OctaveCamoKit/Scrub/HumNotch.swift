#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WASILibc)
import WASILibc
#endif

/// Narrow zero-phase notches at mains harmonics. Removes the electrical-network-frequency
/// fluctuations that can timestamp a recording against grid logs.
public struct HumNotch: ScrubStage {
    var step: ScrubStep { .hum }

    /// 60 Hz in the Americas, 50 Hz in most of the rest of the world.
    public var mains = 60.0
    /// Harmonics are notched below this frequency.
    public var maxFrequency = 400.0
    public var q = 30.0

    public init() {}

    var harmonics: [Double] {
        guard mains > 0 else { return [] }
        return Array(stride(from: mains, to: maxFrequency, by: mains))
    }

    public func process(_ x: [Double], sampleRate: Int) -> (output: [Double], summary: String) {
        let freqs = harmonics
        let y = freqs.reduce(x) { signal, f in
            Biquad.notch(frequency: f, q: q, sampleRate: sampleRate).applyZeroPhase(signal)
        }
        return (y, "hum: notched \(freqs.count) harmonics of \(Int(mains)) Hz")
    }
}
