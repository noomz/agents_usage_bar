import Foundation
import Testing
@testable import AgentsUsageBar

@Suite("GrokManagementClientTests")
struct GrokManagementClientTests {

    @Test func prepaid_cents_are_absolute_dollars() throws {
        let json = Data(#"{ "total": { "val": "-1250" } }"#.utf8)
        let decoded = try JSONDecoder().decode(GrokPrepaidBalanceResponse.self, from: json)
        #expect(decoded.remainingUSD == Decimal(string: "12.5"))
    }

    @Test func usage_sums_all_series() throws {
        let json = Data(#"""
        {
          "timeSeries": [
            { "dataPoints": [ { "values": [0.10, 0.05] } ] },
            { "dataPoints": [ { "values": [1.25] } ] }
          ]
        }
        """#.utf8)
        let decoded = try JSONDecoder().decode(GrokUsageAnalyticsResponse.self, from: json)
        #expect(decoded.totalUSD == Decimal(string: "1.40"))
    }

    @Test func team_id_must_be_path_safe() {
        #expect(GrokManagementClient.isSafeTeamID("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
        #expect(!GrokManagementClient.isSafeTeamID(""))
        #expect(!GrokManagementClient.isSafeTeamID("../escape"))
        #expect(!GrokManagementClient.isSafeTeamID("a/b"))
    }
}
