import Foundation
@testable import AgentsUsageBar

/// Generated history for fixtures and golden tests (SPEC C3). Fake slugs and round
/// numbers only: no real spend, account name, email, account id, or token. The same
/// arguments always give the same days, so golden output is stable.
///
/// Every day covers each billing model (V25, V26):
/// - OpenRouter: metered, reported cost and a balance.
/// - Claude: two ccs slugs on subscription plans, token-priced value, a `5h` and a `7d`
///   window. Every 7th day is a gap with no Claude record.
/// - Codex: mixed, one metered and one subscription account with salted-looking keys,
///   estimated cost. Every 5th day is backfilled, so it has no quota or seen times (V30).
/// - Ollama: local, nil totals (V11).
///
/// A Claude `5h` peak at or over 80% adds a `band80` event.
enum SyntheticHistory {
    static let timeZone = "UTC"

    /// `count` days ending at `lastKey` (a `yyyy-MM-dd` day key), oldest first.
    static func days(endingAt lastKey: String, count: Int) -> [DayFile] {
        let last = dayFormatter.date(from: lastKey)!
        return (0..<count).map { offset in
            let date = calendar.date(byAdding: .day, value: offset - count + 1, to: last)!
            return day(dayFormatter.string(from: date), start: date, index: offset)
        }
    }

    /// Writes each day as `<date>.json` the way `HistoryStore` encodes it.
    static func write(_ days: [DayFile], to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for day in days {
            try day.encoded().write(to: directory.appending(path: "\(day.date).json"))
        }
    }

    private static let calendar: Calendar = {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: timeZone)!
        return gregorian
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let peaks = [0.25, 0.5, 0.85, 0.96, 1.0]

    private static func day(_ key: String, start: Date, index: Int) -> DayFile {
        let firstSeen = start.addingTimeInterval(9 * 3600)
        let lastSeen = start.addingTimeInterval(18 * 3600)
        let resetsAt = start.addingTimeInterval(14 * 3600)
        var records: [DayRecord] = []
        var events: [UsageEvent] = []

        records.append(DayRecord(
            provider: ProviderID(rawValue: "openrouter"),
            tokens: 10_000 * (index % 5 + 1),
            costUSD: money(index % 4, quarters: 2),
            balanceUSD: money(20 - index % 10),
            accounts: [DayAccount(key: "default", label: "default", billingModel: .metered)],
            origin: .observed, firstSeen: firstSeen, lastSeen: lastSeen
        ))

        if index % 7 != 6 {
            let peak = peaks[index % peaks.count]
            let fiveHour = QuotaDay(peak: peak, peakResetsAt: resetsAt, endOfDay: peak / 2)
            let sevenDay = QuotaDay(peak: 0.1 * Double(index % 8 + 1), endOfDay: 0.1 * Double(index % 8 + 1))
            records.append(DayRecord(
                provider: ProviderID(rawValue: "claude"),
                tokens: 100_000 * (index % 3 + 1),
                costUSD: money(5 * (index % 3 + 1)),
                costEstimated: true,
                quota: ["5h": fiveHour, "7d": sevenDay],
                accounts: [
                    DayAccount(key: "work-demo", label: "work-demo", billingModel: .subscription, plan: "max",
                               costUSD: money(4 * (index % 3 + 1)), quota: ["5h": fiveHour]),
                    DayAccount(key: "default", label: "default", billingModel: .subscription, plan: "pro",
                               costUSD: money(index % 3 + 1), quota: ["5h": QuotaDay(peak: 0.25, endOfDay: 0.25)]),
                ],
                origin: .observed, firstSeen: firstSeen, lastSeen: lastSeen
            ))
            if peak >= 0.8 {
                events.append(UsageEvent(time: start.addingTimeInterval(12 * 3600), provider: ProviderID(rawValue: "claude"),
                                         kind: .band80, window: "5h", fraction: peak, notified: true))
            }
        }

        let backfilled = index % 5 == 4
        records.append(DayRecord(
            provider: ProviderID(rawValue: "codex"),
            tokens: 50_000 * (index % 4 + 1),
            costUSD: money(index % 4 + 1),
            costEstimated: true,
            quota: backfilled ? [:] : ["5h": QuotaDay(peak: 0.5, endOfDay: 0.25)],
            accounts: [
                DayAccount(key: "a1b2c3d4e5f6", label: "acct-a1b2", billingModel: .metered, billingModelAssumed: backfilled),
                DayAccount(key: "f6e5d4c3b2a1", label: "plus", billingModel: .subscription, plan: "plus",
                           billingModelAssumed: backfilled),
            ],
            origin: backfilled ? .backfilled : .observed,
            firstSeen: backfilled ? nil : firstSeen,
            lastSeen: backfilled ? nil : lastSeen
        ))

        records.append(DayRecord(
            provider: ProviderID(rawValue: "ollama"),
            accounts: [DayAccount(key: "default", label: "default", billingModel: .local)],
            origin: .observed, firstSeen: firstSeen, lastSeen: lastSeen
        ))

        records.sort { $0.provider.rawValue < $1.provider.rawValue }
        return DayFile(date: key, timeZone: timeZone, records: records, events: events)
    }

    /// Whole dollars plus `quarters` × $0.25.
    private static func money(_ dollars: Int, quarters: Int = 0) -> Money {
        Money(Decimal(dollars) + Decimal(quarters) / 4)
    }
}
