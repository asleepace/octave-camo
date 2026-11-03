// WebAssembly entry points for the web app. Built as a WASI reactor:
//
//   swift build -c release --swift-sdk swift-6.4.2-RELEASE_wasm --product octave-camo-wasm \
//     -Xswiftc -Xclang-linker -Xswiftc -mexec-model=reactor
//
// Calling convention (all sizes in elements, all audio Float32):
//   ptr = camo_alloc(channels * frames)      write planar input samples at ptr
//   n   = camo_scrub(ptr, channels, frames, sampleRate, stepsMask, seedLo, seedHi, cutoffHz, keepVoice)
//   out = camo_output()                       n mono output samples (valid until the next scrub)
//   log = camo_log(), len = camo_log_length() UTF-8, one line per stage
//   camo_free(ptr)
//   st  = camo_analyze(ptr, channels, frames, sampleRate)
//         4 Int32: long tonal tracks, Doppler-shaped tracks, mains-hum lines, fitted flybys
//
// Video flicker (the picture's ENF clock), on row profiles the page measures:
//   ptr = camo_alloc(frames * strips * rows + frames)   log brightness [frame][strip][row], then
//                                                       each frame's time in seconds
//   sum = camo_flicker(ptr, frames, strips, rows, clean)
//         8 Float64: detected, z, flicker Hz, cycles per frame, readout s, after detected, after z,
//         passes removed
//   g   = camo_flicker_gains()                          frames × rows Float32 gains (after clean = 1)
// stepsMask bit i enables ScrubStep.allCases[i]; 0 means the default steps. cutoffHz <= 0 keeps the
// lowband default; keepVoice is 0 or 1.

#if arch(wasm32)
import OctaveCamoKit

/// Results handed back to JavaScript. Static, not top-level: top-level variables in main.swift
/// are initialized by main(), which a WASI reactor never runs (they'd stay zeroed, i.e. empty).
enum Shared {
    nonisolated(unsafe) static var output: [Float] = []
    nonisolated(unsafe) static var logBytes: [UInt8] = []
    nonisolated(unsafe) static var stats = [Int32](repeating: 0, count: 4)
    nonisolated(unsafe) static var flicker = [Double](repeating: 0, count: 8)
    nonisolated(unsafe) static var gains: [Float] = []
}

func audio(_ input: UnsafePointer<Float>, _ channelCount: Int32, _ frames: Int32, _ sampleRate: Int32) -> Audio? {
    let c = Int(channelCount), n = Int(frames)
    guard c > 0, n > 0, sampleRate > 0 else { return nil }
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
               _ cutoffHz: Double, _ keepVoice: Int32) -> Int32 {
    guard let clip = audio(input, channelCount, frames, sampleRate) else { return 0 }
    var pipeline = ScrubPipeline()
    if stepsMask != 0 {
        var steps = Set<ScrubStep>()
        for (i, step) in ScrubStep.allCases.enumerated() where stepsMask & (1 << i) != 0 { steps.insert(step) }
        pipeline.steps = steps
    }
    if cutoffHz > 0 { pipeline.lowband.cutoff = cutoffHz }
    pipeline.lowband.keepVoice = keepVoice != 0
    let seed = UInt64(seedHi) << 32 | UInt64(seedLo)
    if seed != 0 {
        pipeline.lowband.seed = seed
        pipeline.wobble.seed = seed
        pipeline.hum.seed = seed
    }

    let result = pipeline.run(clip)
    let mono = result.audio.channels[0]
    Shared.output = [Float](repeating: 0, count: mono.count)
    for i in 0..<mono.count { Shared.output[i] = Float(mono[i]) }
    Shared.logBytes = Array(result.log.joined(separator: "\n").utf8)
    return Int32(Shared.output.count)
}

@_expose(wasm, "camo_analyze")
@_cdecl("camo_analyze")
func camoAnalyze(_ input: UnsafePointer<Float>, _ channelCount: Int32, _ frames: Int32,
                 _ sampleRate: Int32) -> UnsafePointer<Int32>? {
    for i in 0..<Shared.stats.count { Shared.stats[i] = 0 }
    if let clip = audio(input, channelCount, frames, sampleRate) {
        let analysis = FlybyAnalyzer().analyze(clip)
        Shared.stats[0] = Int32(analysis.tracks.count)
        Shared.stats[1] = Int32(analysis.flybys.count)
        Shared.stats[2] = Int32(analysis.hum.count)
        Shared.stats[3] = Int32(analysis.flybys.filter { $0.fit != nil }.count)
    }
    return Shared.stats.withUnsafeBufferPointer { $0.baseAddress }
}

@_expose(wasm, "camo_flicker")
@_cdecl("camo_flicker")
func camoFlicker(_ input: UnsafePointer<Float>, _ frames: Int32, _ strips: Int32, _ rows: Int32,
                 _ clean: Int32) -> UnsafePointer<Double>? {
    for i in 0..<Shared.flicker.count { Shared.flicker[i] = 0 }
    Shared.gains = []
    let K = Int(frames), S = Int(strips), R = Int(rows)
    guard K >= 8, S >= 1, R >= 8 else { return Shared.flicker.withUnsafeBufferPointer { $0.baseAddress } }
    var values = [Double](repeating: 0, count: K * S * R)
    for i in 0..<(K * S * R) { values[i] = Double(input[i]) }
    var times = [Double](repeating: 0, count: K)
    for k in 0..<K { times[k] = Double(input[K * S * R + k]) }
    let profiles = FlickerScan.Profiles(frames: K, strips: S, rows: R, values: values, times: times)
    let scan = FlickerScan()

    func store(_ f: FlickerScan.Finding, at offset: Int) {
        if offset == 0 {
            Shared.flicker[0] = f.detected ? 1 : 0
            Shared.flicker[1] = f.z
            Shared.flicker[2] = f.flicker
            Shared.flicker[3] = f.cycles
            Shared.flicker[4] = f.readoutSeconds
        } else {
            Shared.flicker[5] = f.detected ? 1 : 0
            Shared.flicker[6] = f.z
        }
    }
    if clean != 0 {
        let result = scan.clean(profiles)
        if let first = result.findings.first { store(first, at: 0) }
        store(result.after, at: 1)
        Shared.flicker[7] = Double(result.findings.filter(\.detected).count)
        Shared.gains = result.gains.map { Float($0) }
    } else {
        let finding = scan.scan(profiles)
        store(finding, at: 0)
        store(finding, at: 1)
    }
    return Shared.flicker.withUnsafeBufferPointer { $0.baseAddress }
}

@_expose(wasm, "camo_flicker_gains")
@_cdecl("camo_flicker_gains")
func camoFlickerGains() -> UnsafePointer<Float>? {
    Shared.gains.withUnsafeBufferPointer { $0.baseAddress }
}

@_expose(wasm, "camo_output")
@_cdecl("camo_output")
func camoOutput() -> UnsafePointer<Float>? {
    Shared.output.withUnsafeBufferPointer { $0.baseAddress }
}

@_expose(wasm, "camo_log")
@_cdecl("camo_log")
func camoLog() -> UnsafePointer<UInt8>? {
    Shared.logBytes.withUnsafeBufferPointer { $0.baseAddress }
}

@_expose(wasm, "camo_log_length")
@_cdecl("camo_log_length")
func camoLogLength() -> Int32 {
    Int32(Shared.logBytes.count)
}
#else
print("octave-camo-wasm: build for WebAssembly (see the comment at the top of main.swift)")
#endif
