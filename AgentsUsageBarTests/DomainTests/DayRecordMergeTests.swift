import Testing
import Foundation
@testable import AgentsUsageBar

@Suite("DayRecordMergeTests")
struct DayRecordMergeTests {

    static let t1 = Date(timeIntervalSince1970: 1_792_000_000)
    static let t2 = t1.addingTimeInterval(300)
    static let t3 = t1.addingTimeInterval(600)
    /// Stands in for the salted hash: unique per test id, never containing the raw id.
    static let fakeKey: @Sendable (String) -> String = { "h\($0.count)\($0.last.map(String.init) ?? "")" }

    static func sample(
        _ provider: String = "openrouter",
        tokens: Int? = nil,
        cost: Decimal? = nil,
        balance: Decimal? = nil,
        quota: Quota? = nil,
        windows: [QuotaWindow]? = nil
    ) -> UsageSnapshot {
        UsageSnapshot(
            providerID: ProviderID(rawValue: provider), asOf: t1, tokensToday: tokens,
            costTodayUSD: cost, balanceUSD: balance, quota: quota, raw: [:], quotaWindows: windows
        )
    }

    private func fold(_ samples: UsageSnapshot...) -> DayRecord {
        var record = DayRecord(provider: samples[0].providerID, origin: .observed)
        for (index, sample) in samples.enumerated() {
            record = record.merging(sample, at: Self.t1.addingTimeInterval(Double(index) * 300), accountKey: Self.fakeKey)
        }
        return record
    }

    @Test("totals keep the highest value; a degraded poll cannot shrink them (V7)")
    func totalsKeepHighest() {
        let record = fold(
            Self.sample(tokens: 100, cost: Decimal(string: "1.50")),
            Self.sample(tokens: nil, cost: Decimal(string: "0.20")),
            Self.sample(tokens: 80, cost: nil)
        )
        #expect(record.tokens == 100)
        #expect(record.costUSD == Money(Decimal(string: "1.50")!))
    }

    @Test("unknown totals stay nil, never zero (V7)")
    func unknownStaysNil() {
        let record = fold(Self.sample("ollama"), Self.sample("ollama"))
        #expect(record.tokens == nil)
        #expect(record.costUSD == nil)
        #expect(record.quota.isEmpty)
    }

    @Test("balance keeps the last value seen; nil keeps the prior one (V7)")
    func balanceKeepsLast() {
        let record = fold(Self.sample(balance: 10), Self.sample(balance: 7), Self.sample(balance: nil))
        #expect(record.balanceUSD == Money(7))
    }

    @Test("quota keeps peak with its resetsAt, and the last value as end of day (V8)")
    func quotaPeakAndEndOfDay() {
        let resetA = Self.t1.addingTimeInterval(3600)
        let resetB = Self.t1.addingTimeInterval(7200)
        let record = fold(
            Self.sample("claude", windows: [QuotaWindow(name: "5h", utilization: 0.4, resetsAt: resetA)]),
            Self.sample("claude", windows: [QuotaWindow(name: "5h", utilization: 0.9, resetsAt: resetA)]),
            // The window reset mid-day: the day keeps its highest value (V8).
            Self.sample("claude", windows: [QuotaWindow(name: "5h", utilization: 0.1, resetsAt: resetB),
                                            QuotaWindow(name: "7d", utilization: 0.3, resetsAt: nil),
                                            QuotaWindow(name: "7d-opus", utilization: nil, resetsAt: nil)])
        )
        #expect(record.quota["5h"] == QuotaDay(peak: 0.9, peakResetsAt: resetA, endOfDay: 0.1))
        #expect(record.quota["7d"] == QuotaDay(peak: 0.3, endOfDay: 0.3))
        #expect(record.quota["7d-opus"] == nil)
    }

    @Test("a single quota with no windows is filed under `quota` (V8)")
    func providerQuotaWindow() {
        let record = fold(Self.sample(quota: Quota(used: 3, limit: 4, remaining: 1)))
        #expect(record.quota[UsageSnapshot.providerQuotaWindow] == QuotaDay(peak: 0.75, endOfDay: 0.75))
    }

    @Test("firstSeen is the first good sample, lastSeen the latest (V10)")
    func seenTimes() {
        let record = fold(Self.sample(tokens: 1), Self.sample(tokens: 1), Self.sample(tokens: 1))
        #expect(record.firstSeen == Self.t1)
        #expect(record.lastSeen == Self.t3)
        #expect(record.origin == .observed)
    }

    @Test("day merge: one record per provider, last zone, seen times ignored by the change check (V6, V11, V15)")
    func dayMerge() {
        let empty = DayFile(date: "2026-10-22", timeZone: "Asia/Bangkok")
        let first = empty.merging([Self.sample(tokens: 5), Self.sample("ollama")], at: Self.t1, timeZone: "Asia/Bangkok", accountKey: Self.fakeKey)
        #expect(first.records.map(\.provider.rawValue) == ["ollama", "openrouter"])

        let again = first.merging([Self.sample(tokens: 5)], at: Self.t2, timeZone: "Asia/Bangkok", accountKey: Self.fakeKey)
        #expect(again.records.count == 2)
        #expect(again != first)
        #expect(again.hasSameContent(as: first))

        let moved = again.merging([Self.sample(tokens: 5)], at: Self.t3, timeZone: "Asia/Tokyo", accountKey: Self.fakeKey)
        #expect(moved.timeZone == "Asia/Tokyo")
        #expect(!moved.hasSameContent(as: again))

        #expect(first.merging([], at: Self.t3, timeZone: "UTC", accountKey: Self.fakeKey) == first)
    }

    // MARK: - Accounts (V9, V10, V21, V22, V25)

    static func codexAccount(_ name: String, id: String?, plan: String?) -> UsageSnapshot.AccountUsage {
        UsageSnapshot.AccountUsage(
            name: name, costTodayUSD: nil, quota: nil,
            quotaWindows: [QuotaWindow(name: "primary", utilization: 0.5, resetsAt: nil)],
            accountInfo: AccountInfo(billingModel: .subscription, plan: plan, accountID: id))
    }

    @Test("a provider without accounts is one default account with its fixed billing model (V9, V25)")
    func implicitAccount() {
        let metered = fold(Self.sample(cost: 2, quota: Quota(used: 1, limit: 4, remaining: 3)))
        #expect(metered.accounts == [DayAccount(
            key: "default", label: "default", billingModel: .metered,
            quota: [UsageSnapshot.providerQuotaWindow: QuotaDay(peak: 0.25, endOfDay: 0.25)])])
        #expect(metered.accounts[0].costUSD == nil)
        #expect(fold(Self.sample("ollama")).accounts.map(\.billingModel) == [.local])

        var gemini = Self.sample("gemini")
        gemini.accountInfo = AccountInfo(billingModel: .subscription, plan: "Standard")
        #expect(fold(gemini).accounts.map(\.label) == ["default"])
        #expect(fold(gemini).accounts.map(\.plan) == ["Standard"])
    }

    @Test("Claude accounts keep slug keys and labels, plan, billing model, and reported cost (V9, V22, V25)")
    func claudeAccounts() {
        var sample = Self.sample("claude", cost: 3)
        sample.accounts = [
            UsageSnapshot.AccountUsage(
                name: "default", costTodayUSD: 1, quota: nil,
                quotaWindows: [QuotaWindow(name: "5h", utilization: 0.2, resetsAt: nil)],
                accountInfo: AccountInfo(billingModel: .subscription, plan: "max")),
            UsageSnapshot.AccountUsage(name: "work", costTodayUSD: 2, quota: nil, quotaWindows: nil),
        ]
        let record = fold(sample)
        #expect(record.accounts.map(\.key) == ["default", "work"])
        #expect(record.accounts.map(\.label) == ["default", "work"])
        #expect(record.accounts.map(\.billingModel) == [.subscription, .metered])
        #expect(record.accounts[0].plan == "max")
        #expect(record.accounts.map(\.costUSD) == [Money(1), Money(2)])
        #expect(record.accounts[0].quota["5h"] == QuotaDay(peak: 0.2, endOfDay: 0.2))
    }

    @Test("Codex keys hash the account id; labels are never an email or the raw id (V21, V22)")
    func codexLabels() {
        var sample = Self.sample("codex")
        sample.accounts = [
            Self.codexAccount("pro", id: "id-one", plan: "pro"),
            Self.codexAccount("a@example.com", id: "id-two", plan: "plus"),
            Self.codexAccount("b@example.com", id: "id-three", plan: "team"),
            Self.codexAccount("acct-id-four", id: "id-four", plan: "team"),
        ]
        let record = fold(sample)
        let labels = Dictionary(uniqueKeysWithValues: record.accounts.map { ($0.key, $0.label) })
        // Live plan label kept; email → unique plan; email or raw-id label with a shared plan → key prefix.
        #expect(labels == ["h6e": "pro", "h6o": "plus", "h8e": "acct-h8e", "h7r": "acct-h7r"])
        #expect(record.accounts.allSatisfy { $0.billingModel == .subscription })
    }

    @Test("the hashed key is stable per salt and changes with the salt (V21)")
    func saltedKey() {
        let salt = Data(repeating: 7, count: 32)
        let key = DayAccount.key(forAccountID: "acct-123", salt: salt)
        #expect(key == DayAccount.key(forAccountID: "acct-123", salt: salt))
        #expect(key != DayAccount.key(forAccountID: "acct-123", salt: Data(repeating: 8, count: 32)))
        #expect(key.count == 12)
        #expect(!key.contains("123"))
    }

    @Test("an account merges across polls: newest label and plan, highest cost, quota peak (V7, V8, V25)")
    func accountMerge() {
        var first = Self.sample("claude")
        first.accounts = [UsageSnapshot.AccountUsage(
            name: "work", costTodayUSD: 5, quota: nil,
            quotaWindows: [QuotaWindow(name: "5h", utilization: 0.9, resetsAt: nil)],
            accountInfo: AccountInfo(billingModel: .subscription, plan: "pro"))]
        var second = Self.sample("claude")
        second.accounts = [UsageSnapshot.AccountUsage(
            name: "work", costTodayUSD: 3, quota: nil,
            quotaWindows: [QuotaWindow(name: "5h", utilization: 0.1, resetsAt: nil)],
            accountInfo: AccountInfo(billingModel: .subscription, plan: "max"))]
        let record = fold(first, second)
        #expect(record.accounts.count == 1)
        #expect(record.accounts[0].plan == "max")
        #expect(record.accounts[0].costUSD == Money(5))
        #expect(record.accounts[0].quota["5h"] == QuotaDay(peak: 0.9, endOfDay: 0.1))
    }

    @Test("costEstimated is set by any estimated cost sample, not by one without cost (V10)")
    func costEstimated() {
        var estimated = Self.sample("codex", cost: 1)
        estimated.costEstimated = true
        var noCost = Self.sample("codex")
        noCost.costEstimated = true
        #expect(fold(Self.sample("codex", cost: 1)).costEstimated == false)
        #expect(fold(noCost).costEstimated == false)
        #expect(fold(estimated, Self.sample("codex", cost: 2)).costEstimated == true)
    }


    @Test("account tokens take the newest known value; a backfill top-up keeps the higher; an old file reads nil (V9, V18, V31)")
    func accountTokens() throws {
        let low = DayAccount(key: "work", label: "work", billingModel: .subscription, tokens: 50)
        let high = DayAccount(key: "work", label: "work", billingModel: .subscription, tokens: 80)
        #expect(high.merging(low).tokens == 50)
        #expect(low.merging(DayAccount(key: "work", label: "work", billingModel: .subscription)).tokens == 50)

        let observed = DayRecord(provider: .claude, tokens: 100, accounts: [low], origin: .observed)
        let backfill = DayRecord(provider: .claude, tokens: 120, accounts: [high], origin: .backfilled)
        #expect(observed.toppedUp(by: backfill).accounts.map(\.tokens) == [80])

        let old = #"{"key":"work","label":"work","billingModel":"subscription","billingModelAssumed":false,"quota":{}}"#
        #expect(try JSONDecoder().decode(DayAccount.self, from: Data(old.utf8)).tokens == nil)
    }


    @Test("a session that changes owner between polls moves its tokens, never counted twice (V9, B15)")
    func ownerChangeMovesTokens() {
        func poll(work: Int, personal: Int) -> UsageSnapshot {
            var sample = Self.sample("claude", tokens: 50)
            sample.accounts = [
                UsageSnapshot.AccountUsage(name: "personal", costTodayUSD: nil, quota: nil, quotaWindows: nil, tokensToday: personal),
                UsageSnapshot.AccountUsage(name: "work", costTodayUSD: nil, quota: nil, quotaWindows: nil, tokensToday: work),
            ]
            return sample
        }
        let record = fold(poll(work: 50, personal: 0), poll(work: 0, personal: 50))
        #expect(record.accounts.map(\.key) == ["personal", "work"])
        #expect(record.accounts.map(\.tokens) == [50, 0])
        #expect(record.tokenSegments.map(\.tokens).reduce(0, +) == 50)
    }


    @Test("an account that drops out of a sample with account tokens goes to 0 (V9, B15)")
    func accountLeavingSampleGoesToZero() {
        func poll(_ owners: [String: Int]) -> UsageSnapshot {
            var sample = Self.sample("claude", tokens: 50)
            sample.accounts = owners.keys.sorted().map {
                UsageSnapshot.AccountUsage(name: $0, costTodayUSD: nil, quota: nil, quotaWindows: nil, tokensToday: owners[$0])
            }
            return sample
        }
        // personal owned S, then S's newest copy moved under work and personal left the feed.
        let record = fold(poll(["personal": 50]), poll(["work": 50]))
        #expect(record.accounts.map(\.key) == ["personal", "work"])
        #expect(record.accounts.map(\.tokens) == [0, 50])
        // A sample without account tokens (session reads) leaves them as they were.
        let kept = fold(poll(["personal": 50]), Self.sample("claude", tokens: 50))
        #expect(kept.accounts.first { $0.key == "personal" }?.tokens == 50)
    }
}
