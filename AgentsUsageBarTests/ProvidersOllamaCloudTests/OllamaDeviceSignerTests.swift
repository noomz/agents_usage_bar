import CryptoKit
import Foundation
import Testing
@testable import AgentsUsageBar

// SPEC V3/V4/V21/V23 — synthetic keys only: generated in-test and serialised to the
// openssh-key-v1 container here. Signatures are randomized (V23), so goldens pin the
// deterministic parts and signatures are checked by verification.

@Suite("OllamaDeviceSignerTests")
struct OllamaDeviceSignerTests {

    /// Seed 0x01×32 — a throwaway test vector, not anyone's key.
    static let fixedSeed = Data(repeating: 1, count: 32)
    static let fixedPublicKeyField = "AAAAC3NzaC1lZDI1NTE5AAAAIIqI4910CfGV/VLbLTy6XXLKZwm/HZQSG/N0iAG0D29c"
    static let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Parsing

    @Test func parse_fixedSeed_publicKeyFieldGolden() throws {
        let signer = try OllamaDeviceSigner(openSSH: TestOpenSSHKey.encode(seed: Self.fixedSeed))
        #expect(signer.publicKeyField == Self.fixedPublicKeyField)
    }

    @Test func parse_randomKey_roundTrips() throws {
        let key = Curve25519.Signing.PrivateKey()
        let signer = try OllamaDeviceSigner(openSSH: TestOpenSSHKey.encode(seed: key.rawRepresentation))
        #expect(signer.publicKeyField == TestOpenSSHKey.publicBlob(key.publicKey).base64EncodedString())
    }

    @Test func parse_withoutPEMMarkers_ok() throws {
        let pem = TestOpenSSHKey.encode(seed: Self.fixedSeed)
        let bare = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined(separator: "\n")
        #expect(try OllamaDeviceSigner(openSSH: bare).publicKeyField == Self.fixedPublicKeyField)
    }

    @Test func parse_encryptedCipher_throwsEncrypted() {
        let pem = TestOpenSSHKey.encode(seed: Self.fixedSeed, cipher: "aes256-ctr")
        #expect(throws: OllamaDeviceSigner.KeyError.encrypted) { try OllamaDeviceSigner(openSSH: pem) }
    }

    @Test func parse_wrongKeyType_throwsUnsupported() {
        let pem = TestOpenSSHKey.encode(seed: Self.fixedSeed, keyType: "ssh-rsa")
        #expect(throws: OllamaDeviceSigner.KeyError.unsupportedKeyType) { try OllamaDeviceSigner(openSSH: pem) }
    }

    @Test func parse_checkIntMismatch_throwsMalformed() {
        let pem = TestOpenSSHKey.encode(seed: Self.fixedSeed, checkInts: (1, 2))
        #expect(throws: OllamaDeviceSigner.KeyError.malformed) { try OllamaDeviceSigner(openSSH: pem) }
    }

    @Test func parse_mismatchedPublicHalf_throwsMalformed() {
        let pem = TestOpenSSHKey.encode(seed: Self.fixedSeed, corruptPublicHalf: true)
        #expect(throws: OllamaDeviceSigner.KeyError.malformed) { try OllamaDeviceSigner(openSSH: pem) }
    }

    @Test(arguments: ["", "not base64 !!", Data("openssh-key-v2\0".utf8).base64EncodedString()])
    func parse_garbage_throwsMalformed(text: String) {
        #expect(throws: OllamaDeviceSigner.KeyError.malformed) { try OllamaDeviceSigner(openSSH: text) }
    }

    @Test func parse_truncated_throwsMalformed() throws {
        let pem = TestOpenSSHKey.encode(seed: Self.fixedSeed)
        let raw = Data(base64Encoded: pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined())!
        let truncated = raw.prefix(raw.count / 2).base64EncodedString()
        #expect(throws: OllamaDeviceSigner.KeyError.malformed) { try OllamaDeviceSigner(openSSH: truncated) }
    }

    // MARK: - Loading

    @Test func load_missingFile_nil() {
        let url = FileManager.default.temporaryDirectory.appending(path: "no-such-\(UUID().uuidString)")
        #expect(OllamaDeviceSigner.load(from: url) == nil)
    }

    @Test func load_validFile_ok() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "OllamaDeviceSignerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "id_ed25519")
        try Data(TestOpenSSHKey.encode(seed: Self.fixedSeed).utf8).write(to: url)
        #expect(OllamaDeviceSigner.load(from: url)?.publicKeyField == Self.fixedPublicKeyField)
    }

    @Test func defaultKeyURL_underDotOllama() {
        let url = OllamaDeviceSigner.defaultKeyURL(home: URL(fileURLWithPath: "/tmp/home"))
        #expect(url.path == "/tmp/home/.ollama/id_ed25519")
    }

    // MARK: - Signing (V23 golden: deterministic parts + verification)

    @Test func sign_get_goldenURLChallengeAndVerifiableSignature() throws {
        let signer = try OllamaDeviceSigner(openSSH: TestOpenSSHKey.encode(seed: Self.fixedSeed))
        let signed = try signer.sign(URLRequest(url: URL(string: "https://ollama.com/api/usage")!), now: Self.fixedNow)

        #expect(signed.url?.absoluteString == "https://ollama.com/api/usage?ts=1700000000")
        let challenge = OllamaDeviceSigner.challenge(method: "GET", url: signed.url!)
        #expect(challenge == "GET,/api/usage?ts=1700000000")
        try Self.expectValidHeader(signed, challenge: challenge)
    }

    @Test func sign_post_challengeUsesMethod() throws {
        let signer = try OllamaDeviceSigner(openSSH: TestOpenSSHKey.encode(seed: Self.fixedSeed))
        var request = URLRequest(url: URL(string: "https://ollama.com/api/me")!)
        request.httpMethod = "POST"
        let signed = try signer.sign(request, now: Self.fixedNow)
        let challenge = OllamaDeviceSigner.challenge(method: "POST", url: signed.url!)
        #expect(challenge == "POST,/api/me?ts=1700000000")
        try Self.expectValidHeader(signed, challenge: challenge)
    }

    @Test func sign_replacesExistingTs_keepsOtherQuery() throws {
        let signer = try OllamaDeviceSigner(openSSH: TestOpenSSHKey.encode(seed: Self.fixedSeed))
        let url = URL(string: "https://ollama.com/api/usage?a=1&ts=5")!
        let signed = try signer.sign(URLRequest(url: url), now: Self.fixedNow)
        #expect(signed.url?.absoluteString == "https://ollama.com/api/usage?a=1&ts=1700000000")
        try Self.expectValidHeader(signed, challenge: "GET,/api/usage?a=1&ts=1700000000")
    }

    @Test func description_redacted() throws {
        let signer = try OllamaDeviceSigner(openSSH: TestOpenSSHKey.encode(seed: Self.fixedSeed))
        #expect(String(describing: signer) == "OllamaDeviceSigner(<redacted>)")
        #expect(!String(reflecting: signer).contains(Self.fixedSeed.base64EncodedString()))
    }

    private static func expectValidHeader(_ request: URLRequest, challenge: String) throws {
        let header = try #require(request.value(forHTTPHeaderField: "Authorization"))
        let parts = header.split(separator: ":", omittingEmptySubsequences: false)
        try #require(parts.count == 2)
        #expect(parts[0] == Substring(fixedPublicKeyField))
        let signature = try #require(Data(base64Encoded: String(parts[1])))
        #expect(signature.count == 64)
        let publicKey = try Curve25519.Signing.PrivateKey(rawRepresentation: fixedSeed).publicKey
        #expect(publicKey.isValidSignature(signature, for: Data(challenge.utf8)))
    }
}

/// Builds synthetic openssh-key-v1 containers for tests. Markers are neutral
/// (`TEST KEY`) — the parser ignores `-----` lines — so no real private-key header
/// string lives in the repo (SPEC V22).
enum TestOpenSSHKey {
    static func publicBlob(_ key: Curve25519.Signing.PublicKey) -> Data {
        Data(string("ssh-ed25519") + string(Array(key.rawRepresentation)))
    }

    static func encode(
        seed: Data,
        cipher: String = "none",
        keyType: String = "ssh-ed25519",
        checkInts: (UInt32, UInt32) = (0x5EED_5EED, 0x5EED_5EED),
        corruptPublicHalf: Bool = false
    ) -> String {
        let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let pub = Array(key.publicKey.rawRepresentation)
        var secretPub = pub
        if corruptPublicHalf { secretPub[0] ^= 0xFF }

        var priv = u32(checkInts.0) + u32(checkInts.1)
        priv += string(keyType) + string(pub) + string(Array(seed) + secretPub) + string("test")
        var pad: UInt8 = 1
        while priv.count % 8 != 0 { priv.append(pad); pad += 1 }

        var out = Array("openssh-key-v1\0".utf8)
        out += string(cipher) + string("none") + string([UInt8]()) + u32(1)
        out += string(Array(publicBlob(key.publicKey))) + string(priv)

        let b64 = Data(out).base64EncodedString()
        let lines = stride(from: 0, to: b64.count, by: 70).map { i -> String in
            let start = b64.index(b64.startIndex, offsetBy: i)
            return String(b64[start..<(b64.index(start, offsetBy: 70, limitedBy: b64.endIndex) ?? b64.endIndex)])
        }
        return (["-----BEGIN TEST KEY-----"] + lines + ["-----END TEST KEY-----"]).joined(separator: "\n") + "\n"
    }

    private static func u32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.bigEndian, Array.init) }
    private static func string(_ s: String) -> [UInt8] { string(Array(s.utf8)) }
    private static func string(_ b: [UInt8]) -> [UInt8] { u32(UInt32(b.count)) + b }
}
