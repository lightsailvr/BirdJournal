import Foundation
import Testing
@testable import BirdJournal

@Suite("Build version")
@MainActor
struct VersionTests {
    @Test("Cloud versions show the distributed bundle's marketing version and build")
    func cloudVersion() {
        #expect(SettingsView.versionText(info: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "42"]) == "0.1.0 (42)")
    }

    @Test("local builds identify their commit, including uncommitted source")
    func localVersion() {
        for commit in ["78a7ad1", "78a7ad1-dirty", "unknown"] {
            #expect(SettingsView.versionText(info: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1", "BirdJournalBuildCommit": commit]) == "0.1.0 (local · \(commit))")
        }
    }

    @Test("the app and embedded widget inherit the same version")
    func widgetMatchesApp() throws {
        let url = try #require(Bundle.main.builtInPlugInsURL).appending(path: "BirdJournalWidgets.appex")
        let widget = try #require(Bundle(url: url)?.infoDictionary)
        let app = try #require(Bundle.main.infoDictionary)
        #expect(widget["CFBundleShortVersionString"] as? String == app["CFBundleShortVersionString"] as? String)
        #expect(widget["CFBundleVersion"] as? String == app["CFBundleVersion"] as? String)
    }
}
