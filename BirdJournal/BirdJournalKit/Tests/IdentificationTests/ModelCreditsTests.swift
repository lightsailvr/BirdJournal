import Foundation
import Testing
@testable import Identification

// Issue #11: the credits screen shows "Powered by BirdNET" and the licenses of the pinned models (spec "Attribution",
// DECISIONS.md "Audio and identification"), with the license texts the manifest downloads beside the models.
@Suite("Model credits")
struct ModelCreditsTests {
    @Test("the attribution names both models with their licenses and sources")
    func attributions() {
        #expect(ModelCredits.poweredBy == "Powered by BirdNET")
        let names = ModelCredits.models.map(\.name)
        #expect(names.contains { $0.contains("BirdNET+ V3.0") })
        #expect(names.contains { $0.contains("geomodel") })
        #expect(ModelCredits.models.map(\.license) == ["CC BY-SA 4.0", "Apache-2.0"])
        for model in ModelCredits.models {
            #expect(model.sourceURL.scheme == "https")
            #expect(model.licenseURL.scheme == "https")
            #expect(!model.licenseFileNames.isEmpty)
        }
    }

    @Test("every license text the manifest pins loads from the package bundle")
    func licenseTexts() throws {
        for model in ModelCredits.models {
            for file in model.licenseFileNames {
                let text = try ModelCredits.licenseText(fileName: file)
                #expect(text.count > 500, "\(file) is too short to be the license")
            }
        }
    }

    @Test("a license file that is not bundled is reported")
    func missingLicense() {
        #expect(throws: ModelError.self) { try ModelCredits.licenseText(fileName: "NOPE.txt") }
    }
}
