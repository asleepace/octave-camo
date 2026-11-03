import Foundation
import OctaveCamoKit

public enum WAVError: Error, CustomStringConvertible {
    case invalid(String)

    public var description: String {
        switch self {
        case .invalid(let message): return "invalid WAV: \(message)"
        }
    }
}

/// Minimal RIFF/WAVE reader and writer.
/// Reads PCM 16/24/32-bit int and 32/64-bit float, including WAVE_FORMAT_EXTENSIBLE.
/// Writes 32-bit float.
public enum WAV {
    private static let formatPCM = 1
    private static let formatFloat = 3
    private static let formatExtensible = 0xFFFE

    public static func read(from path: String) throws -> Audio {
        let bytes = LittleEndianBytes([UInt8](try Data(contentsOf: URL(fileURLWithPath: path))))
        guard bytes.count >= 12, bytes.tag(0) == "RIFF", bytes.tag(8) == "WAVE" else {
            throw WAVError.invalid("not a RIFF/WAVE file")
        }

        var format = 0, channelCount = 0, sampleRate = 0, bitsPerSample = 0
        var dataRange: Range<Int>?
        var offset = 12
        while offset + 8 <= bytes.count {
            let id = bytes.tag(offset)
            let size = bytes.u32(offset + 4)
            let body = offset + 8
            switch id {
            case "fmt ":
                guard body + 16 <= bytes.count else { throw WAVError.invalid("truncated fmt chunk") }
                format = bytes.u16(body)
                channelCount = bytes.u16(body + 2)
                sampleRate = bytes.u32(body + 4)
                bitsPerSample = bytes.u16(body + 14)
                if format == formatExtensible, size >= 26, body + 26 <= bytes.count {
                    format = bytes.u16(body + 24)   // sub-format GUID starts with the real format code
                }
            case "data":
                dataRange = body..<min(body + size, bytes.count)   // streamed WAVs can carry a bogus size
            default:
                break
            }
            if dataRange != nil, format != 0 { break }
            offset = body + size + (size & 1)
        }

        guard format != 0, channelCount > 0, sampleRate > 0, bitsPerSample >= 8, let data = dataRange else {
            throw WAVError.invalid("missing or malformed fmt/data chunk")
        }
        let decode = try sampleDecoder(format: format, bits: bitsPerSample, bytes: bytes)
        let stride = bitsPerSample / 8
        let frameCount = data.count / (stride * channelCount)
        guard frameCount > 0 else { throw WAVError.invalid("no audio in the data chunk") }

        var channels = [[Double]](repeating: [Double](repeating: 0, count: frameCount), count: channelCount)
        var position = data.lowerBound
        for i in 0..<frameCount {
            for c in 0..<channelCount {
                channels[c][i] = decode(position)
                position += stride
            }
        }
        return Audio(sampleRate: sampleRate, channels: channels)
    }

    public static func write(_ audio: Audio, to path: String) throws {
        let channelCount = audio.channels.count
        let frames = audio.frameCount
        let dataBytes = frames * channelCount * 4

        var out = ByteWriter(capacity: 58 + dataBytes)
        out.tag("RIFF"); out.u32(4 + (8 + 16) + (8 + 4) + (8 + dataBytes)); out.tag("WAVE")
        out.tag("fmt "); out.u32(16)
        out.u16(formatFloat)
        out.u16(channelCount)
        out.u32(audio.sampleRate)
        out.u32(audio.sampleRate * channelCount * 4)   // byte rate
        out.u16(channelCount * 4)                      // block align
        out.u16(32)
        out.tag("fact"); out.u32(4); out.u32(frames)   // required for non-PCM formats
        out.tag("data"); out.u32(dataBytes)
        for i in 0..<frames {
            for c in 0..<channelCount { out.u32(Int(Float(audio.channels[c][i]).bitPattern)) }
        }
        try Data(out.bytes).write(to: URL(fileURLWithPath: path))
    }

    /// Picks the per-sample decoder once, instead of switching on the format for every sample.
    private static func sampleDecoder(format: Int, bits: Int, bytes b: LittleEndianBytes) throws -> (Int) -> Double {
        switch (format, bits) {
        case (formatPCM, 16):
            return { Double(Int16(bitPattern: UInt16(b.u16($0)))) / 32_768 }
        case (formatPCM, 24):
            return { o in
                var v = b.u16(o) | (Int(b[o + 2]) << 16)
                if v & 0x80_0000 != 0 { v -= 0x100_0000 }
                return Double(v) / 8_388_608
            }
        case (formatPCM, 32):
            return { Double(Int32(bitPattern: UInt32(b.u32($0)))) / 2_147_483_648 }
        case (formatFloat, 32):
            return { Double(Float(bitPattern: UInt32(b.u32($0)))) }
        case (formatFloat, 64):
            return { o in Double(bitPattern: UInt64(b.u32(o)) | (UInt64(b.u32(o + 4)) << 32)) }
        default:
            throw WAVError.invalid("unsupported sample format \(format) at \(bits) bits")
        }
    }
}

private struct LittleEndianBytes {
    let storage: [UInt8]
    init(_ storage: [UInt8]) { self.storage = storage }

    var count: Int { storage.count }
    subscript(_ i: Int) -> UInt8 { storage[i] }
    func u16(_ o: Int) -> Int { Int(storage[o]) | (Int(storage[o + 1]) << 8) }
    func u32(_ o: Int) -> Int { u16(o) | (u16(o + 2) << 16) }
    func tag(_ o: Int) -> String { String(decoding: storage[o..<(o + 4)], as: UTF8.self) }
}

private struct ByteWriter {
    private(set) var bytes: [UInt8] = []
    init(capacity: Int) { bytes.reserveCapacity(capacity) }

    mutating func tag(_ s: String) { bytes.append(contentsOf: Array(s.utf8)) }
    mutating func u16(_ v: Int) {
        bytes.append(UInt8(truncatingIfNeeded: v))
        bytes.append(UInt8(truncatingIfNeeded: v >> 8))
    }
    mutating func u32(_ v: Int) {
        u16(v & 0xFFFF)
        u16((v >> 16) & 0xFFFF)
    }
}
