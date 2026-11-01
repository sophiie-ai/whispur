import AVFoundation
import Foundation

/// Converts live tap buffers to 16-bit little-endian mono PCM at a fixed
/// rate for streaming. Not thread-safe: call it from the audio tap only.
final class LivePCMConverter {
    let targetSampleRate: Double

    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private let outputFormat: AVAudioFormat?

    init(targetSampleRate: Double) {
        self.targetSampleRate = targetSampleRate
        outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: true
        )
    }

    /// The converted bytes, or empty data when the buffer can't be converted.
    func convert(_ buffer: AVAudioPCMBuffer) -> Data {
        guard buffer.frameLength > 0, let outputFormat else { return Data() }

        if sourceFormat != buffer.format {
            sourceFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            converter?.sampleRateConverterQuality = AVAudioQuality.medium.rawValue
        }
        guard let converter else { return Data() }

        let capacity = AVAudioFrameCount(
            ceil(Double(buffer.frameLength) * targetSampleRate / buffer.format.sampleRate)
        ) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return Data() }

        // The converter is reused across buffers so the resampler keeps its
        // state between them; `.noDataNow` (not end of stream) keeps it open.
        // The resampler holds back ~15 ms that is never flushed, which is
        // below anything a word can hide in.
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, output.frameLength > 0,
              let samples = output.int16ChannelData?[0]
        else { return Data() }

        return Data(bytes: samples, count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }
}
