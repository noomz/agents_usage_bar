import CryptoKit
import Foundation

/// Signs ollama.com requests with the `ollama signin` device key
/// (`~/.ollama/id_ed25519`), the same way Ollama's own client does
/// (`auth/auth.go` `Sign`, `server/cloud_proxy.go` `signCloudProxyRequest`).
///
/// SPEC V3/V4/I3: only the unencrypted OpenSSH ed25519 container is accepted.
/// Key bytes stay in memory for signing; nothing here logs, caches or writes them,
/// and `description` is redacted.
public struct OllamaDeviceSigner: Sendable, CustomStringConvertible {

    public enum KeyError: Error, Equatable {
        case malformed
        case encrypted
        case unsupportedKeyType
    }

    /// `authorized_keys` public-key field: base64 of the SSH wire-format public key.
    public let publicKeyField: String
    private let seed: Data

    public var description: String { "OllamaDeviceSigner(<redacted>)" }

    public static func defaultKeyURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appending(path: ".ollama/id_ed25519")
    }

    /// Loads the device key. `nil` when the file is absent, unreadable, encrypted
    /// or not ed25519 — the caller treats that as "no device credential".
    public static func load(from url: URL = defaultKeyURL()) -> OllamaDeviceSigner? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        do {
            return try OllamaDeviceSigner(openSSH: text)
        } catch {
            AppLogger.logger(category: "ollama-cloud")
                .debug("device key unusable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Parses an OpenSSH private-key PEM block (openssh-key-v1 container).
    public init(openSSH text: String) throws {
        let body = text.split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let raw = Data(base64Encoded: body) else { throw KeyError.malformed }

        var r = Reader(Array(raw))
        guard try r.bytes(Self.magic.count) == Self.magic else { throw KeyError.malformed }
        guard try r.string() == Array("none".utf8) else { throw KeyError.encrypted }
        _ = try r.string()                       // kdfname
        _ = try r.string()                       // kdfoptions
        guard try r.uint32() == 1 else { throw KeyError.malformed }
        let publicBlob = try r.string()

        var p = Reader(try r.string())
        guard try p.uint32() == p.uint32() else { throw KeyError.malformed }
        guard try p.string() == Array("ssh-ed25519".utf8) else { throw KeyError.unsupportedKeyType }
        let publicKey = try p.string()
        let secret = try p.string()               // seed(32) ‖ public(32)
        guard publicKey.count == 32, secret.count == 64,
              Array(secret[32...]) == publicKey else { throw KeyError.malformed }

        let seed = Data(secret[..<32])
        let derived = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        guard Array(derived.publicKey.rawRepresentation) == publicKey else { throw KeyError.malformed }

        self.seed = seed
        self.publicKeyField = Data(publicBlob).base64EncodedString()
    }

    /// Returns `request` with `ts=<unix seconds>` in its query (replacing any
    /// existing `ts`) and `Authorization: <publicKeyField>:<base64 signature>`
    /// over `"<METHOD>,<path>?<query>"`.
    public func sign(_ request: URLRequest, now: Date) throws -> URLRequest {
        guard let url = request.url,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        var items = (components.queryItems ?? []).filter { $0.name != "ts" }
        items.append(URLQueryItem(name: "ts", value: String(Int(now.timeIntervalSince1970))))
        components.queryItems = items
        guard let signedURL = components.url else { throw URLError(.badURL) }

        let challenge = Self.challenge(method: request.httpMethod ?? "GET", url: signedURL)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let signature = try key.signature(for: Data(challenge.utf8))

        var signed = request
        signed.url = signedURL
        signed.setValue("\(publicKeyField):\(signature.base64EncodedString())", forHTTPHeaderField: "Authorization")
        return signed
    }

    /// `"<METHOD>,<request-uri>"` — Go `fmt.Sprintf("%s,%s", req.Method, req.URL.RequestURI())`.
    static func challenge(method: String, url: URL) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = components?.percentEncodedPath.isEmpty == false ? components!.percentEncodedPath : "/"
        guard let query = components?.percentEncodedQuery, !query.isEmpty else { return "\(method),\(path)" }
        return "\(method),\(path)?\(query)"
    }

    private static let magic = Array("openssh-key-v1\0".utf8)

    /// Bounds-checked reader for SSH wire format (big-endian uint32 + length-prefixed strings).
    private struct Reader {
        private let buf: [UInt8]
        private var i = 0

        init(_ buf: [UInt8]) { self.buf = buf }

        mutating func bytes(_ n: Int) throws -> [UInt8] {
            guard n >= 0, i + n <= buf.count else { throw KeyError.malformed }
            defer { i += n }
            return Array(buf[i..<i + n])
        }

        mutating func uint32() throws -> Int {
            try bytes(4).reduce(0) { $0 << 8 | Int($1) }
        }

        mutating func string() throws -> [UInt8] {
            try bytes(uint32())
        }
    }
}
