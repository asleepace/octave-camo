// WebAssembly entry points for the web app. Built as a WASI reactor:
//
//   swift build -c release --swift-sdk swift-6.4.2-RELEASE_wasm --product octave-camo-wasm \
//     -Xswiftc -Xclang-linker -Xswiftc -mexec-model=reactor
//
// Calling convention (all sizes in elements, all audio Float32):
//   ptr = camo_alloc(channels * frames)      write planar input samples at ptr
//   n   = camo_scrub(ptr, channels, frames, sampleRate, stepsMask, seedLo, seedHi)
//   out = camo_output()                       n mono output samples (valid until the next scrub)
//   log = camo_log(), len = camo_log_length() UTF-8, one line per stage
//   camo_free(ptr)
//   st  = camo_analyze(ptr, channels, frames, sampleRate)
//         4 Int32: long tonal tracks, Doppler-shaped tracks, mains-hum lines, fitted flybys
// stepsMask bit i enables ScrubStep.allCases[i]; 0 means the default steps.

#if arch(wasm32)
import OctaveCamoKit

nonisolated(unsafe) var output: [Float] = []
nonisolated(unsafe) var logBytes: [UInt8] = []
nonisolated(unsafe) var stats = [Int32](repeating: 0, count: 4)

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
               _ stepsMask: Int32, _ seedLo: UInt32, _ seedHi: UInt32) -> Int32 {
    guard let clip = audio(input, channelCount, frames, sampleRate) else { return 0 }
    var pipeline = ScrubPipeline()
    if stepsMask != 0 {
        var steps = Set<ScrubStep>()
        for (i, step) in ScrubStep.allCases.enumerated() where stepsMask & (1 << i) != 0 { steps.insert(step) }
        pipeline.steps = steps
    }
    let seed = UInt64(seedHi) << 32 | UInt64(seedLo)
    if seed != 0 {
        pipeline.lowband.seed = seed
        pipeline.wobble.seed = seed
    }

    let result = pipeline.run(clip)
    let mono = result.audio.channels[0]
    output = [Float](repeating: 0, count: mono.count)
    for i in 0..<mono.count { output[i] = Float(mono[i]) }
    logBytes = Array(result.log.joined(separator: "\n").utf8)
    return Int32(output.count)
}

@_expose(wasm, "camo_analyze")
@_cdecl("camo_analyze")
func camoAnalyze(_ input: UnsafePointer<Float>, _ channelCount: Int32, _ frames: Int32,
                 _ sampleRate: Int32) -> UnsafePointer<Int32>? {
    for i in 0..<stats.count { stats[i] = 0 }
    if let clip = audio(input, channelCount, frames, sampleRate) {
        let analysis = FlybyAnalyzer().analyze(clip)
        stats[0] = Int32(analysis.tracks.count)
        stats[1] = Int32(analysis.flybys.count)
        stats[2] = Int32(analysis.hum.count)
        stats[3] = Int32(analysis.flybys.filter { $0.fit != nil }.count)
    }
    return stats.withUnsafeBufferPointer { $0.baseAddress }
}

@_expose(wasm, "camo_output")
@_cdecl("camo_output")
func camoOutput() -> UnsafePointer<Float>? {
    output.withUnsafeBufferPointer { $0.baseAddress }
}

@_expose(wasm, "camo_log")
@_cdecl("camo_log")
func camoLog() -> UnsafePointer<UInt8>? {
    logBytes.withUnsafeBufferPointer { $0.baseAddress }
}

@_expose(wasm, "camo_log_length")
@_cdecl("camo_log_length")
func camoLogLength() -> Int32 {
    Int32(logBytes.count)
}
#else
print("octave-camo-wasm: build for WebAssembly (see the comment at the top of main.swift)")
#endif
