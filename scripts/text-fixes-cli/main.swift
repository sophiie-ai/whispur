// Applies Whispur's deterministic text fixes (Sources/Pipeline/TextFixes.swift)
// to transcripts, so scripts/eval-cleanup.py can send cleanup the same text
// the app sends. Built by the eval with:
//
//   swiftc -O Sources/Pipeline/TextFixes.swift scripts/text-fixes-cli/main.swift -o <out>
//
// Reads one JSON object per line on stdin: {"input": "...", "style": "code"}.
// Writes one per line on stdout: {"text": "..."}. Every fix is on, with
// straight quotes for the "code" style, as in the app's defaults.
import Foundation

struct Request: Decodable {
    let input: String
    let style: String?
}

struct Response: Encodable {
    let text: String
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.withoutEscapingSlashes]
while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty else { continue }
    let request = try JSONDecoder().decode(Request.self, from: Data(line.utf8))
    var options = TextFixOptions()
    options.quoteStyle = request.style == "code" ? .straight : .curly
    let text = TextFixes.apply(request.input, options: options).trimmingCharacters(in: .whitespacesAndNewlines)
    let data = try encoder.encode(Response(text: text))
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}
