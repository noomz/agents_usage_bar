import SwiftUI

/// Custom `ButtonStyle` with explicit hover + pressed visual states (Plan 01.09 — UAT Test 2 gap closure).
///
/// Why this style exists:
///   On macOS 26 + ad-hoc-signed debug builds, the native `.buttonStyle(.bordered)` hover
///   feedback is too subtle for users to perceive. UAT Test 2 reported "hover on button has no
///   diff style from still button" (cosmetic). This style guarantees a visibly distinct fill
///   between idle, hovering, and pressed states by driving the background opacity from explicit
///   `.onHover` tracking and `configuration.isPressed`.
///
/// B5 invariant: This file does NOT redeclare the clock environment key or extend
/// EnvironmentValues. ClockKey ownership remains solely in
/// `UI/Environment/ClockEnvironmentKey.swift`. This style is pure presentation.
///
/// Threat model (T-01-09-01): N/A — no input, no state exfiltration, no `Secret`-derived data
/// flows through this style. Only hover/pressed booleans are read.
public struct HoverableBorderedButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        _HoverContainer(label: configuration.label, isPressed: configuration.isPressed)
    }
}

/// Internal hover-state container. `ButtonStyle.makeBody` is a value context where `@State`
/// cannot live directly on the style — this wrapper view owns the `@State private var isHovering`
/// and is the standard SwiftUI pattern for ButtonStyles that need hover state.
private struct _HoverContainer<Label: View>: View {
    let label: Label
    let isPressed: Bool
    @State private var isHovering: Bool = false

    var body: some View {
        label
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(.primary)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(fillOpacity))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onHover { hovering in
                isHovering = hovering
            }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.08), value: isPressed)
    }

    /// Pressed > hovering > idle. Opacity values picked so each state is visibly distinct
    /// in both light and dark mode on macOS 14+ without resorting to hex literals.
    private var fillOpacity: Double {
        if isPressed { return 0.18 }
        if isHovering { return 0.12 }
        return 0.06
    }
}

// MARK: - Preview

#Preview("HoverableBorderedButtonStyle") {
    HStack(spacing: 8) {
        Button {
            // no-op
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .buttonStyle(HoverableBorderedButtonStyle())
        .tint(.accentColor)

        Button("Quit") {
            // no-op
        }
        .buttonStyle(HoverableBorderedButtonStyle())
    }
    .padding()
    .frame(width: 360)
}
