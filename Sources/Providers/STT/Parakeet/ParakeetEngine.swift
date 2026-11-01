import CoreML
import Darwin
import FluidAudio
import Foundation
import os

private let logger = Logger(subsystem: "ai.sophiie.whispur", category: "Parakeet")

/// The loaded Parakeet model, shared by every dictation.
///
/// Loading the Core ML bundles takes a second or two (much longer the very
/// first time, while macOS compiles them for the Neural Engine), so the
/// model is loaded once, kept resident while Parakeet is the speech
/// provider, and released when the user switches away or deletes it.
actor ParakeetEngine {
    static let shared = ParakeetEngine()

    /// What loading cost, for Settings.
    struct LoadReport: Equatable, Sendable {
        let seconds: Double
        /// Growth of Whispur's own memory footprint across the load. The
        /// Neural Engine keeps part of a compiled model in a system process,
        /// so this is the part Whispur is charged for, not the whole model.
        let footprintBytes: Int64
    }

    private var asr: AsrManager?
    private var loadedSpec: ParakeetModelSpec?
    private var loading: (spec: ParakeetModelSpec, task: Task<(AsrManager, LoadReport), Error>)?
    private(set) var lastLoad: LoadReport?

    var isLoaded: Bool { asr != nil }

    /// Loads the model if it isn't already. Concurrent callers share one load.
    @discardableResult
    func load(
        _ spec: ParakeetModelSpec,
        from modelsDirectory: URL = ParakeetModelLocation.modelsDirectory,
        priority: TaskPriority = .userInitiated
    ) async throws -> LoadReport? {
        if asr != nil, loadedSpec == spec { return lastLoad }
        if let loading, loading.spec == spec {
            _ = try await loading.task.value
            return lastLoad
        }
        await unload()

        let directory = ParakeetModelLocation.directory(for: spec, in: modelsDirectory)
        let task = Task(priority: priority) { () throws -> (AsrManager, LoadReport) in
            guard ParakeetModelLocation.isInstalled(spec, in: modelsDirectory) else {
                throw STTError.modelNotReady(provider: .parakeet, detail: ParakeetSTT.notDownloadedMessage)
            }
            let before = MemoryFootprint.current()
            let started = ContinuousClock.now
            // loadLocal never touches the network: a damaged cache fails here
            // instead of being wiped and silently downloaded again.
            let models = try AsrModels.loadLocal(from: directory, version: spec.version)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            let elapsed = started.duration(to: .now)
            let report = LoadReport(
                seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
                footprintBytes: max(0, MemoryFootprint.current() - before)
            )
            return (manager, report)
        }
        loading = (spec, task)
        do {
            let (manager, report) = try await task.value
            // A delete or a switch away during the load wins.
            guard loading?.spec == spec else {
                await manager.cleanup()
                return nil
            }
            asr = manager
            loadedSpec = spec
            lastLoad = report
            loading = nil
            logger.info("Loaded \(spec.displayName, privacy: .public) in \(report.seconds, format: .fixed(precision: 2)) s, footprint +\(report.footprintBytes / 1_000_000) MB")
            return report
        } catch {
            if loading?.spec == spec { loading = nil }
            logger.error("Loading \(spec.displayName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Transcribes a 16 kHz mono WAV, loading the model first when needed.
    func transcribe(
        fileURL: URL,
        spec: ParakeetModelSpec,
        language: Language?,
        modelsDirectory: URL = ParakeetModelLocation.modelsDirectory
    ) async throws -> ASRResult {
        try await load(spec, from: modelsDirectory)
        guard let asr else {
            throw STTError.modelNotReady(provider: .parakeet, detail: ParakeetSTT.notDownloadedMessage)
        }
        var samples = try AudioConverter().resampleAudioFile(fileURL)
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: 16_000)
        if samples.count < minimum {
            samples += [Float](repeating: 0, count: minimum - samples.count)
        }
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        return try await asr.transcribe(samples, decoderState: &state, language: language)
    }

    /// Releases the model. The next transcription loads it again.
    func unload() async {
        loading?.task.cancel()
        loading = nil
        if let asr { await asr.cleanup() }
        asr = nil
        loadedSpec = nil
    }
}

/// The process's physical memory footprint, the figure Activity Monitor
/// shows as "Memory".
enum MemoryFootprint {
    static func current() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }
}
