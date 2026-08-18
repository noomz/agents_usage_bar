import Foundation
import Testing
@testable import AgentsUsageBar

@Suite("GrokBillingResponseTests")
struct GrokBillingResponseTests {

    @Test func decodes_camel_and_snake_top_level() throws {
        let data = try fixture("billing-credits")
        let decoded = try JSONDecoder().decode(GrokBillingResponse.self, from: data)
        #expect(decoded.creditUsagePercent == 42.5)
        #expect(decoded.monthlyLimit == 1000)
        #expect(decoded.includedUsed == 425)
        #expect(decoded.prepaidBalance == 12.5)
        #expect(decoded.subscriptionTier == "supergrok")
        #expect(decoded.onDemandEnabled == false)
        #expect(decoded.billingPeriodEnd != nil)
    }

    @Test func decodes_nested_data_snake_case() throws {
        let data = try fixture("billing-nested-data")
        let decoded = try JSONDecoder().decode(GrokBillingResponse.self, from: data)
        #expect(decoded.monthlyLimit == 500)
        #expect(decoded.includedUsed == 400)
        #expect(decoded.creditUsagePercent == 80)
        #expect(decoded.subscriptionTier == "supergrok_plus")
    }

    @Test func makeQuota_uses_included_over_monthly() {
        let billing = GrokBillingResponse(
            creditUsagePercent: 42.5,
            monthlyLimit: 1000,
            includedUsed: 425
        )
        let quota = billing.makeQuota()
        #expect(quota?.used == 425)
        #expect(quota?.limit == 1000)
        #expect(quota?.remaining == 575)
    }

    @Test func makeQuota_percent_only_synthesizes_100_scale() {
        let billing = GrokBillingResponse(creditUsagePercent: 80)
        let quota = billing.makeQuota()
        #expect(quota?.limit == 100)
        #expect(quota?.used == 80)
    }

    @Test func unknown_future_fields_do_not_break_decode() throws {
        let json = Data(#"{ "monthlyLimit": 10, "brandNewField": { "x": 1 } }"#.utf8)
        let decoded = try JSONDecoder().decode(GrokBillingResponse.self, from: json)
        #expect(decoded.monthlyLimit == 10)
    }

    @Test func creditsURL_appends_billing_query() {
        let url = GrokBillingClient.creditsURL(from: GrokBillingClient.defaultBaseURL)
        #expect(url.path.hasSuffix("/billing"))
        #expect(url.query == "format=credits")
    }

    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/\(name).json")
        return try Data(contentsOf: url)
    }
}
