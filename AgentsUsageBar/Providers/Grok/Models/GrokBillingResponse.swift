import Foundation

/// Lenient decode of `GET /billing?format=credits`.
///
/// The Grok CLI `/usage` command consumes this payload. Wire keys mix camelCase
/// (`creditUsagePercent`, `includedUsed`) and snake_case (`subscription_tier`).
/// Fields may sit at the top level or under `data` / `billing` / `config`.
/// Every field is optional so unknown future shapes do not zero the row.
public struct GrokBillingResponse: Decodable, Sendable, Equatable {

    public let creditUsagePercent: Double?
    public let monthlyLimit: Double?
    public let includedUsed: Double?
    public let totalUsed: Double?
    public let prepaidBalance: Double?
    public let onDemandCap: Double?
    public let onDemandUsed: Double?
    public let subscriptionTier: String?
    public let billingPeriodStart: Date?
    public let billingPeriodEnd: Date?
    public let currentPeriod: String?
    public let isUnifiedBillingUser: Bool?
    public let onDemandEnabled: Bool?

    public init(
        creditUsagePercent: Double? = nil,
        monthlyLimit: Double? = nil,
        includedUsed: Double? = nil,
        totalUsed: Double? = nil,
        prepaidBalance: Double? = nil,
        onDemandCap: Double? = nil,
        onDemandUsed: Double? = nil,
        subscriptionTier: String? = nil,
        billingPeriodStart: Date? = nil,
        billingPeriodEnd: Date? = nil,
        currentPeriod: String? = nil,
        isUnifiedBillingUser: Bool? = nil,
        onDemandEnabled: Bool? = nil
    ) {
        self.creditUsagePercent = creditUsagePercent
        self.monthlyLimit = monthlyLimit
        self.includedUsed = includedUsed
        self.totalUsed = totalUsed
        self.prepaidBalance = prepaidBalance
        self.onDemandCap = onDemandCap
        self.onDemandUsed = onDemandUsed
        self.subscriptionTier = subscriptionTier
        self.billingPeriodStart = billingPeriodStart
        self.billingPeriodEnd = billingPeriodEnd
        self.currentPeriod = currentPeriod
        self.isUnifiedBillingUser = isUnifiedBillingUser
        self.onDemandEnabled = onDemandEnabled
    }

    public init(from decoder: Decoder) throws {
        let top = try decoder.container(keyedBy: AnyCodingKey.self)
        let decoded = Self.decodeFields(from: top)
            ?? top.nestedFields(for: "data").flatMap(Self.decodeFields)
            ?? top.nestedFields(for: "billing").flatMap(Self.decodeFields)
            ?? top.nestedFields(for: "config").flatMap(Self.decodeFields)
            ?? Self()
        self = decoded
    }

    /// Primary quota from included-used / monthly-limit, else percent-of-100.
    public func makeQuota() -> Quota? {
        if let limit = monthlyLimit, limit > 0 {
            let used = includedUsed ?? totalUsed ?? percentAsUsed(of: limit) ?? 0
            return Quota(used: used, limit: limit, remaining: max(0, limit - used))
        }
        if let percent = normalizedPercent {
            return Quota(used: percent * 100, limit: 100, remaining: max(0, 100 - percent * 100))
        }
        return nil
    }

    /// 0...1 utilization for the billing window.
    public var normalizedPercent: Double? {
        guard let raw = creditUsagePercent else { return nil }
        let value = raw > 1.0 ? raw / 100.0 : raw
        return min(1.0, max(0.0, value))
    }

    private func percentAsUsed(of limit: Double) -> Double? {
        normalizedPercent.map { $0 * limit }
    }

    // MARK: - Decode helpers

    private static func decodeFields(from c: KeyedDecodingContainer<AnyCodingKey>) -> GrokBillingResponse? {
        let response = GrokBillingResponse(
            creditUsagePercent: c.decodeFlexibleDouble("creditUsagePercent", "credit_usage_percent"),
            monthlyLimit: c.decodeFlexibleDouble("monthlyLimit", "monthly_limit"),
            includedUsed: c.decodeFlexibleDouble("includedUsed", "included_used"),
            totalUsed: c.decodeFlexibleDouble("totalUsed", "total_used"),
            prepaidBalance: c.decodeFlexibleDouble("prepaidBalance", "prepaid_balance"),
            onDemandCap: c.decodeFlexibleDouble("onDemandCap", "on_demand_cap"),
            onDemandUsed: c.decodeFlexibleDouble("onDemandUsed", "on_demand_used"),
            subscriptionTier: c.decodeFlexibleString("subscriptionTier", "subscription_tier"),
            billingPeriodStart: c.decodeFlexibleDate("billingPeriodStart", "billing_period_start"),
            billingPeriodEnd: c.decodeFlexibleDate("billingPeriodEnd", "billing_period_end"),
            currentPeriod: c.decodeFlexibleString("currentPeriod", "current_period"),
            isUnifiedBillingUser: c.decodeFlexibleBool("isUnifiedBillingUser", "is_unified_billing_user"),
            onDemandEnabled: c.decodeFlexibleBool("onDemandEnabled", "on_demand_enabled")
        )
        if response.creditUsagePercent == nil
            && response.monthlyLimit == nil
            && response.includedUsed == nil
            && response.totalUsed == nil
            && response.prepaidBalance == nil
            && response.subscriptionTier == nil {
            return nil
        }
        return response
    }
}

// MARK: - AnyCodingKey + flexible field readers

struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(_ string: String) {
        self.stringValue = string
        self.intValue = nil
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private extension KeyedDecodingContainer where K == AnyCodingKey {
    func nestedFields(for key: String) -> KeyedDecodingContainer<AnyCodingKey>? {
        try? nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey(key))
    }

    func decodeFlexibleDouble(_ keys: String...) -> Double? {
        for key in keys {
            let k = AnyCodingKey(key)
            if let v = try? decodeIfPresent(Double.self, forKey: k) { return v }
            if let v = try? decodeIfPresent(Int.self, forKey: k) { return Double(v) }
            if let s = try? decodeIfPresent(String.self, forKey: k), let v = Double(s) { return v }
        }
        return nil
    }

    func decodeFlexibleString(_ keys: String...) -> String? {
        for key in keys {
            let k = AnyCodingKey(key)
            if let v = try? decodeIfPresent(String.self, forKey: k), !v.isEmpty { return v }
        }
        return nil
    }

    func decodeFlexibleBool(_ keys: String...) -> Bool? {
        for key in keys {
            let k = AnyCodingKey(key)
            if let v = try? decodeIfPresent(Bool.self, forKey: k) { return v }
        }
        return nil
    }

    func decodeFlexibleDate(_ keys: String...) -> Date? {
        for key in keys {
            let k = AnyCodingKey(key)
            if let s = try? decodeIfPresent(String.self, forKey: k), let d = Self.parseISO8601(s) {
                return d
            }
            if let epoch = try? decodeIfPresent(Double.self, forKey: k) {
                let seconds = epoch > 1_000_000_000_000 ? epoch / 1000.0 : epoch
                return Date(timeIntervalSince1970: seconds)
            }
        }
        return nil
    }

    static func parseISO8601(_ s: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }
}
