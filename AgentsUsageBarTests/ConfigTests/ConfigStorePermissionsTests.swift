import Testing
@testable import AgentsUsageBar
import Foundation

// MARK: - ConfigStorePermissionsTests (Plan 06-01 / SEC-03)
//
// SEC-03: config.toml may contain provider API keys. A world- or group-
// readable file leaks credentials to other local users. ConfigStore must
//   (1) create the file with POSIX mode 0o600 (owner read/write only), and
//   (2) on every `load()` warn (never crash) if the file is found with any
//       group/other bit set (`mode & 0o077 != 0`).
//
// Test seam (mirrors Phase 1 STATE #33 pure-predicate approach):
// `checkAndWarnPermissions()` returns Void — tests assert the pure helper
// `ConfigStore.isWorldOrGroupReadable(mode:)` which is the exact gate the
// production warning branch consumes. The integration cases also exercise
// `ensureConfigFile(contents:)` end-to-end against a real temp file.
//
// Each case uses a UUID-scoped temp toml path so cases are isolated and
// parallel-safe (no shared global state, no Keychain, no real `~/.config`).

@Suite("ConfigStorePermissionsTests")
struct ConfigStorePermissionsTests {

    // MARK: - Helpers

    /// A unique non-existent toml URL under the OS temp directory.
    /// Caller does not pre-create the file or its parent.
    private func makeTempTomlPath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigStorePermissionsTests-\(UUID().uuidString)")
            .appendingPathComponent("config.toml")
    }

    /// Reads POSIX permission bits (masked to `0o777`) from an existing path.
    /// Returns nil if the file does not exist or the attribute is missing.
    private func posixModeMasked(at url: URL) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mode = attrs[.posixPermissions] as? Int
        else { return nil }
        return mode & 0o777
    }

    // MARK: - Test 1: ensureConfigFile creates file at 0o600

    @Test("ensureConfigFile_createsAt0600")
    func ensureConfigFile_createsAt0600() throws {
        let tomlURL = makeTempTomlPath()
        defer { try? FileManager.default.removeItem(at: tomlURL.deletingLastPathComponent()) }

        let store = ConfigStore(env: DictionaryEnvReader([:]), tomlPath: tomlURL)
        try store.ensureConfigFile(contents: Data("threshold = 0.85\n".utf8))

        #expect(FileManager.default.fileExists(atPath: tomlURL.path))
        #expect(posixModeMasked(at: tomlURL) == 0o600)
    }

    // MARK: - Test 2: ensureConfigFile writes supplied bytes verbatim

    @Test("ensureConfigFile_writesContentsVerbatim")
    func ensureConfigFile_writesContentsVerbatim() throws {
        let tomlURL = makeTempTomlPath()
        defer { try? FileManager.default.removeItem(at: tomlURL.deletingLastPathComponent()) }

        let payload = "threshold = 0.42\nrefresh_interval = \"2m\"\n"
        let store = ConfigStore(env: DictionaryEnvReader([:]), tomlPath: tomlURL)
        try store.ensureConfigFile(contents: Data(payload.utf8))

        let readBack = try String(contentsOf: tomlURL, encoding: .utf8)
        #expect(readBack == payload)
    }

    // MARK: - Test 3: ensureConfigFile is idempotent — does not overwrite or rechmod

    @Test("ensureConfigFile_idempotent_noOverwrite_noRechmod")
    func ensureConfigFile_idempotent_noOverwrite_noRechmod() throws {
        let tomlURL = makeTempTomlPath()
        defer { try? FileManager.default.removeItem(at: tomlURL.deletingLastPathComponent()) }

        // Pre-seed the file with custom contents AND a deliberately wide mode
        // (0o644). ensureConfigFile must NOT touch either when the file exists.
        try FileManager.default.createDirectory(
            at: tomlURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let existingPayload = "preexisting = true\n"
        try existingPayload.write(to: tomlURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: tomlURL.path
        )

        let store = ConfigStore(env: DictionaryEnvReader([:]), tomlPath: tomlURL)
        try store.ensureConfigFile(contents: Data("OVERWRITE_ME = false\n".utf8))

        // Contents unchanged
        let readBack = try String(contentsOf: tomlURL, encoding: .utf8)
        #expect(readBack == existingPayload)
        // Permissions unchanged (still 0o644 — we did NOT silently chmod it)
        #expect(posixModeMasked(at: tomlURL) == 0o644)
    }

    // MARK: - Test 4: isWorldOrGroupReadable predicate — 0o600 is safe

    @Test("isWorldOrGroupReadable_0600_isFalse")
    func isWorldOrGroupReadable_0600_isFalse() {
        #expect(ConfigStore.isWorldOrGroupReadable(mode: 0o600) == false)
    }

    // MARK: - Test 5: isWorldOrGroupReadable predicate — 0o644, 0o604, 0o660 all flag

    @Test("isWorldOrGroupReadable_widePermissions_areTrue")
    func isWorldOrGroupReadable_widePermissions_areTrue() {
        // Other-readable
        #expect(ConfigStore.isWorldOrGroupReadable(mode: 0o644) == true)
        #expect(ConfigStore.isWorldOrGroupReadable(mode: 0o604) == true)
        // Group-readable
        #expect(ConfigStore.isWorldOrGroupReadable(mode: 0o660) == true)
        // Group-only-execute also trips (mode & 0o077 != 0)
        #expect(ConfigStore.isWorldOrGroupReadable(mode: 0o610) == true)
    }

    // MARK: - Test 6: checkAndWarnPermissions on missing file is a silent no-op

    @Test("checkAndWarnPermissions_missingFile_isSilentNoOp")
    func checkAndWarnPermissions_missingFile_isSilentNoOp() {
        let tomlURL = makeTempTomlPath() // never created
        let store = ConfigStore(env: DictionaryEnvReader([:]), tomlPath: tomlURL)

        // Must not throw / crash. Behavioral proxy: also verify load() — which
        // wires checkAndWarnPermissions() at its tail — still returns defaults.
        store.checkAndWarnPermissions()
        let config = store.load()
        #expect(config.threshold == 0.80)
    }

    // MARK: - Test 7: load() wires checkAndWarnPermissions for wide-permission files

    @Test("load_doesNotCrash_onWideOpenConfigFile")
    func load_doesNotCrash_onWideOpenConfigFile() throws {
        // Belt-and-suspenders integration: write a real 0o644 toml file, then
        // call load(). The world-readable warning branch executes; load() must
        // still return a valid AppConfig (D-18 fail-soft).
        let tomlURL = makeTempTomlPath()
        defer { try? FileManager.default.removeItem(at: tomlURL.deletingLastPathComponent()) }

        try FileManager.default.createDirectory(
            at: tomlURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "threshold = 0.91\n".write(to: tomlURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: tomlURL.path
        )

        let store = ConfigStore(env: DictionaryEnvReader([:]), tomlPath: tomlURL)
        let config = store.load()

        // load() returns the parsed value — confirms execution proceeded past
        // checkAndWarnPermissions() rather than crashing.
        #expect(config.threshold == 0.91)
    }
}
