import Foundation
import AVFoundation

enum MicrophoneCaptureError: LocalizedError {
    case converterUnavailable

    var errorDescription: String? {
        "Could not set up microphone audio conversion."
    }
}

/// Captures the Mac's microphone input independently of AudioCapture's
/// system-audio stream, so the two can be sent to Gemini as separate,
/// explicitly-labeled tracks — letting it tell "you talking" apart from
/// "audio playing from the call" instead of guessing from voice alone.
/// Requires Microphone permission for this app in System Settings.
final class MicrophoneCapture: @unchecked Sendable {
    static let shared = MicrophoneCapture()

    /// Mirrors AudioCapture's cap: bound memory if flushes stop happening.
    private static let maxBufferedBytes = 20_000_000

    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "com.local.screenexplain.miccapture")
    private var pcmBuffer = Data()
    private var sampleRate: Double = 48000
    private var isRunning = false

    private init() {}

    func start() throws {
        guard !isRunning else { return }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: inputFormat.sampleRate, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw MicrophoneCaptureError.converterUnavailable
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * targetFormat.sampleRate / inputFormat.sampleRate) + 16
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

            var suppliedInput = false
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                if suppliedInput {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                suppliedInput = true
                outStatus.pointee = .haveData
                return buffer
            }

            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError, withInputFrom: inputBlock)
            guard status != .error, let channelData = outBuffer.int16ChannelData else { return }

            let frameLength = Int(outBuffer.frameLength)
            let data = Data(bytes: channelData[0], count: frameLength * MemoryLayout<Int16>.size)

            self.queue.async {
                self.sampleRate = targetFormat.sampleRate
                self.pcmBuffer.append(data)
                if self.pcmBuffer.count > Self.maxBufferedBytes {
                    self.pcmBuffer.removeFirst(self.pcmBuffer.count - Self.maxBufferedBytes)
                }
            }
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        queue.async { [weak self] in self?.pcmBuffer.removeAll() }
    }

    /// Returns whatever mic audio has buffered since the last flush as a WAV
    /// blob, or nil if nothing has been captured (including if not running).
    func flush() async -> Data? {
        await withCheckedContinuation { continuation in
            queue.async {
                guard !self.pcmBuffer.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                let wav = WAVEncoder.wrap(pcm: self.pcmBuffer, sampleRate: self.sampleRate, channels: 1)
                self.pcmBuffer.removeAll()
                continuation.resume(returning: wav)
            }
        }
    }
}
