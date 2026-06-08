import Testing
import Foundation

/// Plan 02.07 — UI-09 source-grep contract tests for the menu bar tint wiring.
///
/// Verifies (a) `AgentsUsageBarApp.swift` consumes `dependencies.store.menuBarTint`
/// at the `MenuBarExtra` label site with `.symbolRenderingMode(.hierarchical)`
/// (Pitfall 9), and (b) `AggregateStore.swift` exposes the `menuBarTint` and
/// `maxQuotaFraction` computed properties publicly so the App tier can read them.
///
/// Mirrors the Phase 1 W7 source-grep pattern (#filePath-relative repo-root walk).
@MainActor
@Suite("MenuBarTint UI-09 contract tests (Plan 02.07)")
struct MenuBarTintTests {

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // UITests/
            .deletingLastPathComponent()  // AgentsUsageBarTests/
            .deletingLastPathComponent()  // repo root
    }

    private func readSource(_ relativePath: String) throws -> String {
        let url = repoRoot().appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("AgentsUsageBarApp.swift wires dependencies.store.menuBarTint at the MenuBarExtra label (UI-09)")
    func agentsUsageBarApp_source_uses_menuBarTint_at_label_site() throws {
        let source = try readSource("AgentsUsageBar/App/AgentsUsageBarApp.swift")
        #expect(source.contains("dependencies.store.menuBarTint"),
                "AgentsUsageBarApp.swift must bind .foregroundStyle to dependencies.store.menuBarTint")
        #expect(source.contains("symbolRenderingMode(.hierarchical)"),
                "AgentsUsageBarApp.swift must use .symbolRenderingMode(.hierarchical) for the menu bar icon (Pitfall 9)")
    }

    @Test("AggregateStore.swift exposes public var menuBarTint (UI-09)")
    func aggregateStore_menuBarTint_function_isPublic() throws {
        let source = try readSource("AgentsUsageBar/Aggregation/AggregateStore.swift")
        #expect(source.contains("public var menuBarTint"),
                "AggregateStore.swift must expose `public var menuBarTint` for the App-tier MenuBarExtra label binding")
    }

    @Test("AggregateStore.swift exposes public var maxQuotaFraction (UI-09)")
    func aggregateStore_maxQuotaFraction_isPublic() throws {
        let source = try readSource("AgentsUsageBar/Aggregation/AggregateStore.swift")
        #expect(source.contains("public var maxQuotaFraction"),
                "AggregateStore.swift must expose `public var maxQuotaFraction` as the source of truth for menuBarTint")
    }
}
