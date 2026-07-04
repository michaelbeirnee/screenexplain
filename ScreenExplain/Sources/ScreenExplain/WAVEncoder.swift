import Foundation

/// Wraps raw 16-bit PCM samples in a WAV header. Shared by the system-audio
/// and microphone capture pipelines so both can hand Gemini a playable file.
enum WAVEncoder {
    static func wrap(pcm: Data, sampleRate: Double, channels: UInt32) -> Data {
        let byteRate = UInt32(sampleRate) * channels * 2
        let blockAlign = UInt16(channels * 2)
        let dataSize = UInt32(pcm.count)
        let chunkSize = 36 + dataSize

        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        header.append(contentsOf: littleEndianBytes(of: chunkSize))
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.append(contentsOf: littleEndianBytes(of: UInt32(16)))
        header.append(contentsOf: littleEndianBytes(of: UInt16(1))) // PCM
        header.append(contentsOf: littleEndianBytes(of: UInt16(channels)))
        header.append(contentsOf: littleEndianBytes(of: UInt32(sampleRate)))
        header.append(contentsOf: littleEndianBytes(of: byteRate))
        header.append(contentsOf: littleEndianBytes(of: blockAlign))
        header.append(contentsOf: littleEndianBytes(of: UInt16(16)))
        header.append(contentsOf: "data".utf8)
        header.append(contentsOf: littleEndianBytes(of: dataSize))

        return header + pcm
    }

    private static func littleEndianBytes<T: FixedWidthInteger>(of value: T) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }
}
