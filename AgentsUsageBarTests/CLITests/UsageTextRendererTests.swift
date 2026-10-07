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
                    QuotaWindow(name: "5h", utilization: 0.38, resetsAt: now.addingTimeInterval(3 * 3600 + 12 * 60)),
                    QuotaWindow(name: "7d", utilization: 0.62, resetsAt: now.addingTimeInterval(3 * 86400))
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
        #expect(text.contains("38%"))
        #expect(text.contains("no limit"))
        #expect(text.contains("Not running"))
        #expect(text.contains("5h"))
        #expect(text.contains("7d"))
        #expect(text.contains("███████▄▄▄▄▄░░░░░░░░  5h 38% · 7d 62%"))
        #expect(text.contains("Active: 7d 62%"))
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

    @Test("claude child bar uses 5h not weekly max")
    func childBarPrefersFiveHour() {
        let now = Date()
        let snap = UsageSnapshot(
            providerID: .claude,
            asOf: now,
            tokensToday: 10,
            costTodayUSD: 1,
            balanceUSD: nil,
            quota: Quota(used: 0.68, limit: 1, remaining: 0.32),
            raw: [:],
            accounts: [
                .init(
                    name: "work",
                    costTodayUSD: Decimal(string: "325.25"),
                    quota: Quota(used: 0.68, limit: 1, remaining: 0.32),
                    quotaWindows: [
                        QuotaWindow(name: "5h", utilization: 0.24, resetsAt: now.addingTimeInterval(4 * 3600)),
                        QuotaWindow(name: "7d", utilization: 0.68, resetsAt: now.addingTimeInterval(3 * 86400)),
                    ]
                ),
                .init(
                    name: "personal",
                    costTodayUSD: Decimal(string: "78.15"),
                    quota: Quota(used: 0.41, limit: 1, remaining: 0.59),
                    quotaWindows: [
                        QuotaWindow(name: "5h", utilization: 0.20, resetsAt: now.addingTimeInterval(4 * 3600)),
                        QuotaWindow(name: "7d", utilization: 0.41, resetsAt: now.addingTimeInterval(2 * 86400)),
                    ]
                ),
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
        let barLines = text.split(whereSeparator: \.isNewline).filter { $0.contains("░") || $0.contains("█") }
        #expect(text.contains("Active: work 7d 68%"))
        #expect(text.contains("5h 24% · 7d 68%"))
        #expect(text.contains("5h 20% · 7d 41%"))
        // Aggregate and each child use their own dual glyph bar.
        #expect(barLines.count == 3)
        #expect(barLines.contains { $0.contains("5h 24% · 7d 68%") })
        #expect(barLines.contains { $0.contains("5h 20% · 7d 41%") })
    }

    @Test("claude personal+work windows are one per line, not jammed with ·")
    func claudeWindowsNotJammed() {
        let now = Date()
        let personal5h = now.addingTimeInterval(4 * 3600 + 20 * 60)
        let personal7d = now.addingTimeInterval(31 * 3600)
        let work5h = now.addingTimeInterval(3 * 3600)
        let work7d = now.addingTimeInterval(55 * 3600)
        let snap = UsageSnapshot(
            providerID: .claude,
            asOf: now,
            tokensToday: 89_919_043,
            costTodayUSD: Decimal(string: "141.71"),
            balanceUSD: nil,
            quota: Quota(used: 0.86, limit: 1, remaining: 0.14),
            raw: [:],
            quotaWindows: [
                QuotaWindow(name: "personal 5h", utilization: 0.31, resetsAt: personal5h),
                QuotaWindow(name: "personal 7d", utilization: 0.44, resetsAt: personal7d),
                QuotaWindow(name: "work 5h", utilization: 0.35, resetsAt: work5h),
                QuotaWindow(name: "work 7d", utilization: 0.86, resetsAt: work7d),
            ],
            accounts: [
                .init(
                    name: "personal",
                    costTodayUSD: Decimal(string: "78.15"),
                    quota: Quota(used: 0.44, limit: 1, remaining: 0.56),
                    quotaWindows: [
                        QuotaWindow(name: "5h", utilization: 0.31, resetsAt: personal5h),
                        QuotaWindow(name: "7d", utilization: 0.44, resetsAt: personal7d),
                    ]
                ),
                .init(
                    name: "work",
                    costTodayUSD: Decimal(string: "63.56"),
                    quota: Quota(used: 0.86, limit: 1, remaining: 0.14),
                    quotaWindows: [
                        QuotaWindow(name: "5h", utilization: 0.35, resetsAt: work5h),
                        QuotaWindow(name: "7d", utilization: 0.86, resetsAt: work7d),
                    ]
                ),
            ]
        )
        let report = UsageReport(
            asOf: now,
            source: .live,
            providers: [
                ProviderReport(
                    id: .claude, displayName: "Claude Code", status: .ok(lastSuccess: now),
                    snapshot: snap, placeholderMessage: nil, errorDescription: nil,
                    isLocal: false, hasTokens: true
                )
            ]
        )
        let text = UsageTextRenderer.renderUsage(report, color: false)
        #expect(!text.contains("personal 5h"))
        #expect(!text.contains(" · work "))
        #expect(text.contains("personal"))
        #expect(text.contains("work"))
        #expect(text.contains("5h"))
        #expect(text.contains("7d"))
        #expect(text.contains("86%"))
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        let fiveHourLines = lines.filter { $0.contains("5h") }
        let sevenDayLines = lines.filter { $0.contains("7d") }
        #expect(fiveHourLines.count == 4) // dual bar + aggregate summary + two accounts
        #expect(sevenDayLines.count == 5) // active line + dual bar + aggregate summary + two accounts
        #expect(fiveHourLines.allSatisfy { $0.contains("7d") })
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
                        quota: Quota(used: 0.5, limit: 1, remaining: 0.5), raw: [:],
                        quotaWindows: [QuotaWindow(name: "5h", utilization: 0.5, resetsAt: now)]
                    ),
                    placeholderMessage: nil, errorDescription: nil,
                    isLocal: false, hasTokens: true
                )
            ]
        )
        let json = try UsageJSONRenderer.renderUsage(report)
        #expect(json.contains("\"source\" : \"cached\"") || json.contains("\"source\":\"cached\""))
        #expect(json.contains("codex"))
        #expect(json.contains("quotaWindows"))
        #expect(json.contains("\"tokens\" : 10") || json.contains("\"tokens\":10"))
    }

    @Test("gemini degraded snapshot does not print NSError")
    func geminiDegraded() {
        let now = Date()
        let snap = UsageSnapshot(
            providerID: .gemini,
            asOf: now,
            tokensToday: nil,
            costTodayUSD: nil,
            balanceUSD: nil,
            quota: Quota(used: 0.19, limit: 1, remaining: 0.81),
            raw: ["note": ThresholdEngine.degradedTag],
            quotaWindows: [
                QuotaWindow(name: "gemini-2.5-pro", utilization: 0.19, resetsAt: now.addingTimeInterval(3600))
            ]
        )
        let report = UsageReport(
            asOf: now,
            source: .live,
            providers: [
                ProviderReport(
                    id: .gemini, displayName: "Gemini",
                    status: .error(ProviderError(kind: .http, message: "x")),
                    snapshot: snap, placeholderMessage: nil,
                    errorDescription: "The operation couldn’t be completed. (AgentsUsageBar.GeminiOAuthError error 4.)",
                    isLocal: false, hasTokens: false
                )
            ]
        )
        let text = UsageTextRenderer.renderUsage(report, color: false)
        #expect(text.contains("usage temporarily unavailable"))
        #expect(!text.contains("GeminiOAuthError"))
        #expect(!text.contains("error 4"))
        #expect(text.contains("19%"))
    }

    @Test("shouldColor respects --no-color and NO_COLOR")
    func colorGates() {
        #expect(UsageTextRenderer.shouldColor(noColor: true, isTTY: true) == false)
        #expect(UsageTextRenderer.shouldColor(noColor: false, isTTY: false) == false)
    }

    @Test("codex classic usage is one primary bar per login, with no child cost")
    func codexClassicUsageAccounts() throws {
        let report = multiCodexClassicReport()
        let text = UsageTextRenderer.renderUsage(report, color: false)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let codexHeader = try #require(lines.first { $0.hasPrefix("Codex") })

        #expect(codexHeader.contains("80%"))
        #expect(!codexHeader.contains("90%"))
        #expect(text.contains("18,404 tokens"))
        #expect(text.contains("$0.07"))
        #expect(text.contains("████░░░░░░░░░░░░░░░░  20%"))
        #expect(text.contains("Resets 2h 50m"))
        #expect(text.contains("Resets —"))
        #expect(text.contains("unavailable"))
        #expect(!text.contains("no limit"))
        let childLines = lines.filter { $0.contains("plus") || $0.contains("team") || $0.contains("guest") }
        #expect(childLines.allSatisfy { !$0.contains("$") })
        #expect(!text.contains("5h "))
        #expect(!text.contains("7d"))
        #expect(!text.contains("●"))
        #expect(!text.contains("▀"))
        #expect(!text.contains("▄"))
    }

    @Test("codex classic quota lists primary and secondary under each login")
    func codexClassicQuotaAccounts() {
        let report = multiCodexClassicReport()
        let text = UsageTextRenderer.renderQuota(report, color: false)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        #expect(lines[0].contains("80%"))
        #expect(!lines[0].contains("90%"))
        #expect(text.contains("plus"))
        #expect(text.contains("team"))
        #expect(text.contains("guest"))
        #expect(text.contains("primary"))
        #expect(text.contains("secondary"))
        #expect(text.contains("90%"))
        #expect(text.contains("unavailable"))
        let childLines = lines.filter { $0.contains("plus") || $0.contains("team") || $0.contains("guest") }
        #expect(childLines.allSatisfy { !$0.contains("$") })
        #expect(!text.contains("$0.07"))
        #expect(!text.contains("5h "))
        #expect(!text.contains("●"))
    }

    @Test("codex usage JSON accounts are null below two logins and carry a null cost at two or more")
    func codexUsageJSONAccounts() throws {
        let one = try UsageJSONRenderer.renderUsage(singleCodexClassicReport())
        #expect(one.contains("\"accounts\" : null"))
        #expect(!one.contains("\"name\" : \"plus\""))

        let rich = try UsageJSONRenderer.renderUsage(CLIReportFixture.rich())
        #expect(rich.components(separatedBy: "\"accounts\" : null").count - 1 == 1)

        let json = try UsageJSONRenderer.renderUsage(multiCodexClassicReport())
        let provider = try codexProviderObject(json)
        let accounts = try #require(provider["accounts"] as? [[String: Any]])
        #expect(accounts.map { $0["name"] as? String } == ["plus", "team", "guest"])
        #expect(accounts.allSatisfy { $0["costTodayUSD"] is NSNull })
        let plus = try #require(accounts.first { $0["name"] as? String == "plus" })
        let plusQuota = try #require(plus["quota"] as? [String: Any])
        #expect(plusQuota["fraction"] as? Double == 0.20)
        let plusWindows = try #require(plus["quotaWindows"] as? [[String: Any]])
        #expect(plusWindows.map { $0["name"] as? String } == ["primary", "secondary"])
        #expect(provider["quotaWindows"] == nil)
        #expect(provider["tokensToday"] as? Int == 18_404)
        #expect(provider["costTodayUSD"] as? String == "0.07")
        let guest = try #require(accounts.first { $0["name"] as? String == "guest" })
        #expect(guest["quota"] == nil)
        #expect(guest["quotaWindows"] == nil)
    }

    @Test("codex quota JSON carries accounts without cost only at two or more logins")
    func codexQuotaJSONAccounts() throws {
        let rich = try UsageJSONRenderer.renderQuota(CLIReportFixture.rich())
        #expect(!rich.contains("\"accounts\""))

        let one = try UsageJSONRenderer.renderQuota(singleCodexClassicReport())
        #expect(!one.contains("\"accounts\""))

        let json = try UsageJSONRenderer.renderQuota(multiCodexClassicReport())
        let row = try #require((try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])?.first)
        #expect(row["quotaWindows"] == nil)
        let accounts = try #require(row["accounts"] as? [[String: Any]])
        #expect(accounts.map { $0["name"] as? String } == ["plus", "team", "guest"])
        #expect(accounts.allSatisfy { $0["costTodayUSD"] == nil })
        let plus = try #require(accounts.first { $0["name"] as? String == "plus" })
        let windows = try #require(plus["quotaWindows"] as? [[String: Any]])
        #expect(windows.map { $0["name"] as? String } == ["primary", "secondary"])
        let secondary = try #require(windows.first { $0["name"] as? String == "secondary" })
        #expect(secondary["utilization"] as? Double == 0.90)
        let header = try #require(row["quota"] as? [String: Any])
        #expect(header["fraction"] as? Double == 0.80)
    }
}

private func multiCodexClassicReport() -> UsageReport {
    let now = CLIReportFixture.asOf
    let plusReset = now.addingTimeInterval(2 * 3_600 + 50 * 60)
    let plus = UsageSnapshot.AccountUsage(
        name: "plus",
        costTodayUSD: nil,
        quota: Quota(used: 0.20, limit: 1, remaining: 0.80),
        quotaWindows: [
            QuotaWindow(name: "primary", utilization: 0.20, resetsAt: plusReset, duration: 18_000),
            QuotaWindow(name: "secondary", utilization: 0.90, resetsAt: now.addingTimeInterval(6 * 86_400), duration: 604_800),
        ]
    )
    let team = UsageSnapshot.AccountUsage(
        name: "team",
        costTodayUSD: nil,
        quota: Quota(used: 0.80, limit: 1, remaining: 0.20),
        quotaWindows: [
            QuotaWindow(name: "primary", utilization: 0.80, resetsAt: nil, duration: 18_000)
        ]
    )
    let guest = UsageSnapshot.AccountUsage(
        name: "guest",
        costTodayUSD: nil,
        quota: nil,
        quotaWindows: nil
    )
    let snapshot = UsageSnapshot(
        providerID: .codex,
        asOf: now,
        tokensToday: 18_404,
        costTodayUSD: Decimal(string: "0.07"),
        balanceUSD: nil,
        quota: Quota(used: 0.80, limit: 1, remaining: 0.20),
        raw: ["source": "codex-accounts"],
        quotaWindows: nil,
        accounts: [plus, team, guest]
    )
    return UsageReport(
        asOf: now,
        source: .live,
        providers: [
            ProviderReport(
                id: .codex, displayName: "Codex", status: .ok(lastSuccess: now),
                snapshot: snapshot, placeholderMessage: nil, errorDescription: nil,
                isLocal: false, hasTokens: true
            )
        ]
    )
}

private func singleCodexClassicReport() -> UsageReport {
    UsageReport(
        asOf: CLIReportFixture.asOf,
        source: .cached,
        providers: [CLIReportFixture.codex()]
    )
}

private func codexProviderObject(_ json: String) throws -> [String: Any] {
    let root = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    let providers = try #require(root["providers"] as? [[String: Any]])
    return try #require(providers.first { $0["id"] as? String == "codex" })
}
