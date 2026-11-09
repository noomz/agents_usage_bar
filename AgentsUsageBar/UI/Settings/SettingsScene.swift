import Sparkle
import SwiftUI

/// Root SwiftUI view for the Settings scene. Contains three tabs per D-07.
/// Tab content is implemented in Plans 05-03 (General), 05-04 (Providers), 05-06 (About).
struct SettingsScene: View {
    /// The app's single Sparkle updater, for the About tab's manual check.
    let updater: SPUUpdater

    var body: some View {
        TabView {
            SettingsGeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(0)

            SettingsProvidersTab()
                .tabItem { Label("Providers", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(1)

            SettingsAboutTab(updater: updater)
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(2)
        }
        .frame(minWidth: 520, minHeight: 400)
    }
}
