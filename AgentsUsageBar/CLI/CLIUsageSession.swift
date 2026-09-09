import Foundation

/// One-shot usage fetch for the CLI. Never writes the cache and never fires notifications.
public struct CLIUsageSession {
    public var providers: [any UsageProvider]
    public var placeholders: [PlaceholderSeed]
    public var cache: any CacheStore
    public var clock: any Clock
    public var isEnabled: @Sendable (ProviderID) -> Bool

    public init(
        providers: [any UsageProvider],
        placeholders: [PlaceholderSeed] = [],
        cache: any CacheStore = NoopCacheStore(),
        clock: any Clock = SystemClock(),
        isEnabled: @escaping @Sendable (ProviderID) -> Bool = { _ in true }
    ) {
        self.providers = providers
        self.placeholders = placeholders
        self.cache = cache
        self.clock = clock
        self.isEnabled = isEnabled
    }

    @MainActor
    public func fetch(
        filter: AUBCommand.ProviderFilter,
        cached: Bool,
        now: Date? = nil
    ) async -> UsageReport {
        let asOf = now ?? clock.now()
        let cachedStates = cache.loadAll()
        var reports: [ProviderReport] = []

        if cached {
            reports = cachedStates.values
                .sorted { $0.id.rawValue < $1.id.rawValue }
                .map { ProviderReport(state: $0, isLocal: ProviderID.localIDs.contains($0.id)) }
        } else {
            var seen = Set<ProviderID>()

            await withTaskGroup(of: ProviderReport.self) { group in
                for provider in providers {
                    guard wants(provider.id, filter: filter) else { continue }
                    seen.insert(provider.id)
                    let cachedState = cachedStates[provider.id]
                    group.addTask {
                        await CLIUsageSession.fetchOne(provider: provider, now: asOf, cached: cachedState)
                    }
                }
                for await report in group {
                    reports.append(report)
                }
            }

            for seed in placeholders {
                guard wants(seed.providerID, filter: filter), !seen.contains(seed.providerID) else { continue }
                if let cached = cachedStates[seed.providerID], cached.snapshot != nil {
                    reports.append(ProviderReport(state: cached, isLocal: ProviderID.localIDs.contains(seed.providerID)))
                } else {
                    reports.append(ProviderReport(placeholder: seed))
                }
            }

            reports.sort { lhs, rhs in
                let order = ProviderID.allKnown
                let li = order.firstIndex(of: lhs.id) ?? Int.max
                let ri = order.firstIndex(of: rhs.id) ?? Int.max
                return li < ri
            }
        }

        reports = reports.filter { wants($0.id, filter: filter) }
        return UsageReport(asOf: asOf, source: cached ? .cached : .live, providers: reports)
    }

    private func wants(_ id: ProviderID, filter: AUBCommand.ProviderFilter) -> Bool {
        switch filter {
        case .all: return true
        case .one(let wanted): return id == wanted
        case .enabled: return isEnabled(id)
        }
    }

    private static func fetchOne(
        provider: any UsageProvider,
        now: Date,
        cached: ProviderState?
    ) async -> ProviderReport {
        let isLocal = provider.capabilities.isLocal
        do {
            let snapshot = try await provider.fetch(now: now)
            let status = await provider.status()
            return ProviderReport(
                id: provider.id,
                displayName: provider.displayName,
                status: status,
                snapshot: snapshot,
                placeholderMessage: nil,
                errorDescription: nil,
                isLocal: isLocal,
                hasTokens: provider.capabilities.hasTokens
            )
        } catch {
            return ProviderReport(
                id: provider.id,
                displayName: provider.displayName,
                status: .error(ProviderError.from(error)),
                snapshot: cached?.snapshot,
                placeholderMessage: cached?.placeholderMessage,
                errorDescription: error.localizedDescription,
                isLocal: isLocal,
                hasTokens: provider.capabilities.hasTokens
            )
        }
    }
}

public struct UsageReport: Sendable, Equatable {
    public enum Source: String, Sendable, Equatable {
        case live
        case cached
    }

    public var asOf: Date
    public var source: Source
    public var providers: [ProviderReport]

    public var totals: DailyTotals {
        var tokens = 0
        var cost: Decimal = 0
        for p in providers {
            guard p.hasTokens else { continue }
            guard let snap = p.snapshot else { continue }
            tokens += snap.tokensToday ?? 0
            if let c = snap.costTodayUSD { cost += c }
        }
        return DailyTotals(tokens: tokens, costUSD: cost)
    }

    public var hasAnyQuotaOnlyProvider: Bool {
        providers.contains { !$0.hasTokens && !$0.isLocal }
    }
}

public struct ProviderReport: Sendable, Equatable {
    public var id: ProviderID
    public var displayName: String
    public var status: ProviderStatus
    public var snapshot: UsageSnapshot?
    public var placeholderMessage: String?
    public var errorDescription: String?
    public var isLocal: Bool
    public var hasTokens: Bool

    public init(
        id: ProviderID,
        displayName: String,
        status: ProviderStatus,
        snapshot: UsageSnapshot?,
        placeholderMessage: String?,
        errorDescription: String?,
        isLocal: Bool,
        hasTokens: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.status = status
        self.snapshot = snapshot
        self.placeholderMessage = placeholderMessage
        self.errorDescription = errorDescription
        self.isLocal = isLocal
        self.hasTokens = hasTokens
    }

    public init(state: ProviderState, isLocal: Bool) {
        self.init(
            id: state.id,
            displayName: state.displayName,
            status: state.status,
            snapshot: state.snapshot,
            placeholderMessage: state.placeholderMessage,
            errorDescription: nil,
            isLocal: isLocal,
            hasTokens: state.id.contributesToTodayTotal
        )
    }

    public init(placeholder: PlaceholderSeed) {
        self.init(
            id: placeholder.providerID,
            displayName: placeholder.displayName,
            status: placeholder.status,
            snapshot: nil,
            placeholderMessage: placeholder.placeholderMessage,
            errorDescription: nil,
            isLocal: ProviderID.localIDs.contains(placeholder.providerID),
            hasTokens: placeholder.providerID.contributesToTodayTotal
        )
    }
}

extension ProviderID {
    /// D-07: whether this id's snapshot contributes to the Today total.
    /// Matches production `UsageProvider.capabilities.hasTokens` for known ids.
    public var contributesToTodayTotal: Bool {
        self == .claude || self == .codex
    }
}
