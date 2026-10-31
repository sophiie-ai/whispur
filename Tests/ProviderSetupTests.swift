import XCTest
@testable import Whispur

/// In-memory stand-in for the Keychain so tests never touch real items.
final class InMemorySecretStore: SecretStore {
    var values: [KeychainKey: String] = [:]
    var failsWrites = false

    func get(_ key: KeychainKey) -> String? { values[key] }

    func set(_ key: KeychainKey, value: String) -> Bool {
        guard !failsWrites else { return false }
        values[key] = value
        return true
    }

    func delete(_ key: KeychainKey) -> Bool {
        values[key] = nil
        return true
    }
}

final class ProviderSetupTests: XCTestCase {

    // MARK: - Masking

    func testMaskShowsOnlyLastFourCharacters() {
        XCTAssertEqual(KeyMasking.masked("sk-proj-1234567890abcd"), "••••••••abcd")
        XCTAssertEqual(KeyMasking.masked("  gsk_abcdefghijklWXYZ \n"), "••••••••WXYZ")
    }

    func testMaskHidesShortValuesEntirely() {
        XCTAssertEqual(KeyMasking.masked("short-key"), "••••••••")
        XCTAssertEqual(KeyMasking.masked(""), "••••••••")
    }

    // MARK: - Commit rules

    func testCommittableValueTrimsAndSkipsEmptyOrUnchanged() {
        XCTAssertEqual(KeyEntryCommitPolicy.committableValue(draft: "  abc  ", stored: nil), "abc")
        XCTAssertNil(KeyEntryCommitPolicy.committableValue(draft: "   ", stored: nil))
        XCTAssertNil(KeyEntryCommitPolicy.committableValue(draft: "abc", stored: "abc"))
        XCTAssertEqual(KeyEntryCommitPolicy.committableValue(draft: "abd", stored: "abc"), "abd")
    }

    func testPasteDetectionIgnoresTyping() {
        XCTAssertFalse(KeyEntryCommitPolicy.isLikelyPaste(previous: "sk-", current: "sk-a"))
        XCTAssertFalse(KeyEntryCommitPolicy.isLikelyPaste(previous: "sk-abcdef", current: "sk-abcde"))
        XCTAssertTrue(KeyEntryCommitPolicy.isLikelyPaste(previous: "", current: "sk-1234567890"))
    }

    // MARK: - Status

    func testStatusDerivation() {
        XCTAssertEqual(ProviderSetupStatus.derive(requiredKeys: [], has: { _ in false }), .ready)
        XCTAssertEqual(ProviderSetupStatus.derive(requiredKeys: [.groqAPIKey], has: { _ in false }), .needsKey)
        XCTAssertEqual(ProviderSetupStatus.derive(requiredKeys: [.groqAPIKey], has: { _ in true }), .ready)
        XCTAssertEqual(
            ProviderSetupStatus.derive(requiredKeys: [.awsBedrockAPIKey, .awsRegion], has: { $0 == .awsBedrockAPIKey }),
            .needsRegion
        )
        XCTAssertEqual(
            ProviderSetupStatus.derive(requiredKeys: [.awsBedrockAPIKey, .awsRegion], has: { $0 == .awsRegion }),
            .needsKey
        )
    }

    func testReadinessNamesWhatIsMissing() {
        let incomplete = SettingsReadiness.derive(
            microphoneGranted: false,
            accessibilityGranted: true,
            speechProviderName: "Deepgram",
            speechStatus: .needsKey,
            cleanupProviderName: "Groq",
            cleanupStatus: .ready
        )
        XCTAssertEqual(incomplete.tone, .incomplete)
        XCTAssertEqual(incomplete.headline, "Setup incomplete")
        XCTAssertEqual(incomplete.detail, "Needs microphone access and Deepgram key.")

        let readyWithoutCleanup = SettingsReadiness.derive(
            microphoneGranted: true,
            accessibilityGranted: true,
            speechProviderName: "Apple (on-device)",
            speechStatus: .ready,
            cleanupProviderName: "Anthropic Claude",
            cleanupStatus: .needsKey
        )
        XCTAssertEqual(readyWithoutCleanup.tone, .ready)
        XCTAssertEqual(readyWithoutCleanup.detail, "Cleanup is off until Anthropic Claude has a key.")

        XCTAssertEqual(SettingsReadiness.listPhrase(["a", "b", "c"]), "a, b, and c")
    }

    func testUserFacingStringsHaveNoEmDashes() {
        let readiness = SettingsReadiness.derive(
            microphoneGranted: false, accessibilityGranted: false,
            speechProviderName: "X", speechStatus: .needsRegion,
            cleanupProviderName: "Y", cleanupStatus: .needsKey
        )
        var strings = [readiness.headline, readiness.detail]
        strings += SettingsTab.allCases.flatMap { [$0.rawValue, $0.summary] }
        strings += STTProviderID.allCases.map(\.setupDescriptor.note)
        strings += LLMProviderID.allCases.map(\.setupDescriptor.note)
        strings += KeychainKey.allCases.map(\.placeholder)
        for string in strings {
            XCTAssertFalse(string.contains("\u{2014}"), "Em dash in: \(string)")
        }
    }

    // MARK: - Credentials

    @MainActor
    func testCredentialsSaveMaskRemoveAndNotify() {
        let store = InMemorySecretStore()
        let credentials = ProviderCredentials(store: store)
        var changes = 0
        credentials.onChange = { changes += 1 }

        XCTAssertFalse(credentials.has(.openaiAPIKey))
        XCTAssertTrue(credentials.save(.openaiAPIKey, draft: " sk-proj-1234567890wxyz "))
        XCTAssertEqual(store.values[.openaiAPIKey], "sk-proj-1234567890wxyz")
        XCTAssertEqual(credentials.displayValue(.openaiAPIKey), "••••••••wxyz")
        XCTAssertEqual(changes, 1)

        XCTAssertFalse(credentials.save(.openaiAPIKey, draft: "sk-proj-1234567890wxyz"), "Unchanged value must not rewrite")
        XCTAssertEqual(changes, 1)

        credentials.remove(.openaiAPIKey)
        XCTAssertNil(store.values[.openaiAPIKey])
        XCTAssertFalse(credentials.has(.openaiAPIKey))
        XCTAssertEqual(changes, 2)
    }

    @MainActor
    func testRegionIsShownPlainAndFailedWritesReportFalse() {
        let store = InMemorySecretStore()
        let credentials = ProviderCredentials(store: store)
        XCTAssertTrue(credentials.save(.awsRegion, draft: "us-west-2"))
        XCTAssertEqual(credentials.displayValue(.awsRegion), "us-west-2")

        store.failsWrites = true
        XCTAssertFalse(credentials.save(.groqAPIKey, draft: "gsk_1234567890abcd"))
        XCTAssertFalse(credentials.has(.groqAPIKey))
    }

    // MARK: - Key checks

    func testKeyChecksAreReadOnlyGets() {
        let checks = STTProviderID.allCases.compactMap(ProviderKeyCheck.forSpeech)
            + LLMProviderID.allCases.compactMap(ProviderKeyCheck.forCleanup)
        XCTAssertEqual(checks.count, 7, "Apple and Bedrock have no key check")
        for check in checks {
            let request = check.makeRequest(secret: "secret", baseURLOverride: { _ in nil })
            XCTAssertEqual(request?.httpMethod, "GET", check.providerID)
            XCTAssertNil(request?.httpBody, check.providerID)
        }
        XCTAssertNil(ProviderKeyCheck.forSpeech(.apple))
        XCTAssertNil(ProviderKeyCheck.forCleanup(.bedrock))
    }

    func testKeyCheckEndpointsAndAuthHeaders() throws {
        let anthropic = try XCTUnwrap(ProviderKeyCheck.forCleanup(.anthropic)?.makeRequest(secret: "k", baseURLOverride: { _ in nil }))
        XCTAssertEqual(anthropic.url?.absoluteString, "https://api.anthropic.com/v1/models?limit=1")
        XCTAssertEqual(anthropic.value(forHTTPHeaderField: "x-api-key"), "k")
        XCTAssertNotNil(anthropic.value(forHTTPHeaderField: "anthropic-version"))

        let deepgram = try XCTUnwrap(ProviderKeyCheck.forSpeech(.deepgram)?.makeRequest(secret: "k", baseURLOverride: { _ in nil }))
        XCTAssertEqual(deepgram.url?.absoluteString, "https://api.deepgram.com/v1/projects")
        XCTAssertEqual(deepgram.value(forHTTPHeaderField: "Authorization"), "Token k")

        let elevenLabs = try XCTUnwrap(ProviderKeyCheck.forSpeech(.elevenlabs)?.makeRequest(secret: "k", baseURLOverride: { _ in nil }))
        XCTAssertEqual(elevenLabs.url?.absoluteString, "https://api.elevenlabs.io/v1/user")
        XCTAssertEqual(elevenLabs.value(forHTTPHeaderField: "xi-api-key"), "k")

        let groq = try XCTUnwrap(ProviderKeyCheck.forSpeech(.groqWhisper)?.makeRequest(secret: "k", baseURLOverride: { _ in nil }))
        XCTAssertEqual(groq.url?.absoluteString, "https://api.groq.com/openai/v1/models")
        XCTAssertEqual(groq.value(forHTTPHeaderField: "Authorization"), "Bearer k")
    }

    func testOpenAIKeyCheckFollowsTheSectionBaseURLOverride() throws {
        let overrides = ["openaiSTTBaseURL": "https://gateway.example.com/v1", "openaiLLMBaseURL": "https://llm.example.com/v1"]
        let stt = try XCTUnwrap(ProviderKeyCheck.forSpeech(.openai)?.makeRequest(secret: "k", baseURLOverride: { overrides[$0] }))
        XCTAssertEqual(stt.url?.absoluteString, "https://gateway.example.com/v1/models")
        let llm = try XCTUnwrap(ProviderKeyCheck.forCleanup(.openai)?.makeRequest(secret: "k", baseURLOverride: { overrides[$0] }))
        XCTAssertEqual(llm.url?.absoluteString, "https://llm.example.com/v1/models")
        let fallback = try XCTUnwrap(ProviderKeyCheck.forCleanup(.openai)?.makeRequest(secret: "k", baseURLOverride: { _ in nil }))
        XCTAssertEqual(fallback.url?.absoluteString, "https://api.openai.com/v1/models")
    }

    func testKeyCheckOutcomeUsesProviderMessage() {
        XCTAssertEqual(ProviderKeyCheck.outcome(statusCode: 200, providerMessage: nil, providerName: "Groq"), .passed("Groq accepted this key."))
        XCTAssertEqual(
            ProviderKeyCheck.outcome(statusCode: 401, providerMessage: "Invalid API Key", providerName: "Groq"),
            .failed("HTTP 401: Invalid API Key")
        )
        XCTAssertEqual(
            ProviderKeyCheck.outcome(statusCode: 403, providerMessage: "  ", providerName: "Groq"),
            .failed("HTTP 403: The provider rejected this key.")
        )
    }

    func testBaseURLNormalizationMatchesRegistry() {
        XCTAssertEqual(ProviderRegistry.normalizedBaseURL(" https://x.example.com/v1/ "), "https://x.example.com/v1")
        XCTAssertNil(ProviderRegistry.normalizedBaseURL("ftp://x.example.com"))
        XCTAssertNil(ProviderRegistry.normalizedBaseURL("   "))
    }
}
