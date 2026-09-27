import Pack
import SwiftUI

/// Settings on the phone (issue #11): the species pack and the credits screen the licenses ask for.
struct SettingsView: View {
    var body: some View {
        List {
            Section("Species pack") {
                NavigationLink(BundledPack.pack?.info.name ?? "Species pack", value: ContentView.Screen.speciesPack)
            }
            Section("About") {
                NavigationLink("Credits", value: ContentView.Screen.credits)
                LabeledContent("Version", value: Self.versionText)
            }
        }
        .navigationTitle("Settings")
    }

    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
