import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreAudio

enum AudioCaptureError: LocalizedError {
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "No display available to capture audio from."
        }
    }
}

/// Captures system audio (whatever is playing on screen) via ScreenCaptureKit
/// and hands off fixed-length WAV chunks so they can be sent for live translation.
/// Requires Screen Recording permission for this app in System Settings.
final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    static let shared = AudioCapture()

    /// Above this many buffered bytes we auto-flush even in manual-push mode,
    /// so a forgotten push can't grow memory/cost unboundedly (~100s of audio).
    private static let maxBufferedBytes = 20_000_000

    private var stream: SCStream?
    private var chunkTimer: Timer?
    private let queue = DispatchQueue(label: "com.local.screenexplain.audiocapture")
    private var pcmBuffer = Data()
    private var sampleRate: Double = 48000
    private var channels: UInt32 = 2
    private var onChunk: ((Data) -> Void)?
    private var onStreamError: ((Error) -> Void)?

    /// When manualPushOnly is true, no timer is scheduled — audio keeps
    /// buffering until flushNow() is called (or the safety cap is hit).
    func start(chunkInterval: TimeInterval, manualPushOnly: Bool, onChunk: @escaping (Data) -> Void, onStreamError: @escaping (Error) -> Void) async throws {
        self.onChunk = onChunk
        self.onStreamError = onStreamError

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw AudioCaptureError.noDisplay }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream

        guard !manualPushOnly else { return }

        let timer = Timer.scheduledTimer(withTimeInterval: chunkInterval, repeats: true) { [weak self] _ in
            self?.flushChunk()
        }
        RunLoop.main.add(timer, forMode: .common)
        chunkTimer = timer
    }

    /// Immediately sends whatever audio has buffered since the last flush.
    /// Used for the manual-push hotkey/menu item.
    func flushNow() {
        flushChunk()
    }

    func stop() {
        chunkTimer?.invalidate()
        chunkTimer = nil
        onChunk = nil
        onStreamError = nil
        let activeStream = stream
        stream = nil
        queue.async { [weak self] in self?.pcmBuffer.removeAll() }
        Task { try? await activeStream?.stopCapture() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else { return }

        let asbd = asbdPointer.pointee
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer) == kCMBlockBufferNoErr,
              let dataPointer else { return }

        let floatData = Data(bytes: dataPointer, count: length)
        let sampleRate = asbd.mSampleRate
        let channels = asbd.mChannelsPerFrame

        queue.async { [weak self] in
            guard let self else { return }
            self.sampleRate = sampleRate
            self.channels = channels
            self.pcmBuffer.append(Self.convertFloat32ToInt16(floatData))
            if self.pcmBuffer.count > Self.maxBufferedBytes {
                self.flushChunk()
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStreamError?(error)
    }

    private static func convertFloat32ToInt16(_ data: Data) -> Data {
        let floatCount = data.count / MemoryLayout<Float32>.size
        var output = Data(capacity: floatCount * MemoryLayout<Int16>.size)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let floats = raw.bindMemory(to: Float32.self)
            for i in 0..<floatCount {
                let clamped = max(-1.0, min(1.0, floats[i]))
                var intVal = Int16(clamped * Float(Int16.max)).littleEndian
                withUnsafeBytes(of: &intVal) { output.append(contentsOf: $0) }
            }
        }
        return output
    }

    private func flushChunk() {
        queue.async { [weak self] in
            guard let self, !self.pcmBuffer.isEmpty else { return }
            let wav = Self.wrapWAV(pcm: self.pcmBuffer, sampleRate: self.sampleRate, channels: self.channels)
            self.pcmBuffer.removeAll()
            DispatchQueue.main.async { self.onChunk?(wav) }
        }
    }

    private static func wrapWAV(pcm: Data, sampleRate: Double, channels: UInt32) -> Data {
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
