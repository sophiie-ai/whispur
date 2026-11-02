// Applies Whispur's deterministic text fixes (Sources/Pipeline/TextFixes.swift)
// and the dictionary's "heard as" plan (VocabularyAliases.swift, CommonWords.swift)
// to transcripts, so scripts/eval-cleanup.py can send cleanup the same text
// the app sends. Built by the eval with swiftc from those sources and this file.
//
// Reads one JSON object per line on stdin:
//   {"input": "...", "style": "code", "vocabulary": ["Whispur"],
//    "aliases": {"Whispur": ["Whisper"]}, "always_replace": ["Whispur"]}
// Writes one per line on stdout: {"text": "...", "heard_as": {"Whispur": ["Whisper"]},
// "replaced": ["Wispur"]}. Every fix is on, with straight quotes for the
// "code" style, as in the app's defaults.
import Foundation

struct Request: Decodable {
    let input: String
    let style: String?
    let vocabulary: [String]?
    let aliases: [String: [String]]?
    let always_replace: [String]?
}

struct Response: Encodable {
    let text: String
    let heard_as: [String: [String]]
    let replaced: [String]
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty else { continue }
    let request = try JSONDecoder().decode(Request.self, from: Data(line.utf8))
    let always = Set(request.always_replace ?? [])
    let entries = (request.aliases ?? [:]).sorted { $0.key < $1.key }.map {
        VocabularyAliasEntry(term: $0.key, aliases: $0.value, alwaysReplace: always.contains($0.key))
    }
    let plan = VocabularyAliasPlan.build(entries: entries, terms: request.vocabulary ?? [], isCommonWord: CommonWords.isCommon)
    var options = TextFixOptions()
    options.quoteStyle = request.style == "code" ? .straight : .curly
    options.vocabulary = plan.replacements
    let text = TextFixes.apply(request.input, options: options).trimmingCharacters(in: .whitespacesAndNewlines)
    let data = try encoder.encode(Response(text: text, heard_as: plan.heardAs, replaced: plan.replacements.map(\.phrase)))
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}
