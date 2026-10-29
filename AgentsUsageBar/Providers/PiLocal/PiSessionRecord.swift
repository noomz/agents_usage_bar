import Foundation

/// Domain event. Constructed only by `decode(from:)`.
struct PiSessionRecord: Sendable, Equatable {
    let timestamp: Date
    let provider: PiProviderName
    let model: String
    let tokens: Int
    let costUSD: Decimal
    let kind: Kind

    enum Kind: Sendable, Equatable {
        case assistantMessage
        case usageEntry
    }

    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let isoNoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Nil = skip (wrong type, no usage, malformed). Never throws.
    static func decode(from line: String) -> PiSessionRecord? {
        let compactMessage = line.contains("\"type\":\"message\"")
        let spacedMessage = line.contains("\"type\": \"message\"")
        let compactUsage = line.contains("\"type\":\"usage\"")
        let spacedUsage = line.contains("\"type\": \"usage\"")
        guard compactMessage || spacedMessage || compactUsage || spacedUsage else { return nil }

        guard
            let data = line.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        guard let type = json["type"] as? String else { return nil }
        // Compaction / branch summaries may carry a nested usage block; they are not spend.
        guard type == "message" || type == "usage" else { return nil }

        guard
            let timestampString = json["timestamp"] as? String,
            let timestamp = parseISO8601(timestampString)
        else {
            return nil
        }

        let kind: Kind
        let providerRaw: String
        let model: String
        let usage: [String: Any]

        switch type {
        case "message":
            guard
                let message = json["message"] as? [String: Any],
                (message["role"] as? String) == "assistant",
                let usageDict = message["usage"] as? [String: Any],
                let provider = message["provider"] as? String
            else {
                return nil
            }
            kind = .assistantMessage
            providerRaw = provider
            model = (message["model"] as? String) ?? ""
            usage = usageDict
        case "usage":
            guard
                let usageDict = json["usage"] as? [String: Any],
                let provider = json["provider"] as? String
            else {
                return nil
            }
            kind = .usageEntry
            providerRaw = provider
            model = (json["model"] as? String) ?? ""
            usage = usageDict
        default:
            return nil
        }

        return PiSessionRecord(
            timestamp: timestamp,
            provider: PiProviderName(rawValue: providerRaw),
            model: model,
            tokens: tokens(from: usage),
            costUSD: cost(from: usage),
            kind: kind
        )
    }

    private static func parseISO8601(_ s: String) -> Date? {
        isoFractional.date(from: s) ?? isoNoFractional.date(from: s)
    }

    /// Prefer `totalTokens`. Never add it to the part sum.
    private static func tokens(from usage: [String: Any]) -> Int {
        if let total = intValue(usage["totalTokens"]) {
            return total
        }
        let input = intValue(usage["input"]) ?? 0
        let output = intValue(usage["output"]) ?? 0
        let cacheRead = intValue(usage["cacheRead"]) ?? 0
        let cacheWrite = intValue(usage["cacheWrite"]) ?? 0
        let reasoning = intValue(usage["reasoning"]) ?? 0
        return input + output + cacheRead + cacheWrite + reasoning
    }

    private static func cost(from usage: [String: Any]) -> Decimal {
        guard let cost = usage["cost"] as? [String: Any] else { return 0 }
        return decimalValue(cost["total"]) ?? 0
    }

    private static func intValue(_ any: Any?) -> Int? {
        guard let any, !(any is NSNull) else { return nil }
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String { return Int(s) }
        return nil
    }

    private static func decimalValue(_ any: Any?) -> Decimal? {
        guard let any, !(any is NSNull) else { return nil }
        if let n = any as? NSNumber { return n.decimalValue }
        if let d = any as? Decimal { return d }
        if let s = any as? String { return Decimal(string: s) }
        return nil
    }
}
