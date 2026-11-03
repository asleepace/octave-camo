#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WASILibc)
import WASILibc
#endif

/// A narrowband tone followed across STFT frames.
public struct Track {
    /// Frame-center times, s.
    public internal(set) var times: [Double]
    /// Peak frequencies (parabolic-interpolated), Hz.
    public internal(set) var frequencies: [Double]
    /// Peak levels, dB.
    public internal(set) var levels: [Double]

    public var duration: Double { (times.last ?? 0) - (times.first ?? 0) }
    public var meanFrequency: Double { DSP.mean(frequencies) }
    public var minFrequency: Double { frequencies.min() ?? 0 }
    public var maxFrequency: Double { frequencies.max() ?? 0 }
    /// (max − min) / mean.
    public var sweep: Double { meanFrequency > 0 ? (maxFrequency - minFrequency) / meanFrequency : 0 }
}

/// Finds long-lived tones: what an attacker needs, and what the scrubber subtracts.
/// Speech harmonics last well under a second; aircraft, hum and HVAC last many seconds.
public struct ToneTracker {
    public struct Config {
        /// FFT size in samples (~2.9 Hz bins at 48 kHz).
        public var window = 16_384
        public var hop = 2_048
        public var frequencyRange: ClosedRange<Double> = 40...1_000
        /// More ranges to search, each with its own `maxPeaksPerFrame` budget (so loud peaks in
        /// one can't crowd out tones in another). Tracks may cross between ranges.
        public var extraRanges: [ClosedRange<Double>] = []
        /// Peak threshold in the extra ranges. Fine bins up there give background noise thousands
        /// of chances per frame to clear 10 dB; at 15 dB it practically never does, while a real
        /// whine stands 30 dB or more above its floor.
        public var extraThresholdDB = 15.0
        /// Association tolerance in the extra ranges, as frequency drift per second (scaled by the
        /// hop): a fixed share of the frequency (like `relativeTolerance`) is ±100 Hz at 5 kHz,
        /// wide enough to chain unrelated noise peaks. 5 %/s follows a passing jet's whine.
        public var extraDriftPerSecond = 0.05
        /// Tracks shorter than this are discarded.
        public var minDuration = 2.0
        /// How far a peak must stand above the local median floor.
        public var thresholdDB = 10.0
        /// Half-width, in bins, of the window used for the median floor.
        public var floorHalfWidth = 20
        public var maxPeaksPerFrame = 24
        /// Frames a track may go unmatched before it is closed.
        public var maxMisses = 3
        /// Association tolerance: max(minToleranceHz, relativeTolerance × frequency).
        public var minToleranceHz = 3.0
        public var relativeTolerance = 0.02

        public init() {}

        /// Lowest to highest frequency searched, Hz.
        public var coverage: ClosedRange<Double> {
            let all = [frequencyRange] + extraRanges
            return all.map(\.lowerBound).min()!...all.map(\.upperBound).max()!
        }
    }

    public var config: Config

    public init(config: Config = Config()) { self.config = config }

    private struct Peak { var frequency: Double; var level: Double }
    private struct OpenTrack { var track: Track; var misses = 0 }

    public func tracks(in x: [Double], sampleRate: Int) -> [Track] {
        let c = config
        guard x.count >= c.window else { return [] }

        let fft = RealFFT(size: c.window)
        let window = DSP.hann(c.window)
        let binHz = Double(sampleRate) / Double(c.window)
        let ranges: [Range<Int>] = ([c.frequencyRange] + c.extraRanges).compactMap { r in
            let lowBin = max(Int(r.lowerBound / binHz), 1)
            let highBin = min(Int(r.upperBound / binHz), fft.binCount - c.floorHalfWidth - 2)
            return highBin > lowBin ? lowBin..<highBin : nil
        }
        guard let highBin = ranges.map(\.upperBound).max() else { return [] }

        var frame = [Double](repeating: 0, count: c.window)
        var re = [Double](repeating: 0, count: fft.binCount)
        var im = [Double](repeating: 0, count: fft.binCount)
        var levelDB = [Double](repeating: 0, count: fft.binCount)
        var open: [OpenTrack] = []
        var closed: [Track] = []

        for start in stride(from: 0, through: x.count - c.window, by: c.hop) {
            for i in 0..<c.window { frame[i] = x[start + i] * window[i] }
            fft.forward(frame, &re, &im)
            for k in 0...(highBin + c.floorHalfWidth) {
                levelDB[k] = 20 * log10((re[k] * re[k] + im[k] * im[k]).squareRoot() + 1e-12)
            }

            let peaks = ranges.enumerated().flatMap { i, bins in
                findPeaks(levelDB, bins: bins, binHz: binHz, thresholdDB: i == 0 ? c.thresholdDB : c.extraThresholdDB)
            }
            let time = (Double(start) + Double(c.window) / 2) / Double(sampleRate)
            let used = associate(peaks, with: &open, at: time, hopSeconds: Double(c.hop) / Double(sampleRate))

            // Close tracks that have gone quiet; start new ones from unclaimed peaks.
            closed += open.filter { $0.misses > c.maxMisses }.map(\.track)
            open.removeAll { $0.misses > c.maxMisses }
            for (j, p) in peaks.enumerated() where !used.contains(j) {
                open.append(OpenTrack(track: Track(times: [time], frequencies: [p.frequency], levels: [p.level])))
            }
        }
        closed += open.map(\.track)
        return closed.filter { $0.duration >= c.minDuration }
    }

    /// Local maxima standing above the local median floor, strongest first.
    private func findPeaks(_ db: [Double], bins: Range<Int>, binHz: Double, thresholdDB: Double) -> [Peak] {
        let c = config
        var peaks: [Peak] = []
        for k in bins where db[k] > db[k - 1] && db[k] >= db[k + 1] {
            let floorDB = DSP.median(db[max(k - c.floorHalfWidth, 0)...(k + c.floorHalfWidth)])
            guard db[k] - floorDB > thresholdDB else { continue }
            // Parabolic interpolation on the dB spectrum for sub-bin frequency.
            let a = db[k - 1], b = db[k], d = db[k + 1]
            let denominator = a - 2 * b + d
            let offset = denominator != 0 ? 0.5 * (a - d) / denominator : 0
            peaks.append(Peak(frequency: (Double(k) + offset) * binHz, level: b))
        }
        peaks.sort { $0.level > $1.level }
        return Array(peaks.prefix(c.maxPeaksPerFrame))
    }

    /// Greedy nearest-frequency association. Returns the indices of peaks that were claimed.
    private func associate(_ peaks: [Peak], with open: inout [OpenTrack], at time: Double, hopSeconds: Double) -> Set<Int> {
        var used = Set<Int>()
        for idx in open.indices {
            let predicted = open[idx].track.frequencies[open[idx].track.frequencies.count - 1]
            var best: Int?
            let share = predicted > config.frequencyRange.upperBound && !config.extraRanges.isEmpty
                ? config.extraDriftPerSecond * hopSeconds : config.relativeTolerance
            var bestDistance = max(config.minToleranceHz, share * predicted)
            for (j, p) in peaks.enumerated() where !used.contains(j) {
                let distance = abs(p.frequency - predicted)
                if distance < bestDistance { best = j; bestDistance = distance }
            }
            if let j = best {
                used.insert(j)
                open[idx].track.times.append(time)
                open[idx].track.frequencies.append(peaks[j].frequency)
                open[idx].track.levels.append(peaks[j].level)
                open[idx].misses = 0
            } else {
                open[idx].misses += 1
            }
        }
        return used
    }
}
