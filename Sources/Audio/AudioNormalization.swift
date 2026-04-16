import AVFoundation
import Foundation
import os

private let logger = Logger(subsystem: "ai.sophiie.whispur", category: "AudioNormalization")

/// Converts captured audio into the STT-friendly `16 kHz / mono / WAV` format.
enum AudioNormalization {
    static let targetSampleRate: Double = 16_000
    static let targetChannels: AVAudioChannelCount = 1

    static func normalize(_ inputURL: URL) throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")

        try writePreferredAudioCopy(from: inputURL, to: outputURL)
        return outputURL
    }

    static func writePreferredAudioCopy(from sourceURL: URL, to outputURL: URL) throws {
        let inputFile = try AVAudioFile(forReading: sourceURL)
        let inputFormat = inputFile.processingFormat

        guard inputFile.length > 0 else {
            throw AudioNormalizationError.preparationFailed("Recorded audio file is empty.")
        }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: true
        ) else {
            throw AudioNormalizationError.preparationFailed("Could not create the normalized output format.")
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioNormalizationError.preparationFailed("Could not create the audio converter.")
        }

        converter.sampleRateConverterQuality = AVAudioQuality.medium.rawValue

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: targetChannels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: outputSettings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )

        let inputFrameCapacity: AVAudioFrameCount = 4096
        let outputFrameCapacity = AVAudioFrameCount(
            ceil(Double(inputFrameCapacity) * outputFormat.sampleRate / inputFormat.sampleRate)
        ) + 64

        var reachedEndOfInput = false
        var readError: Error?
        var conversionError: NSError?

        // Reuse the same input and output buffers for every convert iteration
        // — allocating fresh AVAudioPCMBuffers each loop shows up in profiles
        // on long recordings. Their underlying storage is filled in-place by
        // the converter / file reader, so reuse is safe.
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            throw AudioNormalizationError.preparationFailed("Could not allocate the normalized audio buffer.")
        }

        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: inputFrameCapacity
        ) else {
            throw AudioNormalizationError.preparationFailed("Could not allocate the source audio buffer.")
        }

        while true {
            // Reset output buffer for the new conversion pass.
            outputBuffer.frameLength = 0

            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                if reachedEndOfInput {
                    outStatus.pointee = .endOfStream
                    return nil
                }

                let remainingFrames = inputFile.length - inputFile.framePosition
                guard remainingFrames > 0 else {
                    reachedEndOfInput = true
                    outStatus.pointee = .endOfStream
                    return nil
                }

                let framesToRead = AVAudioFrameCount(min(Int64(inputFrameCapacity), remainingFrames))

                do {
                    try inputFile.read(into: inputBuffer, frameCount: framesToRead)
                } catch {
                    readError = error
                    outStatus.pointee = .noDataNow
                    return nil
                }

                if inputBuffer.frameLength == 0 {
                    reachedEndOfInput = true
                    outStatus.pointee = .endOfStream
                    return nil
                }

                outStatus.pointee = .haveData
                return inputBuffer
            }

            if let readError {
                throw AudioNormalizationError.preparationFailed(readError.localizedDescription)
            }

            if let conversionError {
                throw AudioNormalizationError.preparationFailed(conversionError.localizedDescription)
            }

            switch status {
            case .haveData:
                try outputFile.write(from: outputBuffer)
            case .inputRanDry:
                continue
            case .endOfStream:
                if outputBuffer.frameLength > 0 {
                    try outputFile.write(from: outputBuffer)
                }

                logger.info(
                    "Normalized audio from \(inputFormat.sampleRate, privacy: .public) Hz / \(inputFormat.channelCount, privacy: .public) ch to 16000 Hz mono"
                )
                return
            case .error:
                throw AudioNormalizationError.preparationFailed("Audio conversion failed.")
            @unknown default:
                throw AudioNormalizationError.preparationFailed("Audio conversion returned an unknown status.")
            }
        }
    }
}

enum AudioNormalizationError: LocalizedError {
    case preparationFailed(String)

    var errorDescription: String? {
        switch self {
        case .preparationFailed(let message):
            return message
        }
    }
}
