import Foundation

enum PiLocalUsage {
    struct Acc: Sendable, Equatable {
        var tokens: Int
        var costUSD: Decimal
        var providers: Set<PiProviderName>
        var models: Set<String>

        init(
            tokens: Int = 0,
            costUSD: Decimal = 0,
            providers: Set<PiProviderName> = [],
            models: Set<String> = []
        ) {
            self.tokens = tokens
            self.costUSD = costUSD
            self.providers = providers
            self.models = models
        }
    }

    /// Pure. Skip if `record.timestamp < todayStart` or catalog miss.
    static func reduce(
        records: [PiSessionRecord],
        catalog: PiLocalCatalog,
        todayStart: Date,
        into acc: inout Acc
    ) {
        for record in records {
            guard record.timestamp >= todayStart else { continue }
            guard catalog.contains(record.provider) else { continue }
            acc.tokens += record.tokens
            acc.costUSD += record.costUSD
            acc.providers.insert(record.provider)
            if !record.model.isEmpty {
                acc.models.insert(record.model)
            }
        }
    }
}
