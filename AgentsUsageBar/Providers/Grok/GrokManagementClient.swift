import Foundation

/// Prepaid remaining USD and today's API spend from the xAI Management API (SPEC I17, V70).
public struct GrokManagementSnapshot: Sendable, Equatable {
    public let remainingUSD: Decimal?
    public let costTodayUSD: Decimal?

    public init(remainingUSD: Decimal?, costTodayUSD: Decimal?) {
        self.remainingUSD = remainingUSD
        self.costTodayUSD = costTodayUSD
    }
}

public protocol GrokManagementClientProtocol: Actor {
    func fetch(now: Date) async throws -> GrokManagementSnapshot
}

/// `GET …/prepaid/balance` and `POST …/usage` on `https://management-api.x.ai`.
public actor GrokManagementClient: GrokManagementClientProtocol {

    public static let defaultBaseURL = URL(string: "https://management-api.x.ai")!

    private let http: any HTTPClient
    private let bearer: Secret
    private let teamID: String
    private let baseURL: URL
    private let timeZone: TimeZone

    public init(
        http: any HTTPClient,
        bearer: Secret,
        teamID: String,
        baseURL: URL = GrokManagementClient.defaultBaseURL,
        timeZone: TimeZone = .current
    ) {
        self.http = http
        self.bearer = bearer
        self.teamID = teamID
        self.baseURL = baseURL
        self.timeZone = timeZone
    }

    public func fetch(now: Date) async throws -> GrokManagementSnapshot {
        guard isSafeTeamID(teamID) else {
            throw GrokBillingError.noCredentials
        }
        async let balance = fetchBalance()
        async let spend = fetchTodaySpend(now: now)
        return GrokManagementSnapshot(
            remainingUSD: try await balance,
            costTodayUSD: try await spend
        )
    }

    private func fetchBalance() async throws -> Decimal? {
        do {
            let body: GrokPrepaidBalanceResponse = try await http.get(
                balanceURL,
                bearer: bearer,
                extraHeaders: [:],
                useSnakeCaseConversion: false,
                as: GrokPrepaidBalanceResponse.self
            )
            return body.remainingUSD
        } catch let httpErr as HTTPError {
            throw mapHTTP(httpErr)
        } catch is DecodingError {
            throw GrokBillingError.decodeFailed
        }
    }

    private func fetchTodaySpend(now: Date) async throws -> Decimal? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            return nil
        }
        let request = GrokUsageAnalyticsRequest.todayUSD(
            start: Self.stamp(start, timeZone: timeZone),
            end: Self.stamp(end, timeZone: timeZone),
            timezone: timeZone.identifier
        )
        do {
            let body: GrokUsageAnalyticsResponse = try await http.postJSON(
                usageURL,
                body: request,
                bearer: bearer,
                extraHeaders: [:],
                as: GrokUsageAnalyticsResponse.self
            )
            return body.totalUSD
        } catch let httpErr as HTTPError {
            throw mapHTTP(httpErr)
        } catch is DecodingError {
            throw GrokBillingError.decodeFailed
        }
    }

    private var balanceURL: URL {
        baseURL.appending(path: "v1/billing/teams/\(teamID)/prepaid/balance")
    }

    private var usageURL: URL {
        baseURL.appending(path: "v1/billing/teams/\(teamID)/usage")
    }

    private func mapHTTP(_ error: HTTPError) -> GrokBillingError {
        switch error.status {
        case 401, 403:
            return .unauthorized(status: error.status)
        default:
            return .billingEndpointFailed(status: error.status)
        }
    }

    /// Team id is a path segment. Refuse anything that is not UUID-ish.
    static func isSafeTeamID(_ raw: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        return !raw.isEmpty && raw.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private func isSafeTeamID(_ raw: String) -> Bool {
        Self.isSafeTeamID(raw)
    }

    static func stamp(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

// MARK: - Wire

struct GrokPrepaidBalanceResponse: Decodable, Sendable {
    let total: GrokCentsAmount?

    var remainingUSD: Decimal? {
        total?.usd
    }
}

struct GrokCentsAmount: Decodable, Sendable {
    let val: String?

    var usd: Decimal? {
        guard let val, let cents = Decimal(string: val) else { return nil }
        return abs(cents) / 100
    }
}

struct GrokUsageAnalyticsRequest: Encodable, Sendable {
    struct Analytics: Encodable, Sendable {
        struct TimeRange: Encodable, Sendable {
            let startTime: String
            let endTime: String
            let timezone: String
        }
        struct Value: Encodable, Sendable {
            let name: String
            let aggregation: String
        }
        let timeRange: TimeRange
        let timeUnit: String
        let values: [Value]
        let groupBy: [String]
        let filters: [String]
    }

    let analyticsRequest: Analytics

    static func todayUSD(start: String, end: String, timezone: String) -> GrokUsageAnalyticsRequest {
        GrokUsageAnalyticsRequest(
            analyticsRequest: Analytics(
                timeRange: Analytics.TimeRange(startTime: start, endTime: end, timezone: timezone),
                timeUnit: "TIME_UNIT_NONE",
                values: [Analytics.Value(name: "usd", aggregation: "AGGREGATION_SUM")],
                groupBy: ["description"],
                filters: []
            )
        )
    }
}

struct GrokUsageAnalyticsResponse: Decodable, Sendable {
    struct Series: Decodable, Sendable {
        struct Point: Decodable, Sendable {
            let values: [Double]?
        }
        let dataPoints: [Point]?
    }

    let timeSeries: [Series]?

    var totalUSD: Decimal {
        var sum: Decimal = 0
        for series in timeSeries ?? [] {
            for point in series.dataPoints ?? [] {
                for value in point.values ?? [] where value.isFinite {
                    sum += Decimal(value)
                }
            }
        }
        return sum
    }
}
