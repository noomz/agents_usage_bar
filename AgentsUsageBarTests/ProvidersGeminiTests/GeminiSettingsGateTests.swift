import Testing
import Foundation
@testable import AgentsUsageBar

// MARK: - GeminiSettingsGateTests
//
// Plan 03-05 Task 1 — RESEARCH correction #2 lock-in tests.
//
// The settings keypath is `security.auth.selectedType` (NESTED), NOT the flat
// `selectedAuthType` that CONTEXT.md / REQUIREMENTS.md described. Case 8 below
// is the **regression-guard** that ensures we never silently fall back to the
// flat shape.

@Suite("GeminiSettingsGateTests", .serialized)
struct GeminiSettingsGateTests {

    // MARK: - Fixture helpers

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }

    private func writeTempSettings(_ json: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemini-settings-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("settings.json")
        try json.data(using: .utf8)!.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Test 1: oauth-personal fixture → true

    @Test func oauthPersonalFixture_returnsTrue() {
        let url = fixtureURL("gemini-settings-fixture.json")
        #expect(GeminiSettingsGate.isOAuthPersonal(settingsPath: url) == true)
    }

    // MARK: - Test 2: api-key fixture → false

    @Test func apiKeyFixture_returnsFalse() {
        let url = fixtureURL("gemini-settings-other-auth.json")
        #expect(GeminiSettingsGate.isOAuthPersonal(settingsPath: url) == false)
    }

    // MARK: - Test 3: missing file → false (no throw)

    @Test func missingFile_returnsFalse() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nonexistent-gemini-\(UUID().uuidString).json")
        #expect(GeminiSettingsGate.isOAuthPersonal(settingsPath: url) == false)
    }

    // MARK: - Test 4: malformed JSON → false

    @Test func malformedJSON_returnsFalse() throws {
        let url = try writeTempSettings("{ not even json ::::")
        #expect(GeminiSettingsGate.isOAuthPersonal(settingsPath: url) == false)
    }

    // MARK: - Test 5: missing `security` → false

    @Test func missingSecurityKey_returnsFalse() throws {
        let url = try writeTempSettings(#"{ "unrelated": true }"#)
        #expect(GeminiSettingsGate.isOAuthPersonal(settingsPath: url) == false)
    }

    // MARK: - Test 6: has `security` but missing `auth` → false

    @Test func missingAuthKey_returnsFalse() throws {
        let url = try writeTempSettings(#"{ "security": { "other": "x" } }"#)
        #expect(GeminiSettingsGate.isOAuthPersonal(settingsPath: url) == false)
    }

    // MARK: - Test 7: selectedType not a string (integer) → false

    @Test func selectedTypeNonString_returnsFalse() throws {
        let url = try writeTempSettings(#"{ "security": { "auth": { "selectedType": 7 } } }"#)
        #expect(GeminiSettingsGate.isOAuthPersonal(settingsPath: url) == false)
    }

    // MARK: - Test 8: REGRESSION GUARD — wrong flat keypath returns false
    //
    // RESEARCH correction #2: the flat `selectedAuthType` shape does NOT exist
    // in live files. If the implementation ever silently falls back to flat
    // lookup, this test fails.

    @Test func flatKeypath_regressionGuard_returnsFalse() throws {
        let url = try writeTempSettings(#"{ "selectedAuthType": "oauth-personal" }"#)
        #expect(GeminiSettingsGate.isOAuthPersonal(settingsPath: url) == false)
    }

    // MARK: - Test 9: wrong case "OAuth-Personal" → false (case-sensitive)

    @Test func wrongCase_returnsFalse() throws {
        let url = try writeTempSettings(#"{ "security": { "auth": { "selectedType": "OAuth-Personal" } } }"#)
        #expect(GeminiSettingsGate.isOAuthPersonal(settingsPath: url) == false)
    }

    // MARK: - Test 10: vertex-ai → false

    @Test func vertexAI_returnsFalse() throws {
        let url = try writeTempSettings(#"{ "security": { "auth": { "selectedType": "vertex-ai" } } }"#)
        #expect(GeminiSettingsGate.isOAuthPersonal(settingsPath: url) == false)
    }
}
