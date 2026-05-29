import SwiftUI

/// Per-provider row in the popover (UI-02).
///
/// Displays:
/// - Provider display name (subheadline) with `.help()` tooltip carrying the
///   `tooltipLabel` (Codex `plan_type` / Gemini tier, D-15 / GEMINI-03)
/// - Status dot (ok/stale/error/unauthenticated/disabled) with amber override
///   when the snapshot is in Gemini's D-11 degraded state
/// - Today tokens ("—" for nil/cold-launch per D-03)
/// - Today USD cost ("—" for nil/cold-launch)
/// - Account balance (omitted when nil)
/// - Color-coded quota bar (QuotaBar) per UI-02 authoritative thresholds (B4)
/// - "Resets —" countdown (OpenRouter has no reset countdown — RESEARCH Open Question #4)
/// - "Updated Xs ago" relative timestamp label (ticks via TimelineView every 1s)
/// - D-11 "Updated Xm ago — usage temporarily unavailable" subtitle when the
///   snapshot carries `raw["note"] == ThresholdEngine.degradedTag`
/// - Trailing "Open dashboard" button (UI-11 / D-13 / D-14) invoking the
///   `openDashboardURL` environment closure with the provider's hard-coded
///   web-console URL from `ProviderDashboardURL.lookup(_:)`.
///
/// No `@StateObject`, `ObservableObject`, `@Published`, or Combine — pure value render from `ProviderState`.
public struct ProviderRowView: View {
    public let state: ProviderState
    /// Plan 02.07 — environment-injected store + clock for `isStale(_:now:)`.
    /// Available since Plan 01.08 wires both into the SwiftUI environment.
    @Environment(AggregateStore.self) private var store
    @Environment(\.clockService) private var clock
    /// Plan 03-07 — environment-injected dashboard-launch closure. The
    /// production default (declared in `OpenDashboardURLEnvironmentKey.swift`)
    /// opens the URL via AppKit; tests inject a recording closure. Keeping
    /// AppKit out of this view body satisfies the testability seam from D-13.
    @Environment(\.openDashboardURL) private var openDashboardURL

    public init(state: ProviderState) {
        self.state = state
    }

    /// Plan 03-07 / D-14 — looked-up dashboard URL for this row. `nil` for
    /// out-of-scope providers (local LLMs); the button is `.disabled` in that
    /// case to preserve row layout symmetry.
    private var dashboardURL: URL? { ProviderDashboardURL.lookup(state.id) }

    /// Plan 03-07 / D-11 — detects Gemini's `"usage-temporarily-unavailable"`
    /// degraded snapshot via the canonical `ThresholdEngine.degradedTag`
    /// constant (single-sourced literal per Plan 03-08 STATE #84).
    private var isDegraded: Bool {
        state.snapshot?.raw["note"] == ThresholdEngine.degradedTag
    }

    public var body: some View {
        // Plan 02.07 (UI-08): wrap the row in a TimelineView so the staleness predicate
        // re-evaluates as time crosses the 2 × interval threshold. Body recomputation is
        // a single-row, integer-math cost — acceptable per RESEARCH §H.2.
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let isStale = store.isStale(state.id, now: ctx.date)
            HStack(alignment: .top, spacing: 10) {
                // Status dot aligned to top of content — Plan 03-07 wires the
                // amber override for the D-11 degraded state.
                StatusDot(status: state.status, isStale: isStale, forceAmber: isDegraded)
                    .padding(.top, 3)

                VStack(alignment: .leading, spacing: 4) {
                    // Provider name with D-15 / GEMINI-03 tooltip. Passing ""
                    // for the absent case yields no tooltip (SwiftUI suppresses
                    // .help when the argument is empty).
                    Text(state.displayName)
                        .font(.subheadline.weight(.semibold))
                        .help(state.snapshot?.tooltipLabel ?? "")

                    // Token count · USD cost · balance
                    HStack(spacing: 4) {
                        Text(tokenText(state.snapshot))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(usdText(state.snapshot))
                            .font(.caption2)
                            .monospacedDigit()
                        if let bal = balanceText(state.snapshot), !bal.isEmpty {
                            Text("·")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(bal)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .opacity(isStale || isDegraded ? 0.6 : 1.0)

                    // Quota bar — opacity composes UI-08 stale dimming and the
                    // Plan 03-07 / D-11 degraded dimming.
                    QuotaBar(quota: state.snapshot?.quota)
                        .frame(maxWidth: .infinity)
                        .opacity(isStale || isDegraded ? 0.6 : 1.0)

                    // Reset countdown + relative timestamp.
                    //
                    // G-01 (UAT 2026-05-18): the countdown reads the soonest
                    // `resetsAt` across all `quotaWindows`. Codex provides
                    // primary+secondary windows (rollout or wham/usage path);
                    // Gemini provides per-model buckets. OpenRouter / Claude
                    // currently emit no `quotaWindows`, so `resetsText` returns
                    // "Resets —" — preserving the prior literal for those rows.
                    HStack(spacing: 8) {
                        RelativeTimestampLabel(date: state.lastSuccess, isStale: isStale)
                        Spacer()
                        Text(resetsText(state.snapshot, now: ctx.date))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    // Plan 03-07 / D-11 — degraded subtitle. Placed AFTER the
                    // existing "Resets —" row so it reads as a footnote to the
                    // row's data, not a replacement for the timestamp.
                    if isDegraded {
                        Text("Updated \(RelativeTimestampLabel.relativeString(from: state.lastSuccess ?? ctx.date, to: ctx.date)) ago — usage temporarily unavailable")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                // Plan 03-07 (UI-11 / D-13) — trailing dashboard button.
                // Always visible (no hover-reveal) so the affordance is
                // one-click discoverable; `.disabled(dashboardURL == nil)`
                // preserves row layout symmetry for providers without a
                // mapped dashboard URL (local LLMs).
                Spacer(minLength: 4)
                Button {
                    if let url = dashboardURL { openDashboardURL(url) }
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .symbolRenderingMode(.monochrome)
                        .font(.caption)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(HoverableBorderedButtonStyle())
                .disabled(dashboardURL == nil)
                .help("Open \(state.displayName) dashboard")
                .padding(.top, 2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Private helpers

    /// Today's token count as text. "—" when nil (cold-launch D-03 / OpenRouter no tokens D-03).
    private func tokenText(_ snapshot: UsageSnapshot?) -> String {
        guard let s = snapshot else { return "—" }
        guard let tokens = s.tokensToday else { return "—" }
        return "\(tokens.formatted(.number)) tokens"
    }

    /// Today's USD cost as text. "—" when nil (cold-launch D-03).
    private func usdText(_ snapshot: UsageSnapshot?) -> String {
        guard let s = snapshot else { return "—" }
        guard let cost = s.costTodayUSD else { return "—" }
        return cost.formatted(.currency(code: "USD"))
    }

    /// Account balance text, or nil when not available.
    private func balanceText(_ snapshot: UsageSnapshot?) -> String? {
        guard let s = snapshot, let bal = s.balanceUSD else { return nil }
        return "bal " + bal.formatted(.currency(code: "USD"))
    }

    /// Countdown to the soonest `quotaWindows[*].resetsAt`. Returns "Resets —"
    /// when the snapshot has no quotaWindows or every window's `resetsAt` is
    /// nil (OpenRouter, Claude). When the soonest reset is already in the
    /// past, returns "Resets now" until the next poll rebases the window.
    ///
    /// Format: `Resets Xh Ym` (≥ 1h), `Resets Xm` (≥ 1m), `Resets <1m` (< 1m).
    private func resetsText(_ snapshot: UsageSnapshot?, now: Date) -> String {
        guard let windows = snapshot?.quotaWindows,
              let soonest = windows.compactMap(\.resetsAt).min()
        else {
            return "Resets —"
        }
        let interval = soonest.timeIntervalSince(now)
        if interval <= 0 {
            return "Resets now"
        }
        let totalMinutes = Int(interval / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours >= 1 {
            return "Resets \(hours)h \(minutes)m"
        }
        if totalMinutes >= 1 {
            return "Resets \(totalMinutes)m"
        }
        return "Resets <1m"
    }
}

// MARK: - Previews

@MainActor
private func previewStore() -> AggregateStore {
    AggregateStore(
        registry: [],
        clock: SystemClock(),
        cache: NoopCacheStore(),
        thresholds: ThresholdEngine(),
        notifications: NoopNotificationManager()
    )
}

#Preview("ProviderRowView — ok with quota") {
    let snapshot = UsageSnapshot(
        providerID: ProviderID(rawValue: "openrouter"),
        asOf: .now,
        tokensToday: nil,
        costTodayUSD: Decimal(2.45),
        balanceUSD: Decimal(7.55),
        quota: Quota(used: 2.45, limit: 10.0, remaining: 7.55),
        raw: [:]
    )
    let state = ProviderState(
        id: ProviderID(rawValue: "openrouter"),
        displayName: "OpenRouter",
        snapshot: snapshot,
        status: .ok(lastSuccess: .now.addingTimeInterval(-30)),
        lastSuccess: .now.addingTimeInterval(-30)
    )
    return ProviderRowView(state: state)
        .environment(previewStore())
        .frame(width: 360)
}

#Preview("ProviderRowView — cold launch (no snapshot)") {
    let state = ProviderState(
        id: ProviderID(rawValue: "openrouter"),
        displayName: "OpenRouter",
        snapshot: nil,
        status: .unauthenticated,
        lastSuccess: nil
    )
    return ProviderRowView(state: state)
        .environment(previewStore())
        .frame(width: 360)
}

#Preview("ProviderRowView — error state") {
    let state = ProviderState(
        id: ProviderID(rawValue: "openrouter"),
        displayName: "OpenRouter",
        snapshot: nil,
        status: .error(ProviderError(kind: .auth, message: "HTTP 401")),
        lastSuccess: nil
    )
    return ProviderRowView(state: state)
        .environment(previewStore())
        .frame(width: 360)
}

#Preview("ProviderRowView — Gemini degraded (D-11)") {
    let snapshot = UsageSnapshot(
        providerID: .gemini,
        asOf: .now,
        tokensToday: nil,
        costTodayUSD: nil,
        balanceUSD: nil,
        quota: Quota(used: 0.15, limit: 1.0, remaining: 0.85),
        raw: ["note": "usage-temporarily-unavailable", "degraded": "true"],
        tooltipLabel: "Free"
    )
    let state = ProviderState(
        id: .gemini,
        displayName: "Gemini",
        snapshot: snapshot,
        status: .stale(lastSuccess: .now.addingTimeInterval(-180),
                       error: ProviderError(kind: .http, message: "503")),
        lastSuccess: .now.addingTimeInterval(-180)
    )
    return ProviderRowView(state: state)
        .environment(previewStore())
        .frame(width: 360)
}
