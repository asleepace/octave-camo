import Foundation

/// Track-following cancellation: for each long tone, heterodyne to DC with the tracked phase,
/// low-pass to get its complex amplitude A(t), resynthesize 2·Re(A·e^{iφ}) and subtract it.
/// Offline and non-causal, so the low-pass is centered and adds no lag.
public struct ToneSubtraction: ScrubStage {
    var step: ScrubStep { .subtract }

    /// Each pass re-tracks the residual and cancels what is left. 0 disables subtraction.
    public var passes = 3
    /// Amplitude low-pass length; ±~1/length Hz around the track is cancelled.
    public var lowpassSeconds = 0.15
    /// Padding beyond each track's ends, also used as the fade length.
    public var edgeSeconds = 0.2
    public var tracker = ToneTracker()

    public init() {}

    public func process(_ x: [Double], sampleRate: Int) -> (output: [Double], summary: String) {
        var y = x
        var counts: [Int] = []
        for _ in 0..<max(passes, 0) {
            let tracks = tracker.tracks(in: y, sampleRate: sampleRate)
            counts.append(tracks.count)
            if tracks.isEmpty { break }
            for track in tracks { cancel(track, in: &y, sampleRate: sampleRate) }
        }
        let perPass = counts.isEmpty ? "none (0 passes)" : counts.map(String.init).joined(separator: " → ")
        return (y, "subtract: long tones per pass \(perPass)")
    }

    func cancel(_ track: Track, in y: inout [Double], sampleRate: Int) {
        guard let first = track.times.first, let last = track.times.last else { return }
        let sr = Double(sampleRate)
        let start = max(Int((first - edgeSeconds) * sr), 0)
        let end = min(Int((last + edgeSeconds) * sr), y.count)
        let m = end - start
        guard m > 2 else { return }

        let times = (0..<m).map { Double(start + $0) / sr }
        let phase = DSP.cumulativePhase(DSP.interpolate(times, track.times, track.frequencies), dt: 1 / sr)
        let cosP = phase.map { cos($0) }
        let sinP = phase.map { sin($0) }

        // Heterodyne: z = y·e^{-iφ}, then two box passes (triangle) for A(t).
        let length = Int(lowpassSeconds * sr)
        let zr = (0..<m).map { y[start + $0] * cosP[$0] }
        let zi = (0..<m).map { -y[start + $0] * sinP[$0] }
        let ar = DSP.movingAverage(DSP.movingAverage(zr, length: length), length: length)
        let ai = DSP.movingAverage(DSP.movingAverage(zi, length: length), length: length)

        let fade = min(Int(edgeSeconds * sr), m / 2)
        for i in 0..<m {
            var gain = 1.0
            if fade > 1 {
                if i < fade { gain = Double(i) / Double(fade - 1) }
                else if i >= m - fade { gain = Double(m - 1 - i) / Double(fade - 1) }
            }
            y[start + i] -= 2 * (ar[i] * cosP[i] - ai[i] * sinP[i]) * gain
        }
    }
}
