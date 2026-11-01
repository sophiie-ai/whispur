import XCTest
@testable import Whispur

@MainActor
final class MyEvalCasesTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("whispur-evalcases-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    private var fileURL: URL { scratch.appendingPathComponent("Whispur/MyEvalCases.jsonl") }

    private func sample(
        input: String = "um send it friday",
        expected: String = "Send it Friday.",
        vocabulary: [String] = [],
        tags: [MyEvalCase.Tag] = []
    ) -> MyEvalCase {
        MyEvalCase(id: "mine-20261102-101500-abcdef12", input: input, expected: expected, vocabulary: vocabulary, tags: tags)
    }

    private func parse(_ line: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    // MARK: - Schema

    func testLineMatchesTheEvalCaseFields() throws {
        let line = try sample(vocabulary: ["Sophiie", "  ", "Whispur"], tags: [.correction, .names]).jsonLine()
        XCTAssertEqual(
            line,
            #"{"id": "mine-20261102-101500-abcdef12", "split": "mine", "input": "um send it friday", "vocabulary": ["Sophiie", "Whispur"], "expected": "Send it Friday.", "tags": ["corrections", "names"], "critical": false}"#
        )
        let object = try parse(line)
        XCTAssertEqual(object["split"] as? String, "mine")
        XCTAssertEqual(object["critical"] as? Bool, false)
    }

    func testVocabularyIsLeftOutWhenEmpty() throws {
        let object = try parse(try sample(vocabulary: [" "]).jsonLine())
        XCTAssertNil(object["vocabulary"])
        XCTAssertEqual(object["tags"] as? [String], [])
    }

    /// Every field written exists in the repo's eval set with the same JSON
    /// type, so the runner reads a marked case like its own.
    func testFieldsAndTypesExistInTheRepoEvalSet() throws {
        let casesURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Evals/cleanup/cases.jsonl")
        let text = try String(contentsOf: casesURL, encoding: .utf8)
        var types: [String: Set<String>] = [:]
        var tags = Set<String>()
        for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let object = try parse(String(line))
            for (key, value) in object { types[key, default: []].insert(Self.kind(value)) }
            tags.formUnion(object["tags"] as? [String] ?? [])
        }
        XCTAssertFalse(types.isEmpty, "Known-positive control: the eval set was read")

        let mine = try parse(try sample(vocabulary: ["Sophiie"], tags: MyEvalCase.Tag.allCases).jsonLine())
        for (key, value) in mine {
            let known = try XCTUnwrap(types[key], "\(key) is not an eval-case field")
            XCTAssertTrue(known.contains(Self.kind(value)), "\(key) has a different type in the eval set")
        }
        for required in ["id", "split", "input", "expected", "tags", "critical"] {
            XCTAssertNotNil(mine[required], "missing \(required)")
        }
        // The tags that have an eval-set equivalent use its spelling.
        for tag in [MyEvalCase.Tag.correction, .list, .email] {
            XCTAssertTrue(tags.contains(tag.evalTag), tag.evalTag)
        }
    }

    private static func kind(_ value: Any) -> String {
        if value is String { return "string" }
        if let number = value as? NSNumber { return CFGetTypeID(number) == CFBooleanGetTypeID() ? "bool" : "number" }
        if value is [Any] { return "array" }
        return "other"
    }

    // MARK: - Escaping

    func testEscapingRoundTripsAndStaysOnOneLine() throws {
        let tricky = "She said \"ship it\" \\ then\nnew line\ttab \u{2028}sep\u{2029}para \u{85}nel mañana 🚀 </dictation-to-clean> a/b"
        let line = try sample(input: tricky, expected: tricky, vocabulary: [tricky]).jsonLine()
        XCTAssertEqual(line.components(separatedBy: .newlines).count, 1, "One physical line, also for Python's splitlines()")
        let object = try parse(line)
        XCTAssertEqual(object["input"] as? String, tricky)
        XCTAssertEqual(object["expected"] as? String, tricky)
        XCTAssertEqual(object["vocabulary"] as? [String], [tricky])
        XCTAssertTrue(line.contains("a/b"), "Slashes are not escaped")
        XCTAssertTrue(line.contains("mañana 🚀"), "UTF-8 is written as is, like cases.jsonl")
    }

    // MARK: - Appending

    func testAppendCreatesAPrivateFileAndAddsOneLinePerCase() throws {
        let store = MyEvalCaseStore(fileURL: fileURL)
        let first = UUID()
        XCTAssertFalse(store.isMarked(first))
        XCTAssertTrue(store.append(MyEvalCase(id: MyEvalCase.makeID(dictationID: first, at: Date()), input: "a", expected: "A.", vocabulary: [], tags: [])))
        XCTAssertTrue(store.append(sample()))

        let text = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(text.hasSuffix("\n"))
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(try parse(String(lines[0]))["input"] as? String, "a")
        XCTAssertEqual(try parse(String(lines[1]))["input"] as? String, "um send it friday")

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        XCTAssertTrue(store.isMarked(first))
        XCTAssertTrue(MyEvalCaseStore(fileURL: fileURL).isMarked(first), "Marked state survives a relaunch")
    }

    func testAppendStartsANewLineWhenTheFileLacksATrailingNewline() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"id": "hand-edited", "split": "mine", "input": "x", "expected": "X", "tags": [], "critical": false}"#.utf8).write(to: fileURL)
        let store = MyEvalCaseStore(fileURL: fileURL)
        XCTAssertTrue(store.append(sample()))
        let lines = try String(contentsOf: fileURL, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(try parse(String(lines[0]))["id"] as? String, "hand-edited")
        XCTAssertEqual(try parse(String(lines[1]))["split"] as? String, "mine")
    }

    func testIDsCarryTheDictationKey() {
        let id = UUID(uuidString: "ABCDEF12-0000-0000-0000-000000000000")!
        let caseID = MyEvalCase.makeID(dictationID: id, at: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(caseID, "mine-19700101-000000-abcdef12")
        XCTAssertEqual(MyEvalCase.dictationKey(fromCaseID: caseID), MyEvalCase.dictationKey(id))
        XCTAssertNil(MyEvalCase.dictationKey(fromCaseID: "answer-question"))
    }
}
