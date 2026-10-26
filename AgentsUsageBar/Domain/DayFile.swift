import Foundation

/// One day key's file in `history/` (SPEC I9, I16): every provider's day records for that
/// day, the day's usage events, and the providers already backfilled for it.
///
/// Schema 1 holds every field the usage history spec needs from S1 on; later slices fill
/// fields, they do not add them (V18). It freezes at the first release that contains it (C6).
public struct DayFile: Sendable, Equatable, Codable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// The day key, `yyyy-MM-dd` (V2). Matches the file name.
    public var date: String
    /// The last time zone id seen that day (V6). `UTC` for OpenRouter backfill (V13).
    public var timeZone: String
    public var records: [DayRecord]
    public var events: [UsageEvent]
    public var backfillChecked: [ProviderID]

    public init(
        date: String,
        timeZone: String,
        records: [DayRecord] = [],
        events: [UsageEvent] = [],
        backfillChecked: [ProviderID] = []
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.date = date
        self.timeZone = timeZone
        self.records = records
        self.events = events
        self.backfillChecked = backfillChecked
    }
}

/// One provider's usage for one day key (V7–V13).
public struct DayRecord: Sendable, Equatable, Codable {
    public var provider: ProviderID
    /// `UTC` for an OpenRouter backfilled record, whose day is a UTC day. Nil means the
    /// day is the file's zone (V13).
    public var timeZone: String?
    /// Highest value seen that day. Nil is unknown, never zero (V7).
    public var tokens: Int?
    /// Highest value seen that day. Nil is unknown, never zero (V7).
    public var costUSD: Money?
    /// True when `costUSD` is tokens times the bundled price table (V10, I8).
    public var costEstimated: Bool
    /// The last value seen that day (V7).
    public var balanceUSD: Money?
    /// Keyed by quota window name (V8).
    public var quota: [String: QuotaDay]
    public var accounts: [DayAccount]
    public var origin: RecordOrigin
    /// First and last good sample. Observed records only (V10, V30).
    public var firstSeen: Date?
    public var lastSeen: Date?

    public init(
        provider: ProviderID,
        timeZone: String? = nil,
        tokens: Int? = nil,
        costUSD: Money? = nil,
        costEstimated: Bool = false,
        balanceUSD: Money? = nil,
        quota: [String: QuotaDay] = [:],
        accounts: [DayAccount] = [],
        origin: RecordOrigin,
        firstSeen: Date? = nil,
        lastSeen: Date? = nil
    ) {
        self.provider = provider
        self.timeZone = timeZone
        self.tokens = tokens
        self.costUSD = costUSD
        self.costEstimated = costEstimated
        self.balanceUSD = balanceUSD
        self.quota = quota
        self.accounts = accounts
        self.origin = origin
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}

/// One quota window's day: the peak fraction with the reset time at the peak, and the
/// last fraction seen (V8).
public struct QuotaDay: Sendable, Equatable, Codable {
    public var peak: Double
    public var peakResetsAt: Date?
    public var endOfDay: Double

    public init(peak: Double, peakResetsAt: Date? = nil, endOfDay: Double) {
        self.peak = peak
        self.peakResetsAt = peakResetsAt
        self.endOfDay = endOfDay
    }
}

/// One account seen on a day (V9). `key` is an account key, never a raw `account_id`, and
/// `label` is never an email (V21, V22).
public struct DayAccount: Sendable, Equatable, Codable {
    public var key: String
    public var label: String
    public var billingModel: BillingModel
    public var plan: String?
    /// True when a backfill took the billing model current at backfill time (V25).
    public var billingModelAssumed: Bool
    /// Only when the provider reports per-account cost (V9).
    public var costUSD: Money?
    /// Only when the provider reports per-account tokens (V9). Nil in files written before.
    public var tokens: Int?
    public var quota: [String: QuotaDay]

    public init(
        key: String,
        label: String,
        billingModel: BillingModel,
        plan: String? = nil,
        billingModelAssumed: Bool = false,
        costUSD: Money? = nil,
        tokens: Int? = nil,
        quota: [String: QuotaDay] = [:]
    ) {
        self.key = key
        self.label = label
        self.billingModel = billingModel
        self.plan = plan
        self.billingModelAssumed = billingModelAssumed
        self.costUSD = costUSD
        self.tokens = tokens
        self.quota = quota
    }
}

/// How an account pays (V25). Only metered cost is spend (V26, ADR 0001).
public enum BillingModel: String, Sendable, Equatable, Codable {
    case metered
    case subscription
    case local
}

/// Whether a record came from the app's own polls that day or was rebuilt later (V10).
public enum RecordOrigin: String, Sendable, Equatable, Codable {
    case observed
    case backfilled
}

/// A notable moment on a day (V33). An event is the crossing, not the notification (V34).
public struct UsageEvent: Sendable, Equatable, Codable {
    public var time: Date
    /// Nil for the total budget.
    public var provider: ProviderID?
    public var kind: UsageEventKind
    /// Nil for a provider-level band or a budget.
    public var window: String?
    /// Account key, only for a per-account alert.
    public var account: String?
    public var fraction: Double
    public var notified: Bool
    public var carriedOver: Bool

    public init(
        time: Date,
        provider: ProviderID?,
        kind: UsageEventKind,
        window: String? = nil,
        account: String? = nil,
        fraction: Double,
        notified: Bool,
        carriedOver: Bool = false
    ) {
        self.time = time
        self.provider = provider
        self.kind = kind
        self.window = window
        self.account = account
        self.fraction = fraction
        self.notified = notified
        self.carriedOver = carriedOver
    }
}

/// Usage event kinds (V33). A band crossing names its band, since one poll can cross
/// several (V34). A budget crossing is at the warning threshold or at 100% (V41).
public enum UsageEventKind: String, Sendable, Equatable, Codable {
    case band80
    case band95
    case band100
    case pace
    case reset
    case authLost
    case authRecovered
    case budgetWarning
    case budgetLimit
}

/// A USD amount stored as a decimal string, so no binary rounding touches money (I16).
/// Rounded to micro-dollars on creation, so a `Decimal(Double)` expansion never reaches a
/// day file, an export, or a view (V65).
public struct Money: Sendable, Hashable, Comparable, Codable {
    public static let scale = 6

    public let amount: Decimal

    public init(_ amount: Decimal) {
        var value = amount
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, Self.scale, .plain)
        self.amount = rounded
    }

    public static func < (lhs: Money, rhs: Money) -> Bool {
        lhs.amount < rhs.amount
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let amount = Decimal(string: string, locale: Locale(identifier: "en_US_POSIX")) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "money is not a decimal string: \(string)")
        }
        self.init(amount)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(amount.description)
    }
}

// MARK: - Codec

extension DayFile {
    /// The result of reading a day file's bytes (V18).
    public enum Decoded: Sendable, Equatable {
        case file(DayFile)
        /// A `schemaVersion` this build cannot read: newer, or unknown.
        case unsupported(schemaVersion: Int)
        /// Not a day file at all: malformed JSON or a missing or mistyped field.
        case unreadable
    }

    private struct VersionProbe: Decodable {
        let schemaVersion: Int
    }

    /// Decodes a day file, migrating an older `schemaVersion` to the current one (V18).
    /// Schema 1 is the first, so there is nothing older to migrate yet.
    public static func decode(_ data: Data) -> Decoded {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let probe = try? decoder.decode(VersionProbe.self, from: data) else { return .unreadable }
        switch probe.schemaVersion {
        case currentSchemaVersion:
            guard let file = try? decoder.decode(DayFile.self, from: data) else { return .unreadable }
            return .file(file)
        default:
            return .unsupported(schemaVersion: probe.schemaVersion)
        }
    }

    /// Stable, human-readable bytes: sorted keys, ISO 8601 dates, money as decimal strings.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
