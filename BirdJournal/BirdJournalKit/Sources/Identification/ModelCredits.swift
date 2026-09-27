import Foundation

/// One pinned model's attribution (models/manifest.json): what the credits screen names and links.
public struct ModelAttribution: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    public let role: String
    public let license: String
    /// The license's own text online.
    public let licenseURL: URL
    public let sourceURL: URL
    /// License and terms files shipped beside the model in the package's `Models` resource folder.
    public let licenseFileNames: [String]
}

/// The attribution the models' licenses ask for (spec "Attribution"; DECISIONS.md "Audio and identification").
public enum ModelCredits {
    public static let poweredBy = "Powered by BirdNET"

    public static let acoustic = ModelAttribution(
        name: "BirdNET+ V3.0 (preview 3.1)",
        role: "Acoustic model: 11,560 species from sound. BirdNET is developed by the K. Lisa Yang Center for Conservation Bioacoustics at the Cornell Lab of Ornithology and Chemnitz University of Technology.",
        license: "CC BY-SA 4.0",
        licenseURL: URL(string: "https://creativecommons.org/licenses/by-sa/4.0/")!,
        sourceURL: URL(string: "https://doi.org/10.5281/zenodo.20703646")!,
        licenseFileNames: ["TERMS_OF_USE.txt"]
    )

    public static let geomodel = ModelAttribution(
        name: "BirdNET+ geomodel v3.0.4",
        role: "Regional filter: which species occur at a place and week of the year.",
        license: "Apache-2.0",
        licenseURL: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!,
        sourceURL: URL(string: "https://github.com/birdnet-team/geomodel/releases/tag/v3.0.4")!,
        licenseFileNames: ["LICENSE-MODELS.md", "ACCEPTABLE_USE.md"]
    )

    public static let models = [acoustic, geomodel]

    /// The text of a license file pinned by the manifest, from the package bundle.
    public static func licenseText(fileName: String) throws -> String {
        try String(contentsOf: ONNXRuntime.bundledModelURL(fileName), encoding: .utf8)
    }
}
