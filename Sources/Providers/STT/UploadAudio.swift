import AVFoundation
import Foundation
import os

private let logger = Logger(subsystem: "ai.sophiie.whispur", category: "UploadAudio")

/// A recording as it is sent to a cloud speech provider.
///
/// Providers that accept FLAC get the 16 kHz WAV re-encoded as FLAC:
/// lossless, so the provider hears exactly the same samples, at roughly half
/// the bytes. On a slow cellular uplink that halves the time a dictation's
/// upload is exposed to a dropped connection. Everything on this Mac
/// (Parakeet, Apple, the kept failed-audio copy) keeps using the WAV.
struct UploadAudio: Equatable {
    let data: Data
    let filename: String
    let mimeType: String

    /// Providers documented to accept FLAC uploads. Meta Muse takes WAV only.
    static let flacProviders: Set<STTProviderID> = [.openai, .groqWhisper, .deepgram, .elevenlabs, .mistral]

    /// Providers that rejected a FLAC upload this session; they get WAV
    /// until the app restarts.
    private static let rejected = OSAllocatedUnfairLock(initialState: Set<STTProviderID>())

    /// Whether `provider` is sent FLAC right now.
    static func sendsFLAC(to provider: STTProviderID) -> Bool {
        flacProviders.contains(provider) && !rejected.withLock { $0.contains(provider) }
    }

    /// Sends `provider` WAV for the rest of the session.
    static func markFLACRejected(by provider: STTProviderID) {
        logger.notice("\(provider.rawValue, privacy: .public) rejected a FLAC upload; sending WAV from now on")
        _ = rejected.withLock { $0.insert(provider) }
    }

    /// Lets `provider` get FLAC again (when re-sending WAV didn't help, the
    /// format wasn't the problem).
    static func clearFLACRejection(for provider: STTProviderID) {
        _ = rejected.withLock { $0.remove(provider) }
    }

    /// The upload for `wavURL`: FLAC for a provider that takes it, when it
    /// encodes and comes out smaller; the WAV otherwise.
    static func load(_ wavURL: URL, for provider: STTProviderID) throws -> UploadAudio {
        if sendsFLAC(to: provider), let flac = FLACEncoding.encode(wavURL: wavURL) {
            return UploadAudio(data: flac, filename: "audio.flac", mimeType: "audio/flac")
        }
        return UploadAudio(data: try Data(contentsOf: wavURL), filename: "audio.wav", mimeType: "audio/wav")
    }
}

/// Lossless re-encoding of a PCM recording as FLAC with AVFoundation.
enum FLACEncoding {
    /// FLAC bytes for the audio in `wavURL`, or nil when encoding fails or
    /// saves nothing. ~30 ms for a minute of 16 kHz mono on Apple silicon.
    static func encode(wavURL: URL) -> Data? {
        let flacURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("flac")
        defer { try? FileManager.default.removeItem(at: flacURL) }
        do {
            try write(wavURL: wavURL, to: flacURL)
            let flac = try Data(contentsOf: flacURL)
            let wavSize = (try? wavURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
            guard !flac.isEmpty, flac.count < wavSize else { return nil }
            return flac
        } catch {
            logger.error("FLAC encoding failed, sending WAV: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Writes the FLAC file. Its own scope, because AVAudioFile only
    /// finalizes the FLAC stream when it is released.
    private static func write(wavURL: URL, to flacURL: URL) throws {
        let input = try AVAudioFile(forReading: wavURL, commonFormat: .pcmFormatInt16, interleaved: true)
        let format = input.processingFormat
        guard input.length > 0 else { throw STTError.noAudioFile }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitDepthHintKey: 16,
        ]
        let output = try AVAudioFile(forWriting: flacURL, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192) else {
            throw STTError.invalidAudioFormat
        }
        while input.framePosition < input.length {
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
        }
    }
}
