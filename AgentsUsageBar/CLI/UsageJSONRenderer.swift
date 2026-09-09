import Foundation

public enum UsageJSONRenderer {
    public static func renderUsage(_ report: UsageReport) throws -> String {
        let doc = UsageJSONDocument(report: report, includeTotals: true)
        return try encode(doc)
    }

    public static func renderQuota(_ report: UsageReport) throws -> String {
        let rows = report.providers.map { QuotaJSONRow(report: $0) }
        return try encode(rows)
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}

private struct UsageJSONDocument: Encodable {
    let asOf: Date
    let source: String
    let totals: TotalsJSON
    let providers: [ProviderJSON]

    init(report: UsageReport, includeTotals: Bool) {
        self.asOf = report.asOf
        self.source = report.source.rawValue
        self.totals = TotalsJSON(totals: report.totals)
        self.providers = report.providers.map { ProviderJSON(report: $0) }
        _ = includeTotals
    }
}

private struct TotalsJSON: Encodable {
    let tokens: Int
    let costUSD: String
    init(totals: DailyTotals) {
        self.tokens = totals.tokens
        self.costUSD = NSDecimalNumber(decimal: totals.costUSD).stringValue
    }
}

private struct ProviderJSON: Encodable {
    let id: String
    let displayName: String
    let status: String
    let tokensToday: Int?
    let costTodayUSD: String?
    let balanceUSD: String?
    let quota: QuotaJSON?
    let quotaWindows: [WindowJSON]?
    let accounts: [AccountJSON]?
    let raw: [String: String]
    let error: String?

    init(report: ProviderReport) {
        self.id = report.id.rawValue
        self.displayName = report.displayName
        self.status = statusName(report.status)
        self.tokensToday = report.snapshot?.tokensToday
        self.costTodayUSD = report.snapshot?.costTodayUSD.map { NSDecimalNumber(decimal: $0).stringValue }
        self.balanceUSD = report.snapshot?.balanceUSD.map { NSDecimalNumber(decimal: $0).stringValue }
        self.quota = report.snapshot?.quota.map(QuotaJSON.init)
        self.quotaWindows = report.snapshot?.quotaWindows?.map(WindowJSON.init)
        self.accounts = report.snapshot?.accounts?.map(AccountJSON.init)
        self.raw = report.snapshot?.raw ?? [:]
        self.error = report.errorDescription
    }
}

private struct QuotaJSONRow: Encodable {
    let id: String
    let status: String
    let quota: QuotaJSON?
    let quotaWindows: [WindowJSON]?
    let error: String?

    init(report: ProviderReport) {
        self.id = report.id.rawValue
        self.status = statusName(report.status)
        self.quota = report.snapshot?.quota.map(QuotaJSON.init)
        self.quotaWindows = report.snapshot?.quotaWindows?.map(WindowJSON.init)
        self.error = report.errorDescription
    }
}

private struct QuotaJSON: Encodable {
    let used: Double
    let limit: Double
    let remaining: Double
    let fraction: Double
    init(_ q: Quota) {
        used = q.used
        limit = q.limit
        remaining = q.remaining
        fraction = q.fraction
    }
}

private struct WindowJSON: Encodable {
    let name: String
    let utilization: Double?
    let resetsAt: Date?
    init(_ w: QuotaWindow) {
        name = w.name
        utilization = w.utilization
        resetsAt = w.resetsAt
    }
}

private struct AccountJSON: Encodable {
    let name: String
    let costTodayUSD: String?
    let quota: QuotaJSON?
    let quotaWindows: [WindowJSON]?
    init(_ a: UsageSnapshot.AccountUsage) {
        name = a.name
        costTodayUSD = a.costTodayUSD.map { NSDecimalNumber(decimal: $0).stringValue }
        quota = a.quota.map(QuotaJSON.init)
        quotaWindows = a.quotaWindows?.map(WindowJSON.init)
    }
}

private func statusName(_ status: ProviderStatus) -> String {
    switch status {
    case .ok: return "ok"
    case .stale: return "stale"
    case .unauthenticated: return "unauthenticated"
    case .notRunning: return "notRunning"
    case .disabled: return "disabled"
    case .error: return "error"
    }
}
