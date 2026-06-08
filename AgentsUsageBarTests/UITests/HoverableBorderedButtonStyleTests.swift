import Testing
import Foundation

/// Plan 01.09 source-grep tests for `HoverableBorderedButtonStyle.swift` and the FooterView wiring.
///
/// These tests verify the gap-closure artifact for UAT Test 2 (cosmetic hover state):
///   (a) The custom `ButtonStyle` exists and conforms to `ButtonStyle`.
///   (b) Explicit `.onHover` plumbing is in place — the load-bearing fix.
///   (c) Only `Color.primary` opacity-based fills are used; no hex / UIColor / asset-bundle Color.
///   (d) FooterView wires the new style on both buttons and no longer uses `.buttonStyle(.bordered)`.
///
/// Path resolution mirrors `FooterViewTests`: `#filePath`-based repo-root walk.
@MainActor
@Suite("HoverableBorderedButtonStyle source contract tests (01.09 gap closure)")
struct HoverableBorderedButtonStyleTests {

    /// Reads any source file under the repo root using a `#filePath`-based walk.
    private func source(at relativePath: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()  // UITests/
            .deletingLastPathComponent()  // AgentsUsageBarTests/
            .deletingLastPathComponent()  // repo root
        let path = repoRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: path, encoding: .utf8)
    }

    @Test("Style file declares HoverableBorderedButtonStyle conforming to ButtonStyle")
    func declaresStyleConformance() throws {
        let src = try source(at: "AgentsUsageBar/UI/Components/HoverableBorderedButtonStyle.swift")
        #expect(src.contains("struct HoverableBorderedButtonStyle: ButtonStyle"),
                "HoverableBorderedButtonStyle.swift must declare `struct HoverableBorderedButtonStyle: ButtonStyle`")
    }

    @Test("Style file wires .onHover for explicit hover state (load-bearing gap fix)")
    func wiresOnHover() throws {
        let src = try source(at: "AgentsUsageBar/UI/Components/HoverableBorderedButtonStyle.swift")
        #expect(src.contains(".onHover { hovering in"),
                "HoverableBorderedButtonStyle.swift must contain `.onHover { hovering in` — the load-bearing line that fixes UAT Test 2")
        #expect(src.contains("isHovering = hovering"),
                "HoverableBorderedButtonStyle.swift must assign `isHovering = hovering` inside .onHover")
    }

    @Test("Style file uses only Color.primary opacity-based fills, no hex / UIColor / asset Color")
    func usesOnlyColorPrimaryOpacity() throws {
        let src = try source(at: "AgentsUsageBar/UI/Components/HoverableBorderedButtonStyle.swift")
        #expect(src.contains("Color.primary"),
                "HoverableBorderedButtonStyle.swift must use `Color.primary` for the fill")
        #expect(!src.contains("Color(red:"),
                "HoverableBorderedButtonStyle.swift must NOT use `Color(red:` literals")
        #expect(!src.contains("Color(hex:"),
                "HoverableBorderedButtonStyle.swift must NOT use `Color(hex:` literals")
        #expect(!src.contains("Color(.system"),
                "HoverableBorderedButtonStyle.swift must NOT use `Color(.system...)` asset-bundle lookups")
        #expect(!src.contains("UIColor"),
                "HoverableBorderedButtonStyle.swift must NOT reference UIColor (iOS-only)")
    }

    @Test("FooterView wires HoverableBorderedButtonStyle on both buttons and drops .bordered")
    func footerViewWiresNewStyle() throws {
        let footerSrc = try source(at: "AgentsUsageBar/UI/FooterView.swift")
        let occurrences = footerSrc.components(separatedBy: "HoverableBorderedButtonStyle()").count - 1
        #expect(occurrences == 2,
                "FooterView.swift must contain exactly 2 occurrences of `HoverableBorderedButtonStyle()` (one per footer button); found \(occurrences)")
        #expect(!footerSrc.contains(".buttonStyle(.bordered)"),
                "FooterView.swift must NOT contain `.buttonStyle(.bordered)` after the modifier swap")
    }
}
