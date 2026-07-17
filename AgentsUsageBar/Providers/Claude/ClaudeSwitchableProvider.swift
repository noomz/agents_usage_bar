import Foundation

// MARK: - ClaudeSwitchableProvider

/// Facade Claude provider that owns the `.claude` identity and delegates each fetch to
/// one of two underlying implementations, selected at fetch time by a `source` closure:
///
/// - `.sessionReads` → `ClaudeJSONLProvider` (reconstructs tokens/cost from JSONL
///   transcripts + polls the OAuth usage endpoint — the existing default behavior).
/// - `.hook` → `ClaudeHookProvider` (reads real usage Claude Code pushes to its status
///   line via the installed statusline tee — no JSONL reads, no network).
///
/// Only this facade is registered in the provider registry (`AppDependencies`); the two
/// concrete providers are private collaborators. The UI never distinguishes them — the row
/// is always "Claude Code", and flipping the source in Settings changes which delegate
/// answers the next poll.
///
/// Invariants:
/// - Default source is `.sessionReads` (existing behavior preserved when the preference key
///   is absent or holds an unknown rawValue).
/// - The `source` closure is `@Sendable` and reads `UserDefaults` directly (thread-safe) so
///   the actor never touches the `@MainActor` `UserPreferencesStore`.
/// - `status()` mirrors the last delegate's status — after each fetch the facade copies the
///   selected delegate's `status()` so the UI reflects the mode that actually ran.
public actor ClaudeSwitchableProvider: UsageProvider {

    // MARK: - UsageProvider nonisolated constants

    public nonisolated let id: ProviderID = .claude
    public nonisolated let displayName: String = "Claude Code"
    public nonisolated let capabilities: ProviderCapabilities = ProviderCapabilities(
        hasQuota: true,
        hasCost: true,
        hasTokens: true,   // nil at runtime in hook mode is acceptable (capability = "may report")
        isLocal: false
    )

    // MARK: - Delegates + source selector

    private let jsonl: ClaudeJSONLProvider
    private let hookProvider: ClaudeHookProvider
    private let source: @Sendable () -> ClaudeUsageSource

    private var lastStatus: ProviderStatus = .error(ProviderError.notYetFetched)

    // MARK: - Init

    /// - Parameters:
    ///   - jsonl: The session-reads delegate (existing JSONL + OAuth provider).
    ///   - hookProvider: The hook (statusline-tee) delegate.
    ///   - source: Selector evaluated on every fetch. Production reads
    ///     `UserDefaults.standard` under `AUBDefaultsKey.claudeSource`; tests inject a fake.
    ///     Defaults to `ClaudeSwitchableProvider.defaultSource`.
    public init(
        jsonl: ClaudeJSONLProvider,
        hookProvider: ClaudeHookProvider,
        source: @escaping @Sendable () -> ClaudeUsageSource = ClaudeSwitchableProvider.defaultSource
    ) {
        self.jsonl = jsonl
        self.hookProvider = hookProvider
        self.source = source
    }

    /// Reads the current Claude usage source straight from `UserDefaults` (thread-safe),
    /// falling back to `.sessionReads` when the key is absent or holds an unknown rawValue.
    public static let defaultSource: @Sendable () -> ClaudeUsageSource = {
        let raw = UserDefaults.standard.string(forKey: AUBDefaultsKey.claudeSource) ?? ""
        return ClaudeUsageSource(rawValue: raw) ?? .sessionReads
    }

    // MARK: - UsageProvider

    public func status() -> ProviderStatus {
        lastStatus
    }

    /// Delegates the fetch to the source-selected provider, then mirrors that delegate's
    /// status into the facade so `status()` reflects the mode that actually ran.
    ///
    /// Hook mode is HYBRID for tokens: the statusline pushes real cost + rate limits but
    /// no cumulative token totals, so the row would render "—" tokens forever. We run the
    /// JSONL delegate concurrently and graft ONLY its `tokensToday` onto the hook snapshot
    /// (cost/quota stay hook-real; a JSONL failure degrades tokens to nil, never the fetch).
    public func fetch(now: Date) async throws -> UsageSnapshot {
        let useHook = source() == .hook
        let delegate: any UsageProvider = useHook ? hookProvider : jsonl
        if !useHook {
            // The tee script writes feed files regardless of mode; prune here so the feed
            // dir stays bounded even when the user never selects hook mode (review finding).
            await hookProvider.pruneFeed(now: now)
        }
        do {
            let snapshot: UsageSnapshot
            if useHook {
                async let tokensBox: Int?? = { [jsonl] in
                    (try? await jsonl.fetch(now: now))?.tokensToday
                }()
                let hookSnap = try await hookProvider.fetch(now: now)
                let tokens = (await tokensBox) ?? nil
                snapshot = UsageSnapshot(
                    providerID: hookSnap.providerID,
                    asOf: hookSnap.asOf,
                    tokensToday: tokens,
                    costTodayUSD: hookSnap.costTodayUSD,
                    balanceUSD: hookSnap.balanceUSD,
                    quota: hookSnap.quota,
                    raw: hookSnap.raw,
                    quotaWindows: hookSnap.quotaWindows,
                    tooltipLabel: hookSnap.tooltipLabel,
                    accounts: hookSnap.accounts
                )
            } else {
                snapshot = try await delegate.fetch(now: now)
            }
            lastStatus = await delegate.status()
            return snapshot
        } catch {
            lastStatus = await delegate.status()
            throw error
        }
    }
}
