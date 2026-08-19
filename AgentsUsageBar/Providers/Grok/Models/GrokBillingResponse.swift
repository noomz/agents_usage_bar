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
    /// Human period label from `currentPeriod.type` (e.g. "weekly").
    public let periodLabel: String?
    /// Product row used for the bar, typically "GrokBuild".
    public let productLabel: String?

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
        onDemandEnabled: Bool? = nil,
        periodLabel: String? = nil,
        productLabel: String? = nil
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
        self.periodLabel = periodLabel
        self.productLabel = productLabel
    }

    public init(from decoder: Decoder) throws {
        if let typed = try? GrokCreditsDocument(from: decoder),
           typed.config != nil,
           let mapped = Self.fromCreditsDocument(typed) {
            self = mapped
            return
        }
        let top = try decoder.container(keyedBy: AnyCodingKey.self)
        let decoded = Self.decodeFields(from: top)
            ?? top.nestedFields(for: "data").flatMap(Self.decodeFields)
            ?? top.nestedFields(for: "billing").flatMap(Self.decodeFields)
            ?? top.nestedFields(for: "config").flatMap(Self.decodeFields)
            ?? Self()
        self = decoded
    }

    private static func fromCreditsDocument(_ doc: GrokCreditsDocument) -> GrokBillingResponse? {
        let cfg = doc.config
        let period = cfg?.currentPeriod
        let product = (cfg?.productUsage ?? []).first(where: {
            ($0.product ?? "").localizedCaseInsensitiveContains("grok")
        }) ?? cfg?.productUsage?.first
        let percent = cfg?.creditUsagePercent ?? doc.creditUsagePercent ?? product?.usagePercent
        let used = cfg?.used?.value ?? cfg?.includedUsed?.value ?? cfg?.totalUsed?.value
        let limit = cfg?.monthlyLimit?.value
        let start = Self.parseDate(cfg?.billingPeriodStart ?? period?.start)
        let end = Self.parseDate(cfg?.billingPeriodEnd ?? period?.end)
        let periodLabel = period?.type.map { KeyedDecodingContainer<AnyCodingKey>.humanizePeriod($0) }
        let response = GrokBillingResponse(
            creditUsagePercent: percent,
            monthlyLimit: limit,
            includedUsed: used ?? cfg?.includedUsed?.value,
            totalUsed: cfg?.totalUsed?.value,
            prepaidBalance: cfg?.prepaidBalance?.value,
            onDemandCap: cfg?.onDemandCap?.value,
            onDemandUsed: cfg?.onDemandUsed?.value,
            subscriptionTier: cfg?.subscriptionTier,
            billingPeriodStart: start,
            billingPeriodEnd: end,
            currentPeriod: periodLabel,
            isUnifiedBillingUser: cfg?.isUnifiedBillingUser,
            onDemandEnabled: nil,
            periodLabel: periodLabel,
            productLabel: product?.product
        )
        if response.creditUsagePercent == nil
            && response.monthlyLimit == nil
            && response.includedUsed == nil
            && response.billingPeriodEnd == nil {
            return nil
        }
        return response
    }

    static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return KeyedDecodingContainer<AnyCodingKey>.parseISO8601(raw)
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
        let raw = creditUsagePercent
        guard let raw else { return nil }
        let value = raw > 1.0 ? raw / 100.0 : raw
        return min(1.0, max(0.0, value))
    }

    private func percentAsUsed(of limit: Double) -> Double? {
        normalizedPercent.map { $0 * limit }
    }

    // MARK: - Decode helpers

    private static func decodeFields(from c: KeyedDecodingContainer<AnyCodingKey>) -> GrokBillingResponse? {
        let period = c.decodePeriod()
        let product = c.decodeProductUsage()
        let percent = c.decodeFlexibleDouble("creditUsagePercent", "credit_usage_percent")
            ?? product.percent
        let response = GrokBillingResponse(
            creditUsagePercent: percent,
            monthlyLimit: c.decodeFlexibleDouble("monthlyLimit", "monthly_limit"),
            includedUsed: c.decodeFlexibleDouble("includedUsed", "included_used", "used"),
            totalUsed: c.decodeFlexibleDouble("totalUsed", "total_used"),
            prepaidBalance: c.decodeFlexibleDouble("prepaidBalance", "prepaid_balance"),
            onDemandCap: c.decodeFlexibleDouble("onDemandCap", "on_demand_cap"),
            onDemandUsed: c.decodeFlexibleDouble("onDemandUsed", "on_demand_used"),
            subscriptionTier: c.decodeFlexibleString("subscriptionTier", "subscription_tier"),
            billingPeriodStart: c.decodeFlexibleDate("billingPeriodStart", "billing_period_start")
                ?? period.start,
            billingPeriodEnd: c.decodeFlexibleDate("billingPeriodEnd", "billing_period_end")
                ?? period.end,
            currentPeriod: period.label,
            isUnifiedBillingUser: c.decodeFlexibleBool("isUnifiedBillingUser", "is_unified_billing_user"),
            onDemandEnabled: c.decodeFlexibleBool("onDemandEnabled", "on_demand_enabled"),
            periodLabel: period.label,
            productLabel: product.label
        )
        if response.creditUsagePercent == nil
            && response.monthlyLimit == nil
            && response.includedUsed == nil
            && response.totalUsed == nil
            && response.prepaidBalance == nil
            && response.subscriptionTier == nil
            && response.billingPeriodEnd == nil {
            return nil
        }
        return response
    }
}

/// Typed live `/billing?format=credits` (and bare `/billing`) envelope.
private struct GrokCreditsDocument: Decodable {
    let config: Config?
    let creditUsagePercent: Double?

    struct Config: Decodable {
        let creditUsagePercent: Double?
        let currentPeriod: Period?
        let productUsage: [Row]?
        let billingPeriodStart: String?
        let billingPeriodEnd: String?
        let monthlyLimit: FlexAmount?
        let used: FlexAmount?
        let includedUsed: FlexAmount?
        let totalUsed: FlexAmount?
        let prepaidBalance: FlexAmount?
        let onDemandCap: FlexAmount?
        let onDemandUsed: FlexAmount?
        let isUnifiedBillingUser: Bool?
        let subscriptionTier: String?
    }

    struct Period: Decodable {
        let type: String?
        let start: String?
        let end: String?
    }

    struct Row: Decodable {
        let product: String?
        let usagePercent: Double?
    }
}

/// Number or `{ "val": N }` box used by the billing service.
private struct FlexAmount: Decodable {
    let value: Double

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer() {
            if let d = try? single.decode(Double.self) { value = d; return }
            if let i = try? single.decode(Int.self) { value = Double(i); return }
        }
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        if let d = try c.decodeIfPresent(Double.self, forKey: AnyCodingKey("val")) {
            value = d; return
        }
        if let i = try c.decodeIfPresent(Int.self, forKey: AnyCodingKey("val")) {
            value = Double(i); return
        }
        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath, debugDescription: "FlexAmount")
        )
    }
}

/// One `config.productUsage[]` row from the live billing payload.
struct GrokProductUsageRow: Decodable, Sendable, Equatable {
    let product: String?
    let usagePercent: Double?

    private enum CodingKeys: String, CodingKey {
        case product
        case usagePercent
        case usage_percent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        product = try c.decodeIfPresent(String.self, forKey: .product)
        usagePercent = try c.decodeIfPresent(Double.self, forKey: .usagePercent)
            ?? c.decodeIfPresent(Double.self, forKey: .usage_percent)
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
            // Live wire wraps money/caps as `{ "val": 0 }`.
            if let nested = try? nestedContainer(keyedBy: AnyCodingKey.self, forKey: k) {
                if let v = try? nested.decodeIfPresent(Double.self, forKey: AnyCodingKey("val")) { return v }
                if let v = try? nested.decodeIfPresent(Int.self, forKey: AnyCodingKey("val")) { return Double(v) }
            }
        }
        return nil
    }

    func decodePeriod() -> (label: String?, start: Date?, end: Date?) {
        if let s = decodeFlexibleString("currentPeriod", "current_period") {
            return (Self.humanizePeriod(s), nil, nil)
        }
        for key in ["currentPeriod", "current_period"] {
            guard let nested = try? nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey(key)) else {
                continue
            }
            let type = (try? nested.decodeIfPresent(String.self, forKey: AnyCodingKey("type")))
            let start = nested.decodeDateValue(for: "start")
            let end = nested.decodeDateValue(for: "end")
            return (type.map(Self.humanizePeriod), start, end)
        }
        return (nil, nil, nil)
    }

    func decodeProductUsage() -> (label: String?, percent: Double?) {
        for key in ["productUsage", "product_usage"] {
            guard let rows = try? decodeIfPresent([GrokProductUsageRow].self, forKey: AnyCodingKey(key)),
                  !rows.isEmpty
            else { continue }
            let preferred = rows.first(where: { ($0.product ?? "").localizedCaseInsensitiveContains("grok") })
                ?? rows.first
            return (preferred?.product, preferred?.usagePercent)
        }
        return (nil, nil)
    }

    func decodeDateValue(for key: String) -> Date? {
        if let s = try? decodeIfPresent(String.self, forKey: AnyCodingKey(key)) {
            return Self.parseISO8601(s)
        }
        return nil
    }

    static func humanizePeriod(_ raw: String) -> String {
        let upper = raw.uppercased()
        if upper.contains("WEEKLY") { return "weekly" }
        if upper.contains("MONTHLY") { return "monthly" }
        if upper.contains("DAILY") { return "daily" }
        if upper.contains("HOURLY") { return "hourly" }
        return raw
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
        let variants: [ISO8601DateFormatter.Options] = [
            [.withInternetDateTime, .withFractionalSeconds, .withColonSeparatorInTimeZone],
            [.withInternetDateTime, .withFractionalSeconds],
            [.withInternetDateTime, .withColonSeparatorInTimeZone],
            [.withInternetDateTime],
        ]
        for options in variants {
            let f = ISO8601DateFormatter()
            f.formatOptions = options
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}
