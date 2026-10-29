import Foundation

/// Local provider ids derived from one or more Pi `models.json` files.
struct PiLocalCatalog: Sendable, Equatable {
    let names: Set<PiProviderName>

    private static let llamaCpp = PiProviderName(rawValue: "llama.cpp")

    private static let cloudIDs: Set<String> = [
        "anthropic",
        "openai",
        "openai-codex",
        "openrouter",
        "xai",
        "amazon-bedrock",
        "router",
        "google",
        "gemini",
    ]

    func contains(_ name: PiProviderName) -> Bool {
        names.contains(name)
    }

    /// Parse `{"providers": { "<id>": { "baseUrl": "..." } }}`.
    /// Missing/unreadable files contribute nothing. Union across urls.
    /// Always unions `{ llama.cpp }`.
    static func load(urls: [URL]) -> PiLocalCatalog {
        var names: Set<PiProviderName> = [llamaCpp]
        for url in urls {
            guard
                let data = try? Data(contentsOf: url),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let providers = json["providers"] as? [String: Any]
            else {
                continue
            }
            for (key, value) in providers {
                let name = PiProviderName(rawValue: key)
                let dict = value as? [String: Any]
                let base = (dict?["baseUrl"] as? String).flatMap { URL(string: $0) }
                if isLocal(id: name, baseUrl: base) {
                    names.insert(name)
                }
            }
        }
        return PiLocalCatalog(names: names)
    }

    /// Cloud denylist wins even when `baseUrl` looks local. `llama.cpp` is always local.
    static func isLocal(id: PiProviderName, baseUrl: URL?) -> Bool {
        let key = id.rawValue.lowercased()
        if cloudIDs.contains(key) { return false }
        if key == llamaCpp.rawValue { return true }
        guard let baseUrl, let host = baseUrl.host, !host.isEmpty else { return false }
        let hostLower = host.lowercased()
        if isLoopback(hostLower) { return true }
        if isIPv4PrivateOrLinkLocal(hostLower) { return true }
        if isIPv6LinkLocal(hostLower) { return true }
        if hostLower.hasSuffix(".local") { return true }
        let scheme = (baseUrl.scheme ?? "").lowercased()
        if scheme == "http", isDotlessLANHost(hostLower) { return true }
        return false
    }

    private static func isLoopback(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" || host == "0:0:0:0:0:0:0:1" { return true }
        guard let octets = ipv4Octets(host) else { return false }
        return octets[0] == 127
    }

    private static func isIPv4PrivateOrLinkLocal(_ host: String) -> Bool {
        guard let octets = ipv4Octets(host) else { return false }
        if octets[0] == 10 { return true }
        if octets[0] == 172, (16...31).contains(octets[1]) { return true }
        if octets[0] == 192, octets[1] == 168 { return true }
        if octets[0] == 169, octets[1] == 254 { return true }
        return false
    }

    private static func isIPv6LinkLocal(_ host: String) -> Bool {
        host.hasPrefix("fe80:")
    }

    private static func isDotlessLANHost(_ host: String) -> Bool {
        !host.isEmpty && !host.contains(".") && !host.contains(":")
    }

    private static func ipv4Octets(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(4)
        for part in parts {
            guard let n = UInt8(part) else { return nil }
            out.append(n)
        }
        return out
    }
}
