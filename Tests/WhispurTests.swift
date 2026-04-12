import XCTest

final class WhispurTests: XCTestCase {
    func testProviderIDsAreUnique() {
        // Ensure no duplicate raw values across provider IDs
        let sttRawValues = STTProviderID.allCases.map(\.rawValue)
        XCTAssertEqual(sttRawValues.count, Set(sttRawValues).count, "Duplicate STT provider IDs")

        let llmRawValues = LLMProviderID.allCases.map(\.rawValue)
        XCTAssertEqual(llmRawValues.count, Set(llmRawValues).count, "Duplicate LLM provider IDs")
    }

    func testKeychainKeys() {
        // All provider IDs that require keys should have at least one keychain key
        for provider in STTProviderID.allCases where provider.requiresAPIKey {
            XCTAssertFalse(provider.keychainKeys.isEmpty, "\(provider) requires API key but has no keychain keys")
        }
    }
}
