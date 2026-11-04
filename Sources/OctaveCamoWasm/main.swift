// WebAssembly entry points for the web app. Built as a WASI reactor:
//
//   swift build -c release --swift-sdk swift-6.4.2-RELEASE_wasm --product octave-camo-wasm \
//     -Xswiftc -Xclang-linker -Xswiftc -mexec-model=reactor
//
// Calling convention (all sizes in elements, all audio Float32):
//   ptr = camo_alloc(channels * frames)      write planar input samples at ptr
//   n   = camo_scrub(ptr, channels, frames, sampleRate, stepsMask, seedLo, seedHi, cutoffHz, keepVoice,
//                    flattenSeconds)            flattenSeconds 0 = off (LowBandRegeneration.flattenSeconds)
//   out = camo_output()                       n mono output samples (valid until the next scrub)
//   log = camo_log(), len = camo_log_length() UTF-8, one line per stage
//   camo_free(ptr)
//   st  = camo_analyze(ptr, channels, frames, sampleRate)
//         4 Int32: long tonal tracks, Doppler-shaped tracks, mains-hum lines, fitted flybys
//         (all -1: the input was rejected, which is not the same as clean)
//   t   = camo_tracks(), n = camo_tracks_length()   after camo_analyze: n Float32, 5 per long tone
//         found: start s, end s, lowest Hz, highest Hz, kind (0 hum, 1 steady, 2 doppler, 3 no fit)
// camo_scrub returns 0 and leaves an empty output when it rejects its input (no stale result).
//
// Video flicker (the picture's ENF clock), on row profiles the page measures:
//   ptr = camo_alloc(frames * strips * rows + frames)   log brightness [frame][strip][row], then
//                                                       each frame's time in seconds
//   sum = camo_flicker(ptr, frames, strips, rows, clean)
//         9 Float64: detected, z, flicker Hz, cycles per frame, readout s, after detected, after z,
//         passes removed, checked (0: too few frames or too high a frame rate to look; not clean)
//   g   = camo_flicker_gains(), n = camo_flicker_gains_length()
//         n Float32 gains, frames × rows after a clean (1 where untouched), 0 otherwise
// stepsMask bit i enables ScrubStep.allCases[i]; 0 means the default steps. cutoffHz <= 0 keeps the
// lowband default; keepVoice is 0 or 1.

#if arch(wasm32)
import OctaveCamoKit

/// A result buffer JavaScript reads from wasm memory. It owns its allocation, so the address it
/// hands out stays valid until the next `set` (a pointer escaping `withUnsafeBufferPointer` would
/// not be).
final class Outbox<T> {
    private(set) var pointer: UnsafeMutablePointer<T>
    private(set) var count = 0
    private var capacity = 1

    init() { pointer = .allocate(capacity: 1) }

    func set(_ values: [T]) {
        if values.count > capacity {
            pointer.deallocate()
            capacity = values.count
            pointer = .allocate(capacity: capacity)
        }
        values.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { pointer.update(from: base, count: values.count) }
        }
        count = values.count
    }
}

/// Results handed back to JavaScript. Static, not top-level: top-level variables in main.swift
/// are initialized by main(), which a WASI reactor never runs (they'd stay zeroed, i.e. empty).
enum Shared {
    nonisolated(unsafe) static let output = Outbox<Float>()
    nonisolated(unsafe) static let logBytes = Outbox<UInt8>()
    nonisolated(unsafe) static let stats = Outbox<Int32>()
    nonisolated(unsafe) static let flicker = Outbox<Double>()
    nonisolated(unsafe) static let gains = Outbox<Float>()
    nonisolated(unsafe) static let tracks = Outbox<Float>()
}

/// `a × b × …` if it fits in Int (32 bits in wasm32), else nil: sizes come from JavaScript.
func product(_ factors: Int...) -> Int? {
    var total = 1
    for f in factors {
        guard f >= 0 else { return nil }
        let (value, overflow) = total.multipliedReportingOverflow(by: f)
        if overflow { return nil }
        total = value
    }
    return total
}

func audio(_ input: UnsafePointer<Float>, _ channelCount: Int32, _ frames: Int32, _ sampleRate: Int32) -> Audio? {
    let c = Int(channelCount), n = Int(frames)
    guard c > 0, c <= 64, n > 0, sampleRate > 0, product(c, n, MemoryLayout<Double>.stride) != nil else { return nil }
    var channels: [[Double]] = []
    for ch in 0..<c {
        var samples = [Double](repeating: 0, count: n)
        let base = input + ch * n
        for i in 0..<n { samples[i] = Double(base[i]) }
        channels.append(samples)
    }
    return Audio(sampleRate: Int(sampleRate), channels: channels)
}

@_expose(wasm, "camo_alloc")
@_cdecl("camo_alloc")
func camoAlloc(_ count: Int32) -> UnsafeMutablePointer<Float> {
    UnsafeMutablePointer<Float>.allocate(capacity: Int(max(count, 1)))
}

@_expose(wasm, "camo_free")
@_cdecl("camo_free")
func camoFree(_ pointer: UnsafeMutablePointer<Float>) {
    pointer.deallocate()
}

@_expose(wasm, "camo_steps")
@_cdecl("camo_steps")
func camoSteps() -> Int32 {
    var mask: Int32 = 0
    for (i, step) in ScrubStep.allCases.enumerated() where ScrubPipeline.defaultSteps.contains(step) { mask |= 1 << i }
    return mask
}

@_expose(wasm, "camo_scrub")
@_cdecl("camo_scrub")
func camoScrub(_ input: UnsafePointer<Float>, _ channelCount: Int32, _ frames: Int32, _ sampleRate: Int32,
               _ stepsMask: Int32, _ seedLo: UInt32, _ seedHi: UInt32,
               _ cutoffHz: Double, _ keepVoice: Int32, _ flattenSeconds: Double) -> Int32 {
    guard let clip = audio(input, channelCount, frames, sampleRate) else {
        Shared.output.set([])
        Shared.logBytes.set(Array("scrub: input rejected".utf8))
        return 0
    }
    var pipeline = ScrubPipeline()
    if stepsMask != 0 {
        var steps = Set<ScrubStep>()
        for (i, step) in ScrubStep.allCases.enumerated() where stepsMask & (1 << i) != 0 { steps.insert(step) }
        pipeline.steps = steps
    }
    if cutoffHz > 0 { pipeline.lowband.cutoff = cutoffHz }
    pipeline.lowband.keepVoice = keepVoice != 0
    if flattenSeconds.isFinite && flattenSeconds > 0 { pipeline.lowband.flattenSeconds = min(flattenSeconds, 120) }
    let seed = UInt64(seedHi) << 32 | UInt64(seedLo)
    if seed != 0 {
        pipeline.lowband.seed = seed
        pipeline.wobble.seed = seed
        pipeline.hum.seed = seed
    }

    let result = pipeline.run(clip)
    Shared.output.set(result.audio.channels[0].map { Float($0) })
    Shared.logBytes.set(Array(result.log.joined(separator: "\n").utf8))
    return Int32(Shared.output.count)
}

@_expose(wasm, "camo_analyze")
@_cdecl("camo_analyze")
func camoAnalyze(_ input: UnsafePointer<Float>, _ channelCount: Int32, _ frames: Int32,
                 _ sampleRate: Int32) -> UnsafePointer<Int32> {
    var stats = [Int32](repeating: -1, count: 4)
    var tracks: [Float] = []
    if let clip = audio(input, channelCount, frames, sampleRate) {
        let analysis = FlybyAnalyzer().analyze(clip)
        stats = [Int32(analysis.tracks.count), Int32(analysis.flybys.count), Int32(analysis.hum.count),
                 Int32(analysis.flybys.filter { $0.fit != nil }.count)]
        let kinds: [TrackKind] = [.hum, .steady, .doppler, .noFit]
        for t in analysis.tracks {
            tracks += [Float(t.start), Float(t.start + t.duration), Float(t.minFrequency), Float(t.maxFrequency),
                       Float(kinds.firstIndex(of: t.kind) ?? 3)]
        }
    }
    Shared.tracks.set(tracks)
    Shared.stats.set(stats)
    return UnsafePointer(Shared.stats.pointer)
}

@_expose(wasm, "camo_flicker")
@_cdecl("camo_flicker")
func camoFlicker(_ input: UnsafePointer<Float>, _ frames: Int32, _ strips: Int32, _ rows: Int32,
                 _ clean: Int32) -> UnsafePointer<Double> {
    var summary = [Double](repeating: 0, count: 9)
    Shared.gains.set([])
    let K = Int(frames), S = Int(strips), R = Int(rows)
    guard K >= 8, S >= 1, R >= 8, let total = product(K, S, R), product(total + K, MemoryLayout<Double>.stride) != nil else {
        Shared.flicker.set(summary)
        return UnsafePointer(Shared.flicker.pointer)
    }
    var values = [Double](repeating: 0, count: total)
    for i in 0..<(total) { values[i] = Double(input[i]) }
    var times = [Double](repeating: 0, count: K)
    for k in 0..<K { times[k] = Double(input[total + k]) }
    let profiles = FlickerScan.Profiles(frames: K, strips: S, rows: R, values: values, times: times)
    let scan = FlickerScan()

    func store(_ f: FlickerScan.Finding, at offset: Int) {
        if offset == 0 {
            summary[0] = f.detected ? 1 : 0
            summary[1] = f.z
            summary[2] = f.flicker
            summary[3] = f.cycles
            summary[4] = f.readoutSeconds
            summary[8] = f.checked ? 1 : 0
        } else {
            summary[5] = f.detected ? 1 : 0
            summary[6] = f.z
        }
    }
    if clean != 0 {
        let result = scan.clean(profiles)
        if let first = result.findings.first { store(first, at: 0) }
        store(result.after, at: 1)
        summary[7] = Double(result.findings.filter(\.detected).count)
        Shared.gains.set(result.gains.map { Float($0) })
    } else {
        let finding = scan.scan(profiles)
        store(finding, at: 0)
        store(finding, at: 1)
    }
    Shared.flicker.set(summary)
    return UnsafePointer(Shared.flicker.pointer)
}

@_expose(wasm, "camo_flicker_gains")
@_cdecl("camo_flicker_gains")
func camoFlickerGains() -> UnsafePointer<Float> {
    UnsafePointer(Shared.gains.pointer)
}

@_expose(wasm, "camo_flicker_gains_length")
@_cdecl("camo_flicker_gains_length")
func camoFlickerGainsLength() -> Int32 {
    Int32(Shared.gains.count)
}

@_expose(wasm, "camo_tracks")
@_cdecl("camo_tracks")
func camoTracks() -> UnsafePointer<Float> {
    UnsafePointer(Shared.tracks.pointer)
}

@_expose(wasm, "camo_tracks_length")
@_cdecl("camo_tracks_length")
func camoTracksLength() -> Int32 {
    Int32(Shared.tracks.count)
}

@_expose(wasm, "camo_output")
@_cdecl("camo_output")
func camoOutput() -> UnsafePointer<Float> {
    UnsafePointer(Shared.output.pointer)
}

@_expose(wasm, "camo_log")
@_cdecl("camo_log")
func camoLog() -> UnsafePointer<UInt8> {
    UnsafePointer(Shared.logBytes.pointer)
}

@_expose(wasm, "camo_log_length")
@_cdecl("camo_log_length")
func camoLogLength() -> Int32 {
    Int32(Shared.logBytes.count)
}
#else
print("octave-camo-wasm: build for WebAssembly (see the comment at the top of main.swift)")
#endif
