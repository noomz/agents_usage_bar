import Foundation
import Testing
@testable import AgentsUsageBar

@Suite("PiLocalUsageTests")
struct PiLocalUsageTests {

    @Test func reduce_keeps_today_local_skips_cloud_and_yesterday() {
        let catalog = PiLocalCatalog(names: [
            PiProviderName(rawValue: "DRM-SWAP"),
            PiProviderName(rawValue: "llama.cpp"),
        ])
        let todayStart = Date(timeIntervalSince1970: 1_700_000_000)
        let local = record(provider: "DRM-SWAP", tokens: 33482, at: todayStart.addingTimeInterval(60))
        let cloud = record(provider: "openrouter", tokens: 20, at: todayStart.addingTimeInterval(120))
        let yesterday = record(provider: "DRM-SWAP", tokens: 999, at: todayStart.addingTimeInterval(-1))
        var acc = PiLocalUsage.Acc()
        PiLocalUsage.reduce(
            records: [local, cloud, yesterday],
            catalog: catalog,
            todayStart: todayStart,
            into: &acc
        )
        #expect(acc.tokens == 33482)
        #expect(acc.providers.map(\.rawValue).sorted() == ["DRM-SWAP"])
    }

    private func record(provider: String, tokens: Int, at timestamp: Date) -> PiSessionRecord {
        let line = #"{"type":"message","timestamp":"\#(iso(timestamp))","message":{"role":"assistant","provider":"\#(provider)","model":"m","usage":{"totalTokens":\#(tokens),"cost":{"total":0}}}}"#
        return PiSessionRecord.decode(from: line)!
    }

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}
