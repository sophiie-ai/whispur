import XCTest
@testable import Whispur

final class WhispurTests: XCTestCase {

    // MARK: - Provider IDs

    func testProviderIDsAreUnique() {
        let sttRawValues = STTProviderID.allCases.map(\.rawValue)
        XCTAssertEqual(sttRawValues.count, Set(sttRawValues).count, "Duplicate STT provider IDs")

        let llmRawValues = LLMProviderID.allCases.map(\.rawValue)
        XCTAssertEqual(llmRawValues.count, Set(llmRawValues).count, "Duplicate LLM provider IDs")
    }

    func testKeychainKeys() {
        for provider in STTProviderID.allCases where provider.requiresAPIKey {
            XCTAssertFalse(provider.keychainKeys.isEmpty, "\(provider) requires API key but has no keychain keys")
        }
    }

    // MARK: - ShortcutBinding storage round-trip

    func testShortcutBindingStorageRoundTrip() {
        let cases: [ShortcutBinding] = [
            .fnKey, .commandFn, .rightOption, .controlSpace, .optionSpace, .commandShiftSpace, .f5,
        ]
        for binding in cases {
            let storage = binding.storageValue
            let decoded = ShortcutBinding(storageValue: storage)
            XCTAssertEqual(decoded, binding, "Round-trip failed for \(binding.menuTitle): \(storage)")
        }
    }

    func testShortcutBindingRejectsInvalidStorage() {
        XCTAssertNil(ShortcutBinding(storageValue: ""))
        XCTAssertNil(ShortcutBinding(storageValue: "garbage"))
        XCTAssertNil(ShortcutBinding(storageValue: "abc:def"))
        XCTAssertNil(ShortcutBinding(storageValue: "1:notanumber"))
    }

    func testShortcutBindingDisplayNameIncludesModifiers() {
        XCTAssertTrue(ShortcutBinding.commandFn.displayName.contains("fn"))
        XCTAssertTrue(ShortcutBinding.commandFn.displayName.contains("\u{2318}"))
        XCTAssertTrue(ShortcutBinding.controlSpace.displayName.contains("^"))
        XCTAssertTrue(ShortcutBinding.controlSpace.displayName.contains("Space"))
    }

    // MARK: - RequestsStatusFilter

    func testProviderRequestStatusFilterMatchesByStatusCode() {
        let success = makeEntry(statusCode: 200)
        let clientError = makeEntry(statusCode: 404)
        let serverError = makeEntry(statusCode: 500)
        let transport = makeEntry(statusCode: nil, errorMessage: "timeout")

        XCTAssertTrue(ProviderRequestStatusFilter.all.matches(success))
        XCTAssertTrue(ProviderRequestStatusFilter.all.matches(transport))

        XCTAssertTrue(ProviderRequestStatusFilter.success.matches(success))
        XCTAssertFalse(ProviderRequestStatusFilter.success.matches(clientError))
        XCTAssertFalse(ProviderRequestStatusFilter.success.matches(transport))

        XCTAssertTrue(ProviderRequestStatusFilter.clientError.matches(clientError))
        XCTAssertFalse(ProviderRequestStatusFilter.clientError.matches(serverError))

        XCTAssertTrue(ProviderRequestStatusFilter.serverError.matches(serverError))
        XCTAssertFalse(ProviderRequestStatusFilter.serverError.matches(clientError))

        XCTAssertTrue(ProviderRequestStatusFilter.transport.matches(transport))
        XCTAssertFalse(ProviderRequestStatusFilter.transport.matches(success))
    }

    // MARK: - Error descriptions

    func testLLMErrorDescriptionsIncludeProviderName() {
        let apiError = LLMError.apiError(provider: .anthropic, message: "boom", statusCode: 500)
        XCTAssertTrue(apiError.errorDescription?.contains("Anthropic") ?? false)
        XCTAssertTrue(apiError.errorDescription?.contains("500") ?? false)

        let timeoutErr = LLMError.timeout(provider: .openai)
        XCTAssertTrue(timeoutErr.errorDescription?.contains("OpenAI") ?? false)
        XCTAssertTrue(timeoutErr.errorDescription?.lowercased().contains("timed out") ?? false)

        let rateLimit = LLMError.rateLimited(provider: .groq, retryAfter: 42)
        XCTAssertTrue(rateLimit.errorDescription?.contains("Groq") ?? false)
        XCTAssertTrue(rateLimit.errorDescription?.contains("42") ?? false)
    }

    func testSTTErrorDescriptionsIncludeProviderName() {
        let apiError = STTError.apiError(provider: .elevenlabs, message: "nope", statusCode: 400)
        XCTAssertTrue(apiError.errorDescription?.contains("ElevenLabs") ?? false)
        XCTAssertTrue(apiError.errorDescription?.contains("400") ?? false)

        let missingKey = STTError.missingAPIKey(provider: .deepgram)
        XCTAssertTrue(missingKey.errorDescription?.contains("Deepgram") ?? false)
    }

    // MARK: - ShortcutModifiers from CGEventFlags

    func testShortcutModifiersFromCGEventFlags() {
        let flags: CGEventFlags = [.maskCommand, .maskShift]
        let mods = ShortcutModifiers(flags: flags)
        XCTAssertTrue(mods.contains(.command))
        XCTAssertTrue(mods.contains(.shift))
        XCTAssertFalse(mods.contains(.option))
        XCTAssertFalse(mods.contains(.control))
        XCTAssertFalse(mods.contains(.function))
    }

    // MARK: - STTLanguageSelection

    func testSTTLanguageSelectionStorageRoundTrip() {
        XCTAssertEqual(STTLanguageSelection(storageValue: "").storageValue, "")
        XCTAssertEqual(STTLanguageSelection(storageValue: "en-US").storageValue, "en-US")
        XCTAssertEqual(STTLanguageSelection(storageValue: "  ").storageValue, "")
        if case .single(let code) = STTLanguageSelection(storageValue: "es-MX") {
            XCTAssertEqual(code, "es-MX")
        } else {
            XCTFail("Expected .single")
        }
        if case .auto = STTLanguageSelection(storageValue: "") { } else {
            XCTFail("Expected .auto")
        }
    }

    func testSTTLanguageResolverISO639_1() {
        XCTAssertNil(STTLanguageResolver.iso639_1(for: .auto))
        XCTAssertEqual(STTLanguageResolver.iso639_1(for: .single(code: "en-US")), "en")
        XCTAssertEqual(STTLanguageResolver.iso639_1(for: .single(code: "es-MX")), "es")
        XCTAssertEqual(STTLanguageResolver.iso639_1(for: .single(code: "zh")), "zh")
    }

    func testSTTLanguageResolverDeepgramMapsAutoToMulti() {
        if case .multi = STTLanguageResolver.deepgram(for: .auto) { } else {
            XCTFail("Expected .multi for .auto")
        }
        if case .single(let code) = STTLanguageResolver.deepgram(for: .single(code: "fr-FR")) {
            XCTAssertEqual(code, "fr-FR")
        } else {
            XCTFail("Expected .single passthrough")
        }
    }

    func testSTTLanguageResolverAppleLocaleForAutoIsNonEmpty() {
        let locale = STTLanguageResolver.appleLocale(for: .auto)
        XCTAssertFalse(locale.isEmpty)
    }

    func testSTTLanguageResolverAppleLocalePassesSingleThrough() {
        XCTAssertEqual(STTLanguageResolver.appleLocale(for: .single(code: "ja-JP")), "ja-JP")
    }

    // MARK: - Helpers

    private func makeEntry(statusCode: Int?, errorMessage: String? = nil) -> ProviderRequestLogEntry {
        ProviderRequestLogEntry(
            id: UUID(),
            timestamp: Date(),
            providerID: "openai",
            kind: .stt,
            endpointURL: "https://example.test/v1/x",
            httpMethod: "POST",
            statusCode: statusCode,
            durationMS: 123,
            requestSummary: "summary",
            responseBodyPreview: "preview",
            errorMessage: errorMessage
        )
    }
}
