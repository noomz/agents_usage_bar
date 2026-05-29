import SwiftUI
import AppKit

/// Popover footer containing the Quit affordance.
///
/// Satisfies SHELL-06: "Quit action available from popover (footer) and Cmd-click context menu."
/// The Cmd-click context menu (secondary-click on the status item) is system-provided by
/// `MenuBarExtra(.window)` — it shows a "Quit" item automatically.
public struct FooterView: View {
    public var body: some View {
        HStack {
            Spacer()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
