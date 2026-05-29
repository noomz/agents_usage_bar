import Foundation
import Security

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
    /// An unexpected `OSStatus` was returned — check the raw code for debugging.
    case unexpectedStatus(OSStatus)
    /// The Keychain returned success but the result was not `Data`.
    case dataNotData
}

/// A thin synchronous wrapper around `SecItem` APIs for reading and writing
/// generic-password Keychain items.
///
/// `KeychainReader` is a `struct` (NOT an `actor`) because `SecItem` APIs are
/// synchronous C functions — no async coordination is needed.
///
/// `Sendable` is safe: the struct carries no mutable state; all state is managed
/// by the Keychain service itself.
///
/// Reuse note: Plan 02.03 introduces this type; Plan 03.x (Codex provider) will
/// reuse it for `com.openai.codex.credentials` lookups.
public struct KeychainReader: Sendable, KeychainProtocol {

    public init() {}

    /// Reads a generic-password item from the Keychain.
    ///
    /// - Parameters:
    ///   - service: The `kSecAttrService` value (e.g. `"Claude Code-credentials"`).
    ///   - account: Optional `kSecAttrAccount` filter. Pass `nil` to match any account.
    /// - Returns: The raw `Data` stored in the item.
    /// - Throws: `KeychainReaderError` on failure.
    public func readGenericPassword(service: String, account: String?) throws -> Data {
        var query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw KeychainReaderError.dataNotData
            }
            return data
        case errSecItemNotFound:
            throw KeychainReaderError.itemNotFound
        case errSecAuthFailed:
            throw KeychainReaderError.authFailed
        default:
            throw KeychainReaderError.unexpectedStatus(status)
        }
    }

    /// Writes (or updates) a generic-password item in the Keychain.
    ///
    /// Attempts `SecItemUpdate` first; if `errSecItemNotFound` is returned,
    /// falls back to `SecItemAdd`.
    ///
    /// - Parameters:
    ///   - data: The data payload to store.
    ///   - service: The `kSecAttrService` value.
    ///   - account: Optional `kSecAttrAccount`. Pass `nil` for account-less items.
    /// - Throws: `KeychainReaderError` on failure.
    public func writeGenericPassword(_ data: Data, service: String, account: String?) throws {
        var query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }

        let updateDict: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateDict as CFDictionary)

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            // Item doesn't exist yet — add it
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                switch addStatus {
                case errSecAuthFailed: throw KeychainReaderError.authFailed
                default: throw KeychainReaderError.unexpectedStatus(addStatus)
                }
            }
        case errSecAuthFailed:
            throw KeychainReaderError.authFailed
        default:
            throw KeychainReaderError.unexpectedStatus(updateStatus)
        }
    }
}
