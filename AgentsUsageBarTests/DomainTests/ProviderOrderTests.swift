import Foundation
import Testing
@testable import AgentsUsageBar

/// Shared provider ordering (SPEC V31) and the popover adopting it (V32).
@Suite("Provider order")
struct ProviderOrderTests {

    private func order(_ ids: [ProviderID], preference: [ProviderID] = []) -> [String] {
        ProviderID.ordered(ids, id: { $0 }, preference: preference).map(\.rawValue)
    }

    private let gpu = ProviderID(rawValue: "engine.gpu-box")
    private let alpha = ProviderID(rawValue: "engine.alpha")

    @Test("unset: allKnown order, then engine.* by slug")
    func unset() {
        let ids: [ProviderID] = [gpu, .llamacpp, .gemini, alpha, .openrouter, .claude]
        #expect(order(ids) == ["openrouter", "claude", "gemini", "llamacpp", "engine.alpha", "engine.gpu-box"])
    }

    @Test("listed first in given order, then allKnown, then engines")
    func listed() {
        let ids: [ProviderID] = [.openrouter, .claude, .codex, .gemini, gpu, alpha]
        #expect(order(ids, preference: [gpu, .codex, .claude])
                == ["engine.gpu-box", "codex", "claude", "openrouter", "gemini", "engine.alpha"])
    }

    @Test("stale listed ids are skipped")
    func stale() {
        let ids: [ProviderID] = [.claude, .codex]
        #expect(order(ids, preference: [ProviderID(rawValue: "engine.gone"), .codex]) == ["codex", "claude"])
    }

    @Test("UserDefaults reader: comma list, trimmed, lowercased; empty when unset")
    func reader() {
        let suite = "test.aub.order.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(defaults.aubProviderOrder.isEmpty)
        defaults.set("Codex, claude,engine.gpu-box", forKey: AUBDefaultsKey.providerOrder)
        #expect(defaults.aubProviderOrder == [.codex, .claude, gpu])
    }

    @Test("popover uses the shared order, not displayName")
    func popover() {
        let states = [
            ProviderState(id: .codex, displayName: "Codex"),
            ProviderState(id: .claude, displayName: "Claude"),
            ProviderState(id: .openrouter, displayName: "OpenRouter"),
        ]
        #expect(PopoverRootView.ordered(states, preference: []).map(\.id) == [.openrouter, .claude, .codex])
        #expect(PopoverRootView.ordered(states, preference: [.codex]).map(\.id) == [.codex, .openrouter, .claude])
    }
}
