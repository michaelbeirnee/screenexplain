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

/// Captures system audio (whatever is playing on screen — e.g. the other
/// side of a Zoom call) via ScreenCaptureKit. Buffers continuously; callers
/// pull WAV chunks out with flush() on whatever cadence they want (a timer,
/// a manual push, or paired with MicrophoneCapture for the same instant).
/// Requires Screen Recording permission for this app in System Settings.
final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let shared = AudioCapture()

    /// Above this many buffered bytes we drop the oldest audio, so a long
    /// gap between flushes can't grow memory unboundedly (~100s of audio).
    private static let maxBufferedBytes = 20_000_000

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "com.local.screenexplain.audiocapture")
    private var pcmBuffer = Data()
    private var sampleRate: Double = 48000
    private var channels: UInt32 = 2
    private var onStreamError: ((Error) -> Void)?

    private override init() {}

    func start(onStreamError: @escaping (Error) -> Void) async throws {
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
    }

    func stop() {
        onStreamError = nil
        let activeStream = stream
        stream = nil
        queue.async { [weak self] in self?.pcmBuffer.removeAll() }
        Task { try? await activeStream?.stopCapture() }
    }

    /// Returns whatever audio has buffered since the last flush as a WAV
    /// blob, or nil if nothing (or only silence) has been captured.
    func flush() async -> Data? {
        await withCheckedContinuation { continuation in
            queue.async {
                guard !self.pcmBuffer.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                let wav = WAVEncoder.wrap(pcm: self.pcmBuffer, sampleRate: self.sampleRate, channels: self.channels)
                self.pcmBuffer.removeAll()
                continuation.resume(returning: wav)
            }
        }
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
                self.pcmBuffer.removeFirst(self.pcmBuffer.count - Self.maxBufferedBytes)
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
}
