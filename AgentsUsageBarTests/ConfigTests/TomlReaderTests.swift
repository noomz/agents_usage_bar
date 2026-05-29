import Testing
@testable import AgentsUsageBar
import Foundation

// MARK: - TomlReader Tests (D-16, D-18)

@Suite("TomlReaderTests")
struct TomlReaderTests {

    // MARK: - Helpers

    /// Load a fixture TOML file from the test bundle's ConfigTests/Fixtures/ directory.
    private func loadFixture(named name: String) -> String {
        let bundle = Bundle(for: BundleFinder.self)
        // Try direct resource lookup first (copied as resources)
        if let url = bundle.url(forResource: name, withExtension: "toml") {
            return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        // Fallback: derive path from source file location (works in Xcode test bundles)
        let thisFile = URL(fileURLWithPath: #file)
        let fixturesDir = thisFile
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
        let fileURL = fixturesDir.appendingPathComponent("\(name).toml")
        return (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    // MARK: - Test 1: Empty string → empty top-level map

    @Test("parseEmptyString_returnsEmptyTopLevel")
    func parseEmptyString_returnsEmptyTopLevel() {
        let result = TomlReader.parse("")
        #expect(result == ["": [:]])
    }

    // MARK: - Test 2: Comments-only file → empty top-level map

    @Test("parseCommentsOnly_returnsEmptyTopLevel")
    func parseCommentsOnly_returnsEmptyTopLevel() {
        let text = loadFixture(named: "comments-only")
        let result = TomlReader.parse(text)
        #expect(result == ["": [:]])
    }

    // MARK: - Test 3: Four scalar types parsed correctly

    @Test("parseScalars_stringIntDoubleBool")
    func parseScalars_stringIntDoubleBool() {
        let text = """
        label = "hello"
        count = 42
        ratio = 3.14
        enabled = true
        """
        let result = TomlReader.parse(text)
        #expect(result[""] != nil)
        let top = result[""]!
        #expect(top["label"] == .string("hello"))
        #expect(top["count"] == .int(42))
        #expect(top["ratio"] == .double(3.14))
        #expect(top["enabled"] == .bool(true))
    }

    // MARK: - Test 4: Section header assigns keys under the section, not top-level

    @Test("parseSection_assignsKeysToSection")
    func parseSection_assignsKeysToSection() {
        let text = "[openrouter]\napi_key = \"sk-test\"\n"
        let result = TomlReader.parse(text)
        // Top-level is empty
        #expect(result[""]?.isEmpty == true)
        // Section has the key
        #expect(result["openrouter"]?["api_key"] == .string("sk-test"))
    }

    // MARK: - Test 5: Trailing inline comment stripped

    @Test("parseInlineComment_strips")
    func parseInlineComment_strips() {
        let text = "key = \"value\"  # trailing comment\n"
        let result = TomlReader.parse(text)
        #expect(result[""]?["key"] == .string("value"))
    }

    // MARK: - Test 6: Hash inside a quoted string is preserved

    @Test("parseQuotedStringWithHashCharacter_keepsHash")
    func parseQuotedStringWithHashCharacter_keepsHash() {
        let text = "key = \"https://example.com/#frag\"\n"
        let result = TomlReader.parse(text)
        #expect(result[""]?["key"] == .string("https://example.com/#frag"))
    }

    // MARK: - Test 7: Malformed lines skipped; valid neighbors preserved

    @Test("parseMalformedLine_skips_neighborsPreserved")
    func parseMalformedLine_skips_neighborsPreserved() {
        let text = loadFixture(named: "malformed")
        // malformed.toml has:
        //   refresh_interval = "5m"        ← valid (top-level)
        //   this_line_is_broken            ← INVALID (no =)
        //   threshold = 0.80               ← valid (top-level)
        //   [openrouter]
        //   api_key = "sk-or-..."          ← valid (section)
        //   bare_token_no_equals           ← INVALID (no =)
        //   models = ["arrays", ...]       ← INVALID (array syntax)
        //   enabled = true                 ← valid (section)
        let result = TomlReader.parse(text)

        // Valid top-level keys extracted
        #expect(result[""]?["refresh_interval"] == .string("5m"))
        #expect(result[""]?["threshold"] == .double(0.80))

        // Valid section keys extracted
        let or = result["openrouter"]
        #expect(or != nil)
        #expect(or?["api_key"] == .string("sk-or-FAKE_FIXTURE_KEY_XXXXXXXXXXXXXXXX"))
        #expect(or?["enabled"] == .bool(true))

        // Invalid lines were NOT added
        #expect(or?["bare_token_no_equals"] == nil)
        #expect(result[""]?["this_line_is_broken"] == nil)
        #expect(or?["models"] == nil)
    }

    // MARK: - Test 8: Array syntax treated as invalid (D-16 scope)

    @Test("parseArraySyntax_isInvalidLine")
    func parseArraySyntax_isInvalidLine() {
        let text = "models = [\"a\", \"b\"]\n"
        let result = TomlReader.parse(text)
        // The array line should be skipped (not parseable as scalar)
        #expect(result[""]?["models"] == nil)
    }

    // MARK: - Test 9: Full valid.toml fixture parses complete shape

    @Test("parseValidFixture_completeShape")
    func parseValidFixture_completeShape() {
        let text = loadFixture(named: "valid")
        let result = TomlReader.parse(text)

        // Top-level scalars
        #expect(result[""]?["refresh_interval"] == .string("5m"))
        #expect(result[""]?["threshold"] == .double(0.80))

        // [openrouter] section — all 5 keys
        let or = result["openrouter"]
        #expect(or != nil)
        #expect(or?["api_key"] == .string("sk-or-FAKE_FIXTURE_KEY_XXXXXXXXXXXXXXXX"))
        #expect(or?["api_url"] == .string("https://openrouter.ai/api/v1"))
        #expect(or?["http_referer"] == .string("https://github.com/lazym0m3nt/agents_usage_bar"))
        #expect(or?["x_title"] == .string("Agents Usage Bar"))
        #expect(or?["enabled"] == .bool(true))
    }

    // MARK: - Test 10: Fuzz-style — any input returns a dict (D-18 fail-soft invariant)

    @Test("parseDoesNotThrow_onAnyInput")
    func parseDoesNotThrow_onAnyInput() {
        // Simulate random/garbage input
        let garbage = String(bytes: (0..<128).map { _ in UInt8.random(in: 32...126) }, encoding: .ascii) ?? "garbage"
        let result = TomlReader.parse(garbage)
        // Must always return a non-nil dictionary (fail-soft — never throws)
        #expect(result[""] != nil)
    }
}

// MARK: - Bundle finder anchor

/// An empty class used solely to locate the test bundle via `Bundle(for:)`.
private class BundleFinder: NSObject {}
