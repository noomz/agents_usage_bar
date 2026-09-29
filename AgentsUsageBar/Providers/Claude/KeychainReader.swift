import Foundation

/// Error types surfaced by `KeychainReader`.
///
/// Pitfall A11: `authFailed` must be swallowed silently by callers that do not
/// own the user's Keychain state (e.g. `ClaudeCredentialLoader`). Propagating an
/// `authFailed` into UI triggers a blocking macOS Keychain auth dialog cascade.
public enum KeychainReaderError: Error, Sendable, Equatable {
    /// No item matching the query exists in the Keychain.
    case itemNotFound
    /// The Keychain item exists but access was denied (ACL mismatch or locked Keychain).
    case authFailed
    /// `security` exited with an unexpected status — check the raw code for debugging.
    case unexpectedStatus(Int32)
    /// `security` succeeded but its output could not be read.
    case dataNotData
}

/// Reads generic-password Keychain items by running `/usr/bin/security`.
///
/// Why not `SecItemCopyMatching`: Claude Code creates `"Claude Code-credentials"`
/// with the `security` CLI, so the item's ACL trusts `com.apple.security`
/// (Apple-anchored, stable across OS updates). Calling `SecItem` directly makes
/// macOS check *this app's* identity instead — for ad-hoc builds that is a
/// cdhash that changes on every build, so "Always Allow" never sticks and the
/// user is prompted after each rebuild/update. Reading via `security` is covered
/// by the existing ACL entry and never prompts.
///
/// Read-only by design: the Keychain item is owned by Claude Code; this app
/// never writes to it.
public struct KeychainReader: Sendable, KeychainProtocol {

    /// `security` exit status for `errSecItemNotFound`.
    private static let itemNotFoundExitStatus: Int32 = 44
    /// `security` exit status for `errSecAuthFailed` (user denied / locked keychain).
    private static let authFailedExitStatus: Int32 = 51

    public init() {}

    /// Reads a generic-password item from the Keychain.
    ///
    /// - Parameters:
    ///   - service: The `kSecAttrService` value (e.g. `"Claude Code-credentials"`).
    ///   - account: Optional `kSecAttrAccount` filter. Pass `nil` to match any account.
    /// - Returns: The raw password `Data` stored in the item.
    /// - Throws: `KeychainReaderError` on failure.
    public func readGenericPassword(service: String, account: String?) throws -> Data {
        var arguments = ["find-generic-password", "-s", service]
        if let account {
            arguments += ["-a", account]
        }
        arguments.append("-w")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw KeychainReaderError.unexpectedStatus(-1)
        }
        // Read before waiting so a large payload cannot fill the pipe and deadlock.
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        switch process.terminationStatus {
        case 0:
            // `-w` prints the password followed by a single newline.
            var data = output
            if data.last == UInt8(ascii: "\n") { data.removeLast() }
            guard !data.isEmpty else { throw KeychainReaderError.dataNotData }
            return data
        case Self.itemNotFoundExitStatus:
            throw KeychainReaderError.itemNotFound
        case Self.authFailedExitStatus:
            throw KeychainReaderError.authFailed
        case let status:
            throw KeychainReaderError.unexpectedStatus(status)
        }
    }
}
