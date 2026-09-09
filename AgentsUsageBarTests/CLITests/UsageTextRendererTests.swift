import Foundation
import Testing
@testable import AgentsUsageBar

@Suite("UsageTextRenderer")
struct UsageTextRendererTests {

    @Test("bar fill at 0 / 0.5 / 1 / nil")
    func barFill() {
        #expect(UsageTextRenderer.bar(consumed: 0) == String(repeating: "░", count: 20))
        #expect(UsageTextRenderer.bar(consumed: 0.5) == String(repeating: "█", count: 10) + String(repeating: "░", count: 10))
        #expect(UsageTextRenderer.bar(consumed: 1) == String(repeating: "█", count: 20))
        #expect(UsageTextRenderer.bar(consumed: nil) == String(repeating: "█", count: 20))
    }

    @Test("usage render includes totals, bar percent, local caption, no-limit")
    func usageLayout() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let claude = ProviderReport(
            id: .claude,
            displayName: "Claude",
            status: .ok(lastSuccess: now),
            snapshot: UsageSnapshot(
                providerID: .claude,
                asOf: now,
                tokensToday: 45230,
                costTodayUSD: Decimal(string: "12.40"),
                balanceUSD: nil,
                quota: Quota(used: 0.62, limit: 1, remaining: 0.38),
                raw: [:],
                quotaWindows: [
                    QuotaWindow(name: "5h", utilization: 0.38, resetsAt: now.addingTimeInterval(3 * 3600 + 12 * 60))
                ]
            ),
            placeholderMessage: nil,
            errorDescription: nil,
            isLocal: false,
            hasTokens: true
        )
        let openrouter = ProviderReport(
            id: .openrouter,
            displayName: "OpenRouter",
            status: .ok(lastSuccess: now),
            snapshot: UsageSnapshot(
                providerID: .openrouter,
                asOf: now,
                tokensToday: nil,
                costTodayUSD: Decimal(string: "4.10"),
                balanceUSD: Decimal(string: "8.12"),
                quota: nil,
                raw: [:]
            ),
            placeholderMessage: nil,
            errorDescription: nil,
            isLocal: false,
            hasTokens: false
        )
        let ollama = ProviderReport(
            id: .ollama,
            displayName: "Ollama",
            status: .notRunning,
            snapshot: nil,
            placeholderMessage: nil,
            errorDescription: nil,
            isLocal: true,
            hasTokens: false
        )
        let report = UsageReport(asOf: now, source: .live, providers: [claude, openrouter, ollama])
        let text = UsageTextRenderer.renderUsage(report, color: false)
        #expect(text.contains("Today total"))
        #expect(text.contains("45,230 tokens") || text.contains("45230 tokens"))
        #expect(text.contains("62%"))
        #expect(text.contains("no limit"))
        #expect(text.contains("Not running"))
        #expect(text.contains("5h"))
        #expect(!text.contains("Ollama") || text.contains("Not running"))
        #expect(text.contains("Total excludes quota-only providers"))
    }

    @Test("claude child accounts")
    func childAccounts() {
        let now = Date()
        let snap = UsageSnapshot(
            providerID: .claude,
            asOf: now,
            tokensToday: 10,
            costTodayUSD: 1,
            balanceUSD: nil,
            quota: Quota(used: 0.5, limit: 1, remaining: 0.5),
            raw: [:],
            accounts: [
                .init(name: "default", costTodayUSD: Decimal(string: "0.40"), quota: Quota(used: 0.2, limit: 1, remaining: 0.8), quotaWindows: nil),
                .init(name: "work", costTodayUSD: Decimal(string: "0.60"), quota: Quota(used: 0.8, limit: 1, remaining: 0.2), quotaWindows: nil),
            ]
        )
        let report = UsageReport(
            asOf: now,
            source: .live,
            providers: [
                ProviderReport(
                    id: .claude, displayName: "Claude", status: .ok(lastSuccess: now),
                    snapshot: snap, placeholderMessage: nil, errorDescription: nil,
                    isLocal: false, hasTokens: true
                )
            ]
        )
        let text = UsageTextRenderer.renderUsage(report, color: false)
        #expect(text.contains("default"))
        #expect(text.contains("work"))
    }

    @Test("quota renderer lists windows")
    func quotaWindows() {
        let now = Date()
        let snap = UsageSnapshot(
            providerID: .claude,
            asOf: now,
            tokensToday: 1,
            costTodayUSD: 1,
            balanceUSD: nil,
            quota: Quota(used: 0.3, limit: 1, remaining: 0.7),
            raw: [:],
            quotaWindows: [
                QuotaWindow(name: "5h", utilization: 0.3, resetsAt: now.addingTimeInterval(3600)),
                QuotaWindow(name: "7d", utilization: 0.1, resetsAt: now.addingTimeInterval(86400 * 4)),
            ]
        )
        let report = UsageReport(
            asOf: now,
            source: .cached,
            providers: [
                ProviderReport(
                    id: .claude, displayName: "Claude", status: .ok(lastSuccess: now),
                    snapshot: snap, placeholderMessage: nil, errorDescription: nil,
                    isLocal: false, hasTokens: true
                )
            ]
        )
        let text = UsageTextRenderer.renderQuota(report, color: false)
        #expect(text.contains("5h"))
        #expect(text.contains("7d"))
        #expect(text.contains("30%"))
    }

    @Test("JSON usage includes source and totals")
    func jsonUsage() throws {
        let now = Date(timeIntervalSince1970: 0)
        let report = UsageReport(
            asOf: now,
            source: .cached,
            providers: [
                ProviderReport(
                    id: .codex, displayName: "Codex", status: .ok(lastSuccess: now),
                    snapshot: UsageSnapshot(
                        providerID: .codex, asOf: now, tokensToday: 10,
                        costTodayUSD: 2, balanceUSD: nil,
                        quota: Quota(used: 0.5, limit: 1, remaining: 0.5), raw: [:]
                    ),
                    placeholderMessage: nil, errorDescription: nil,
                    isLocal: false, hasTokens: true
                )
            ]
        )
        let json = try UsageJSONRenderer.renderUsage(report)
        #expect(json.contains("\"source\" : \"cached\"") || json.contains("\"source\":\"cached\""))
        #expect(json.contains("codex"))
        #expect(json.contains("\"tokens\" : 10") || json.contains("\"tokens\":10"))
    }

    @Test("shouldColor respects --no-color and NO_COLOR")
    func colorGates() {
        #expect(UsageTextRenderer.shouldColor(noColor: true, isTTY: true) == false)
        #expect(UsageTextRenderer.shouldColor(noColor: false, isTTY: false) == false)
    }
}
