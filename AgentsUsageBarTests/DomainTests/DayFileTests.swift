import Testing
import Foundation
@testable import AgentsUsageBar

@Suite("DayFileTests")
struct DayFileTests {

    /// A day file with every I16 field set, from synthetic values (C3).
    static func fullDay() -> DayFile {
        let resets = Date(timeIntervalSince1970: 1_792_000_000)
        let seen = Date(timeIntervalSince1970: 1_791_990_000)
        return DayFile(
            date: "2026-10-22",
            timeZone: "Asia/Bangkok",
            records: [
                DayRecord(
                    provider: .claude,
                    tokens: 120_000,
                    costUSD: Money(Decimal(string: "12.10")!),
                    costEstimated: true,
                    balanceUSD: nil,
                    quota: ["5h": QuotaDay(peak: 0.92, peakResetsAt: resets, endOfDay: 0.40)],
                    accounts: [
                        DayAccount(
                            key: "work", label: "work", billingModel: .subscription, plan: "max",
                            billingModelAssumed: false, costUSD: Money(5),
                            quota: ["5h": QuotaDay(peak: 0.92, peakResetsAt: resets, endOfDay: 0.40)])
                    ],
                    origin: .observed, firstSeen: seen, lastSeen: resets),
                DayRecord(provider: .ollama, origin: .observed, firstSeen: seen, lastSeen: seen),
            ],
            events: [
                UsageEvent(time: seen, provider: .claude, kind: .band80, window: "5h", account: "work",
                           fraction: 0.81, notified: true, carriedOver: false),
                UsageEvent(time: seen, provider: nil, kind: .budgetLimit, fraction: 1.0, notified: false),
            ],
            backfillChecked: [.codex])
    }

    @Test("full v1 day file round trips (I16)")
    func fullDayRoundTrips() throws {
        let day = Self.fullDay()
        #expect(DayFile.decode(try day.encoded()) == .file(day))
    }

    @Test("v1 JSON carries the I16 field names, money as decimal strings")
    func encodedShape() throws {
        let json = try #require(
            JSONSerialization.jsonObject(with: try Self.fullDay().encoded()) as? [String: Any])
        #expect(Set(json.keys) == ["schemaVersion", "date", "timeZone", "records", "events", "backfillChecked"])
        #expect(json["schemaVersion"] as? Int == 1)

        let record = try #require((json["records"] as? [[String: Any]])?.first)
        #expect(Set(record.keys) == [
            "provider", "tokens", "costUSD", "costEstimated", "quota", "accounts", "origin",
            "firstSeen", "lastSeen",
        ])
        #expect(record["costUSD"] as? String == "12.1")
        let window = try #require((record["quota"] as? [String: [String: Any]])?["5h"])
        #expect(Set(window.keys) == ["peak", "peakResetsAt", "endOfDay"])

        let account = try #require((record["accounts"] as? [[String: Any]])?.first)
        #expect(Set(account.keys) == [
            "key", "label", "billingModel", "plan", "billingModelAssumed", "costUSD", "quota",
        ])
        #expect(account["costUSD"] as? String == "5")

        let event = try #require((json["events"] as? [[String: Any]])?.first)
        #expect(Set(event.keys) == [
            "time", "provider", "kind", "window", "account", "fraction", "notified", "carriedOver",
        ])
    }

    @Test("unknown totals stay nil, never zero (V7)")
    func nilTotalsStayNil() throws {
        let local = try #require(Self.fullDay().records.last)
        guard case .file(let decoded) = DayFile.decode(try DayFile(
            date: "2026-10-22", timeZone: "UTC", records: [local]).encoded())
        else { Issue.record("decode failed"); return }
        #expect(decoded.records[0].tokens == nil)
        #expect(decoded.records[0].costUSD == nil)
    }

    @Test("money keeps exact decimals")
    func moneyIsExact() throws {
        let data = try JSONEncoder().encode([Money(Decimal(string: "0.1")! + Decimal(string: "0.2")!)])
        #expect(String(decoding: data, as: UTF8.self) == #"["0.3"]"#)
        #expect(try JSONDecoder().decode([Money].self, from: Data(#"["11.40"]"#.utf8))
            == [Money(Decimal(string: "11.4")!)])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([Money].self, from: Data("[11.4]".utf8))
        }
    }

    @Test("newer or unknown schemaVersion is unsupported (V18)", arguments: [0, 2, 99])
    func unsupportedVersion(_ version: Int) {
        let data = Data(#"{"schemaVersion": \#(version), "date": "2026-10-22"}"#.utf8)
        #expect(DayFile.decode(data) == .unsupported(schemaVersion: version))
    }

    @Test("malformed or incomplete files are unreadable (V18)", arguments: [
        "not json",
        #"{"date": "2026-10-22"}"#,
        #"{"schemaVersion": 1, "date": "2026-10-22"}"#,
    ])
    func unreadable(_ text: String) {
        #expect(DayFile.decode(Data(text.utf8)) == .unreadable)
    }
}
