import FluidAudio
import Foundation

/// The Parakeet model Whispur downloads and runs.
///
/// One multilingual model for everyone: Parakeet Ultra, Moondream's
/// post-training of NVIDIA's Parakeet TDT 0.6B v3. It covers the same 25
/// European languages as v3, is more accurate than v3 in all of them, and
/// runs at the same speed on the Neural Engine. English-only Parakeet v2 was
/// measured against it on the same clips and gave no accuracy gain worth a
/// second download and a model switch when the languages change.
struct ParakeetModelSpec: Equatable {
    let version: AsrModelVersion
    /// Hugging Face repository the weights come from.
    let repository: String
    /// Approximate download size, shown before the user downloads.
    let downloadBytes: Int64
    let displayName: String
    let license: String
    let attribution: String

    static let ultra = ParakeetModelSpec(
        version: .ultra,
        repository: "FluidInference/parakeet-ultra-coreml",
        downloadBytes: 632_000_000,
        displayName: "Parakeet Ultra",
        license: "CC BY 4.0",
        attribution: "Parakeet Ultra by Moondream, a post-training of NVIDIA Parakeet TDT 0.6B v3, converted to Core ML by FluidInference."
    )

    /// The model Whispur uses.
    static let current = ultra

    /// Folder name under the models directory. FluidAudio's downloader
    /// always writes to `<parent>/<its folder name>` whatever directory it is
    /// handed, and its loaders read from there, so take the name from it.
    var folderName: String {
        AsrModels.defaultCacheDirectory(for: version).lastPathComponent
    }

    var sourceURL: URL {
        URL(string: "https://huggingface.co/\(repository)")!
    }
}

/// Where Whispur keeps downloaded speech models.
enum ParakeetModelLocation {
    /// `~/Library/Application Support/Whispur/Models`.
    static var modelsDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support
            .appendingPathComponent("Whispur", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    static func directory(for spec: ParakeetModelSpec, in modelsDirectory: URL = modelsDirectory) -> URL {
        modelsDirectory.appendingPathComponent(spec.folderName, isDirectory: true)
    }

    /// Every file the model needs is on disk.
    static func isInstalled(_ spec: ParakeetModelSpec, in modelsDirectory: URL = modelsDirectory) -> Bool {
        AsrModels.modelsExist(at: directory(for: spec, in: modelsDirectory), version: spec.version)
    }

    /// Bytes on disk under the model's folder, including partial downloads.
    static func bytesOnDisk(_ spec: ParakeetModelSpec, in modelsDirectory: URL = modelsDirectory) -> Int64 {
        let root = directory(for: spec, in: modelsDirectory)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

/// Parakeet and the user's "Languages I speak".
///
/// Parakeet has no language parameter: it detects the language itself. What
/// it does take is a script hint. With one, the decoder skips tokens in
/// the wrong alphabet (Cyrillic letters in a Spanish clip, say), which is
/// the failure the script guard otherwise has to catch after the fact.
enum ParakeetLanguages {
    /// ISO-639-1 codes the multilingual model was trained on.
    static let supported: Set<String> = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
        "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
    ]

    /// The user's languages Parakeet doesn't cover, in order.
    static func unsupported(in selection: STTLanguageSelection) -> [String] {
        selection.isoCodes.filter { !supported.contains($0) }
    }

    /// The script hint for a selection, or nil to let the model decide.
    ///
    /// One language passes that language: French also gets FluidAudio's
    /// filter against English words leaking into French. Several languages
    /// that share an alphabet pass a stand-in for that alphabet (English for
    /// Latin, Russian for Cyrillic, Greek for Greek), which filters by script and nothing
    /// else. Mixed alphabets, auto-detect, or a language FluidAudio doesn't
    /// know get no hint.
    static func hint(for selection: STTLanguageSelection) -> Language? {
        if let single = selection.singleISOCode {
            return Language(rawValue: single)
        }
        guard selection.isMultilingual else { return nil }
        let languages = selection.isoCodes.map { Language(rawValue: $0) }
        guard languages.allSatisfy({ $0 != nil }) else { return nil }
        let scripts = Set(languages.compactMap { $0?.script })
        guard scripts.count == 1, let script = scripts.first else { return nil }
        switch script {
        case .latin: return .english
        case .cyrillic: return .russian
        case .greek: return .greek
        }
    }
}
