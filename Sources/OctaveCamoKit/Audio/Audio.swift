/// Planar PCM audio. Samples are nominally in [-1, 1].
public struct Audio {
    public var sampleRate: Int
    public var channels: [[Double]]

    public init(sampleRate: Int, channels: [[Double]]) {
        precondition(sampleRate > 0, "sample rate must be positive")
        precondition(!channels.isEmpty, "audio needs at least one channel")
        precondition(channels.allSatisfy { $0.count == channels[0].count }, "channels must be equal length")
        self.sampleRate = sampleRate
        self.channels = channels
    }

    public var frameCount: Int { channels[0].count }
    public var duration: Double { Double(frameCount) / Double(sampleRate) }

    /// Average of all channels.
    public var mono: [Double] {
        guard channels.count > 1 else { return channels[0] }
        var out = [Double](repeating: 0, count: frameCount)
        for ch in channels {
            for i in 0..<frameCount { out[i] += ch[i] }
        }
        let scale = 1 / Double(channels.count)
        for i in 0..<frameCount { out[i] *= scale }
        return out
    }
}
