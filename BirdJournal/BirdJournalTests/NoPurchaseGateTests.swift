import Foundation
import Testing
@testable import BirdJournal

// Issue #59 and ADR-0001: every feature stays free. Only the tip jar touches StoreKit, it never asks what was bought,
// and the screen says a tip unlocks nothing. The source tree is read from the Mac's disk, which a simulator test
// reaches.
@Suite("No purchase gate")
struct NoPurchaseGateTests {
    /// `BirdJournal/` (the app target and the package), from this file's path.
    static let sources = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    static let tipJar = "BirdJournal/Settings/TipJar.swift"

    static func swiftFiles() throws -> [(path: String, text: String)] {
        let roots = ["BirdJournal", "BirdJournalKit/Sources"].map { sources.appending(path: $0) }
        return try roots.flatMap { root -> [(String, String)] in
            let walker = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            return try walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.map { url in
                (String(url.path(percentEncoded: false).dropFirst(sources.path(percentEncoded: false).count)).trimmingPrefix("/").description,
                 try String(contentsOf: url, encoding: .utf8))
            }
        }
    }

    @Test("Only the tip jar imports StoreKit")
    func storeKitStaysInTheTipJar() throws {
        let files = try Self.swiftFiles()
        #expect(files.count > 50, "found only \(files.count) source files under \(Self.sources.path())")
        let importers = files.filter { $0.text.contains("import StoreKit") }.map(\.path)
        #expect(importers == [Self.tipJar])
    }

    @Test("Nothing asks StoreKit what was bought")
    func noEntitlementChecks() throws {
        let checks = ["currentEntitlements", "currentEntitlement(", "Transaction.all", "Transaction.latest", "latestTransaction", "AppStore.sync", "AppTransaction", "appStoreReceiptURL", "SubscriptionStatus"]
        for file in try Self.swiftFiles() {
            for check in checks {
                #expect(!file.text.contains(check), "\(file.path) checks a purchase with \(check)")
            }
        }
    }

    @Test("The tip jar sends nothing anywhere")
    func noServerReceipt() throws {
        let tipJar = try #require(try Self.swiftFiles().first { $0.path == Self.tipJar })
        for network in ["URLSession", "URLRequest", "jwsRepresentation", "UserDefaults", "@AppStorage"] {
            #expect(!tipJar.text.contains(network), "the tip jar uses \(network)")
        }
    }

    @Test("The copy says tips unlock nothing")
    func copySaysUnlocksNothing() {
        #expect(SupportView.unlocksNothing.contains("unlock nothing"))
        #expect(SupportView.unlocksNothing.contains("stays free"))
    }
}
