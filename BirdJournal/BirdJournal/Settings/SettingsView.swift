import Pack
import SwiftUI

/// Settings on the phone (issue #11): the species packs (#13) and the credits screen the licenses ask for.
struct SettingsView: View {
    @Environment(PackLibrary.self) private var library

    var body: some View {
        List {
            Section("Species packs") {
                NavigationLink(value: ContentView.Screen.packs) {
                    LabeledContent("Species packs", value: library.packs.map(\.info.name).joined(separator: ", "))
                }
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
