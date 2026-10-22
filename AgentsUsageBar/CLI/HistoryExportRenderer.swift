import Foundation

/// `aub stats --json` and `--csv` (SPEC V47–V49). The dashboard Export… uses the same
/// renderer, so the bytes match for the same scope.
///
/// Spend and API-equivalent value come from `DayRecord.costSplit` and never share a field
/// (V26). `backfillChecked`, the account salt, and budgets are never exported (V48).
public enum HistoryExportRenderer {
    public static let schemaVersion = 1

    /// The CSV tables, one per run (V49).
    public enum CSVTable: String, Sendable, Equatable, CaseIterable {
        case days, accounts, events, quota
    }

    /// What one export covers: every key in `range`, one provider or all.
    public struct Scope: Sendable {
        public var range: StatsRange
        public var provider: ProviderID?
        /// Whether a provider is enabled; an enabled provider with no record on a day is a gap.
        public var isEnabled: @Sendable (ProviderID) -> Bool

        public init(range: StatsRange, provider: ProviderID? = nil, isEnabled: @escaping @Sendable (ProviderID) -> Bool = { _ in true }) {
            self.range = range
            self.provider = provider
            self.isEnabled = isEnabled
        }
    }

    // MARK: - JSON (V48)

    public static func json(_ days: [DayFile], scope: Scope, exportedAt: Date) throws -> String {
        let export = Export(
            schemaVersion: schemaVersion,
            exportedAt: exportedAt,
            range: .init(from: scope.range.keys[0], to: scope.range.keys[scope.range.keys.count - 1]),
            days: exportDays(days, scope: scope)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(export), as: UTF8.self) + "\n"
    }

    // MARK: - CSV (V49)

    /// Column sets are fixed for `schemaVersion` 1. Columns may be appended; a rename or
    /// removal bumps the version.
    static func columns(_ table: CSVTable) -> [String] {
        switch table {
        case .days:
            ["date", "provider", "tokens", "costUSD", "valueUSD", "costEstimated", "balanceUSD",
             "billingModel", "origin", "sealed", "firstSeen", "lastSeen"]
        case .accounts:
            ["date", "provider", "account", "label", "billingModel", "plan"]
        case .events:
            ["date", "time", "provider", "kind", "window", "account", "fraction", "notified", "carriedOver"]
        case .quota:
            ["date", "provider", "account", "window", "peak", "peakResetsAt", "endOfDay"]
        }
    }

    /// A gap is a missing row, an unknown value an empty cell, money a plain number.
    public static func csv(_ days: [DayFile], scope: Scope, table: CSVTable) -> String {
        var rows = [columns(table)]
        for day in exportDays(days, scope: scope) {
            switch table {
            case .days:
                rows += day.records.map { r -> [String] in
                    [day.date, r.provider.rawValue, int(r.tokens), money(r.costUSD), money(r.valueUSD),
                     bool(r.costEstimated), money(r.balanceUSD), text(r.billingModel), r.origin.rawValue,
                     bool(day.sealed), date(r.firstSeen), date(r.lastSeen)]
                }
            case .accounts:
                rows += day.records.flatMap { r in
                    r.accounts.map { a -> [String] in
                        [day.date, r.provider.rawValue, a.key, a.label, a.billingModel.rawValue, text(a.plan)]
                    }
                }
            case .events:
                rows += day.events.map(\.event).map { e -> [String] in
                    [day.date, date(e.time), text(e.provider?.rawValue), e.kind.rawValue, text(e.window),
                     text(e.account), double(e.fraction), bool(e.notified), bool(e.carriedOver)]
                }
            case .quota:
                rows += day.quotaRows.map { q -> [String] in
                    [day.date, q.provider.rawValue, text(q.account), q.window, double(q.day.peak),
                     date(q.day.peakResetsAt), double(q.day.endOfDay)]
                }
            }
        }
        return rows.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    // MARK: - Shape

    struct Export: Encodable {
        var schemaVersion: Int
        var exportedAt: Date
        var range: Range
        var days: [Day]

        struct Range: Encodable {
            var from: String
            var to: String
        }
    }

    struct Day: Encodable {
        var date: String
        /// Nil when the day has no file.
        var timeZone: String?
        var sealed: Bool
        var records: [Record]
        var events: [Event]
        var gaps: [ProviderID]

        /// Record-level quota windows have no account; account windows name the account key.
        var quotaRows: [(provider: ProviderID, account: String?, window: String, day: QuotaDay)] {
            records.flatMap { r in
                r.quota.sorted { $0.key < $1.key }.map { (r.provider, nil, $0.key, $0.value) }
                    + r.accountQuota.flatMap { key, windows in
                        windows.sorted { $0.key < $1.key }.map { (r.provider, key, $0.key, $0.value) }
                    }
            }
        }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(date, forKey: .date)
            try c.encode(timeZone, forKey: .timeZone)
            try c.encode(sealed, forKey: .sealed)
            try c.encode(records, forKey: .records)
            try c.encode(events, forKey: .events)
            try c.encode(gaps, forKey: .gaps)
        }

        enum CodingKeys: String, CodingKey {
            case date, timeZone, sealed, records, events, gaps
        }
    }

    /// A day record as exported: spend in `costUSD`, subscription value in `valueUSD` (V26).
    /// Unknown values encode as `null`, never 0.
    struct Record: Encodable {
        var provider: ProviderID
        var tokens: Int?
        var costUSD: Money?
        var valueUSD: Money?
        var costEstimated: Bool
        var balanceUSD: Money?
        /// `metered`, `subscription`, `local`, or `mixed` for metered plus subscription.
        var billingModel: String?
        var quota: [String: QuotaDay]
        var accounts: [Account]
        /// Not encoded in JSON, whose accounts carry only key, label, model, and plan (V48).
        var accountQuota: [(key: String, quota: [String: QuotaDay])]
        var origin: RecordOrigin
        var firstSeen: Date?
        var lastSeen: Date?

        init(_ record: DayRecord) {
            let split = record.costSplit
            provider = record.provider
            tokens = record.tokens
            costUSD = split.spend
            valueUSD = split.value
            costEstimated = record.costEstimated
            balanceUSD = record.balanceUSD
            let models = Set(record.accounts.map(\.billingModel))
            billingModel = models.count > 1 ? (models == [.metered, .subscription] ? "mixed" : nil) : models.first?.rawValue
            quota = record.quota
            accounts = record.accounts.map { Account(key: $0.key, label: $0.label, billingModel: $0.billingModel, plan: $0.plan) }
            accountQuota = record.accounts.filter { !$0.quota.isEmpty }.map { ($0.key, $0.quota) }
            origin = record.origin
            firstSeen = record.firstSeen
            lastSeen = record.lastSeen
        }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(provider, forKey: .provider)
            try c.encode(tokens, forKey: .tokens)
            try c.encode(costUSD, forKey: .costUSD)
            try c.encode(valueUSD, forKey: .valueUSD)
            try c.encode(costEstimated, forKey: .costEstimated)
            try c.encode(balanceUSD, forKey: .balanceUSD)
            try c.encode(billingModel, forKey: .billingModel)
            try c.encode(quota.mapValues(Window.init), forKey: .quota)
            try c.encode(accounts, forKey: .accounts)
            try c.encode(origin, forKey: .origin)
            try c.encode(firstSeen, forKey: .firstSeen)
            try c.encode(lastSeen, forKey: .lastSeen)
        }

        enum CodingKeys: String, CodingKey {
            case provider, tokens, costUSD, valueUSD, costEstimated, balanceUSD, billingModel, quota,
                 accounts, origin, firstSeen, lastSeen
        }
    }

    struct Account: Encodable {
        var key: String
        var label: String
        var billingModel: BillingModel
        var plan: String?

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(key, forKey: .key)
            try c.encode(label, forKey: .label)
            try c.encode(billingModel, forKey: .billingModel)
            try c.encode(plan, forKey: .plan)
        }

        enum CodingKeys: String, CodingKey {
            case key, label, billingModel, plan
        }
    }

    struct Window: Encodable {
        var peak: Double
        var peakResetsAt: Date?
        var endOfDay: Double

        init(_ day: QuotaDay) {
            peak = day.peak
            peakResetsAt = day.peakResetsAt
            endOfDay = day.endOfDay
        }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(peak, forKey: .peak)
            try c.encode(peakResetsAt, forKey: .peakResetsAt)
            try c.encode(endOfDay, forKey: .endOfDay)
        }

        enum CodingKeys: String, CodingKey {
            case peak, peakResetsAt, endOfDay
        }
    }

    struct Event: Encodable {
        var event: UsageEvent

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(event.time, forKey: .time)
            try c.encode(event.provider, forKey: .provider)
            try c.encode(event.kind, forKey: .kind)
            try c.encode(event.window, forKey: .window)
            try c.encode(event.account, forKey: .account)
            try c.encode(event.fraction, forKey: .fraction)
            try c.encode(event.notified, forKey: .notified)
            try c.encode(event.carriedOver, forKey: .carriedOver)
        }

        enum CodingKeys: String, CodingKey {
            case time, provider, kind, window, account, fraction, notified, carriedOver
        }
    }

    /// One entry per range key, oldest first. A day without a file has no zone and every
    /// enabled provider as a gap. The gap set is the enabled providers seen in range, so a
    /// provider never configured is not a gap every day. Today is the one unsealed day (V16).
    static func exportDays(_ days: [DayFile], scope: Scope) -> [Day] {
        let byKey = Dictionary(days.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
        let inScope: (ProviderID?) -> Bool = { scope.provider == nil || $0 == scope.provider }
        let seen = Set(scope.range.keys.flatMap { byKey[$0]?.records.map(\.provider) ?? [] })
        let tracked = seen.union(scope.provider.map { [$0] } ?? []).filter { inScope($0) && scope.isEnabled($0) }
        return scope.range.keys.map { key in
            let file = byKey[key]
            let records = (file?.records ?? []).filter { inScope($0.provider) }
            let present = Set(records.map(\.provider))
            return Day(
                date: key,
                timeZone: file?.timeZone,
                sealed: key < scope.range.today,
                records: records.sorted { $0.provider.rawValue < $1.provider.rawValue }.map(Record.init),
                events: (file?.events ?? []).filter { inScope($0.provider) }.map(Event.init),
                gaps: tracked.subtracting(present).sorted { $0.rawValue < $1.rawValue }
            )
        }
    }

    // MARK: - Cells

    private static func int(_ value: Int?) -> String { value.map(String.init) ?? "" }
    private static func double(_ value: Double?) -> String { value.map { "\($0)" } ?? "" }
    private static func bool(_ value: Bool) -> String { value ? "true" : "false" }
    private static func text(_ value: String?) -> String { value ?? "" }
    private static func money(_ value: Money?) -> String { value?.amount.description ?? "" }
    private static func date(_ value: Date?) -> String { value?.formatted(.iso8601) ?? "" }

    /// RFC 4180 quoting for a field holding a comma, quote, or line break.
    private static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
