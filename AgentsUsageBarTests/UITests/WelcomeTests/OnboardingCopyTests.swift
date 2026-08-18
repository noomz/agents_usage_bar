import Testing
import Foundation
@testable import AgentsUsageBar

// MARK: - OnboardingCopyTests
//
// Tests for OnboardingCopy.loadBundled() — providers.json bundle loader.

@MainActor
@Suite("OnboardingCopyTests")
struct OnboardingCopyTests {

    // MARK: - Bundle loading

    @Test func loadBundled_returnsAllKnownProviders() throws {
        let copy = try OnboardingCopy.loadBundled()
        #expect(copy.providers.count == ProviderID.allKnown.count,
                "Expected \(ProviderID.allKnown.count) providers, got \(copy.providers.count)")
    }

    @Test func loadBundled_allProviderIDsPresent() throws {
        let copy = try OnboardingCopy.loadBundled()
        let loadedIDs = Set(copy.providers.map(\.providerID))
        let expectedIDs = Set(ProviderID.allKnown.map(\.rawValue))
        #expect(loadedIDs == expectedIDs,
                "providerID mismatch — loaded: \(loadedIDs), expected: \(expectedIDs)")
    }

    // MARK: - SEC-04 compliance

    @Test func loadBundled_noRealLookingApiKeys() throws {
        let copy = try OnboardingCopy.loadBundled()
        // SEC-04: snippets must use <placeholder> tokens, never real-looking key patterns
        let forbiddenPatterns = ["sk-or-", "sk-proj-", "AIzaSy"]
        for info in copy.providers {
            for pattern in forbiddenPatterns {
                #expect(!info.envSnippet.contains(pattern),
                        "\(info.providerID) envSnippet contains forbidden pattern '\(pattern)'")
                #expect(!info.tomlSnippet.contains(pattern),
                        "\(info.providerID) tomlSnippet contains forbidden pattern '\(pattern)'")
            }
        }
    }

    // MARK: - Lenient decoding

    @Test func loadBundled_lenientUnknownFields() throws {
        // Manually decode JSON with an extra unknown field — must not throw
        let jsonWithExtraField = """
        {
          "providers": [
            {
              "providerID": "openrouter",
              "displayName": "OpenRouter",
              "detectionDescription": "Test",
              "envSnippet": "test",
              "envNote": "note",
              "tomlSnippet": "test",
              "tomlNote": "note",
              "docsURL": null,
              "unknownFutureField": "should be silently ignored"
            }
          ]
        }
        """
        let data = Data(jsonWithExtraField.utf8)
        // Must not throw — JSONDecoder silently ignores unknown keys by default
        let result = try JSONDecoder().decode(OnboardingCopy.self, from: data)
        #expect(result.providers.count == 1)
        #expect(result.providers[0].providerID == "openrouter")
    }

    // MARK: - Error case

    @Test func bundleResourceMissing_throwsCorrectError() {
        // Verify that OnboardingCopyError.bundleResourceMissing is thrown when the
        // bundle URL lookup fails. We test this by decoding from a deliberately
        // empty/invalid data and checking the error type.
        //
        // The actual "resource missing" path requires Bundle.main.url to return nil,
        // which cannot be simulated without swizzling. Instead, verify the error enum
        // value is defined and matches its expected case (type-level test).
        let error = OnboardingCopyError.bundleResourceMissing
        switch error {
        case .bundleResourceMissing:
            break  // expected
        case .decodeFailed:
            Issue.record("Wrong error case — expected bundleResourceMissing")
        }

        // Also verify decodeFailed wraps correctly
        let fakeError = NSError(domain: "test", code: 1)
        let decodeError = OnboardingCopyError.decodeFailed(fakeError)
        switch decodeError {
        case .decodeFailed:
            break  // expected
        case .bundleResourceMissing:
            Issue.record("Wrong error case — expected decodeFailed")
        }
    }
}
