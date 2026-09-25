import Foundation
@testable import AgentsUsageBar

/// Rich, deterministic `UsageReport` shared by CLI theme golden tests.
///
/// Covers every branch the text renderers take: Claude multi-account with
/// dual windows, Codex primary/secondary windows, OpenRouter balance
/// (quota-only), degraded Gemini, an unauthenticated provider with no
/// snapshot, and local runtimes (running, not running, placeholder, custom
/// engine, long display name). `asOf` is fixed so reset phrases are stable.
enum CLIReportFixture {

    /// 2026-09-24 05:20:00 UTC.
    static let asOf = Date(timeIntervalSince1970: 1_790_227_200)

    static func rich() -> UsageReport {
        UsageReport(asOf: asOf, source: .cached, providers: [
            openrouter(), claude(), codex(), gemini(), grok(),
            ollama(), lmStudioLlamaCpp(), llamacpp(), customEngine(),
        ])
    }

    static func claude() -> ProviderReport {
        let personal5h = asOf.addingTimeInterval(4 * 3600 + 20 * 60)
        let personal7d = asOf.addingTimeInterval(31 * 3600)
        let work5h = asOf.addingTimeInterval(2 * 3600 + 50 * 60)
        let work7d = asOf.addingTimeInterval(3 * 86400 + 8 * 3600)
        let snap = UsageSnapshot(
            providerID: .claude,
            asOf: asOf,
            tokensToday: 232_400_512,
            costTodayUSD: Decimal(string: "273.86"),
            balanceUSD: nil,
            quota: Quota(used: 0.47, limit: 1, remaining: 0.53),
            raw: [:],
            quotaWindows: [
                QuotaWindow(name: "personal 5h", utilization: 0.12, resetsAt: personal5h),
                QuotaWindow(name: "personal 7d", utilization: 0.17, resetsAt: personal7d),
                QuotaWindow(name: "work 5h", utilization: 0.31, resetsAt: work5h),
                QuotaWindow(name: "work 7d", utilization: 0.47, resetsAt: work7d),
            ],
            accounts: [
                .init(
                    name: "personal",
                    costTodayUSD: Decimal(string: "53.63"),
                    quota: Quota(used: 0.17, limit: 1, remaining: 0.83),
                    quotaWindows: [
                        QuotaWindow(name: "5h", utilization: 0.12, resetsAt: personal5h),
                        QuotaWindow(name: "7d", utilization: 0.17, resetsAt: nil),
                    ]
                ),
                .init(
                    name: "work",
                    costTodayUSD: Decimal(string: "220.23"),
                    quota: Quota(used: 0.47, limit: 1, remaining: 0.53),
                    quotaWindows: [
                        QuotaWindow(name: "5h", utilization: 0.31, resetsAt: work5h),
                        QuotaWindow(name: "7d", utilization: 0.47, resetsAt: work7d),
                    ]
                ),
            ]
        )
        return report(.claude, "Claude", status: .ok(lastSuccess: asOf), snapshot: snap, hasTokens: true)
    }

    static func codex() -> ProviderReport {
        let snap = UsageSnapshot(
            providerID: .codex,
            asOf: asOf,
            tokensToday: 1_204_331,
            costTodayUSD: Decimal(string: "0.07"),
            balanceUSD: nil,
            quota: Quota(used: 0.69, limit: 1, remaining: 0.31),
            raw: [:],
            quotaWindows: [
                QuotaWindow(name: "primary", utilization: 0.69, resetsAt: asOf.addingTimeInterval(2 * 3600 + 50 * 60)),
                QuotaWindow(name: "secondary", utilization: 0.22, resetsAt: asOf.addingTimeInterval(5 * 86400)),
            ]
        )
        return report(.codex, "Codex", status: .ok(lastSuccess: asOf), snapshot: snap, hasTokens: true)
    }

    static func openrouter() -> ProviderReport {
        let snap = UsageSnapshot(
            providerID: .openrouter,
            asOf: asOf,
            tokensToday: nil,
            costTodayUSD: Decimal(string: "1.25"),
            balanceUSD: Decimal(string: "9.40"),
            quota: Quota(used: 0.94, limit: 1, remaining: 0.06),
            raw: [:]
        )
        return report(.openrouter, "OpenRouter", status: .ok(lastSuccess: asOf), snapshot: snap)
    }

    static func gemini() -> ProviderReport {
        let snap = UsageSnapshot(
            providerID: .gemini,
            asOf: asOf,
            tokensToday: nil,
            costTodayUSD: nil,
            balanceUSD: nil,
            quota: Quota(used: 0.19, limit: 1, remaining: 0.81),
            raw: ["note": ThresholdEngine.degradedTag],
            quotaWindows: [
                QuotaWindow(name: "gemini-2.5-pro", utilization: 0.19, resetsAt: asOf.addingTimeInterval(3600)),
                QuotaWindow(name: "gemini-2.5-flash", utilization: 0.04, resetsAt: asOf.addingTimeInterval(3600)),
            ]
        )
        return report(
            .gemini, "Gemini",
            status: .error(ProviderError(kind: .http, message: "HTTP 503")),
            snapshot: snap
        )
    }

    static func grok() -> ProviderReport {
        report(.grok, "Grok", status: .unauthenticated, snapshot: nil)
    }

    static func ollama() -> ProviderReport {
        report(.ollama, "Ollama", status: .notRunning, snapshot: nil, isLocal: true)
    }

    static func lmStudioLlamaCpp() -> ProviderReport {
        report(
            .lmstudioLlamaCpp, "LM Studio llama.cpp",
            status: .notRunning, snapshot: nil,
            placeholder: "Start LM Studio's llama.cpp server", isLocal: true
        )
    }

    static func llamacpp() -> ProviderReport {
        let snap = UsageSnapshot(
            providerID: .llamacpp,
            asOf: asOf,
            tokensToday: nil,
            costTodayUSD: nil,
            balanceUSD: nil,
            quota: nil,
            raw: ["modelCount": "1", "modelName": "Qwen3.5-4B", "vramBytes": "3221225472"]
        )
        return report(.llamacpp, "llama.cpp", status: .ok(lastSuccess: asOf), snapshot: snap, isLocal: true)
    }

    static func customEngine() -> ProviderReport {
        report(
            ProviderID(rawValue: "engine.gpu-box"), "gpu-box",
            status: .notRunning, snapshot: nil,
            placeholder: "Set [engine.gpu-box] port or match_path in config.toml", isLocal: true
        )
    }

    private static func report(
        _ id: ProviderID,
        _ name: String,
        status: ProviderStatus,
        snapshot: UsageSnapshot?,
        placeholder: String? = nil,
        isLocal: Bool = false,
        hasTokens: Bool = false
    ) -> ProviderReport {
        ProviderReport(
            id: id, displayName: name, status: status, snapshot: snapshot,
            placeholderMessage: placeholder, errorDescription: nil,
            isLocal: isLocal, hasTokens: hasTokens
        )
    }
}
