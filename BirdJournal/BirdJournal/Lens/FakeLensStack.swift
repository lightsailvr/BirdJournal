#if DEBUG
import Identification
import LensSession
import UIKit

/// A hard-coded stack and pack profiles for driving the lens without the engine or a species pack (issue #7:
/// "demonstrated on the mock display with a hard-coded fake stack"). Photos are SF Symbols on a dark card until
/// the pack builder (#8) supplies real crops. The last species has no profile, to show the name-only pages.
enum FakeLensStack {
    static let species: [Species] = [
        Species(index: 0, scientificName: "Sayornis nigricans", commonName: "Black Phoebe", taxonomicClass: "Aves"),
        Species(index: 1, scientificName: "Haemorhous mexicanus", commonName: "House Finch", taxonomicClass: "Aves"),
        Species(index: 2, scientificName: "Melozone crissalis", commonName: "California Towhee", taxonomicClass: "Aves"),
        Species(index: 3, scientificName: "Calypte anna", commonName: "Anna's Hummingbird", taxonomicClass: "Aves"),
        Species(index: 4, scientificName: "Psaltriparus minimus", commonName: "Bushtit", taxonomicClass: "Aves"),
    ]

    static let scores: [Float] = [0.82, 0.61, 0.74, 0.93, 0.55]

    static let profiles: [String: SpeciesProfile] = [
        "Sayornis nigricans": SpeciesProfile(
            photo: LensImage(id: "sayornis-nigricans"),
            fieldMarks: "Sooty black with a clean white belly. Perches low near water and wags its tail.",
            size: "Sparrow-sized",
            habitat: "Streams, ponds, lawns",
            photoCredit: "Photo: placeholder, CC0"
        ),
        "Haemorhous mexicanus": SpeciesProfile(
            photo: LensImage(id: "haemorhous-mexicanus"),
            fieldMarks: "Streaky brown; males wear a rosy red head and chest. Chatty flocks at feeders.",
            size: "Sparrow-sized",
            habitat: "Yards, parks, scrub",
            photoCredit: "Photo: placeholder, CC0"
        ),
        "Melozone crissalis": SpeciesProfile(
            photo: LensImage(id: "melozone-crissalis"),
            fieldMarks: "Plain grey-brown with a rusty patch under the tail. Scratches in leaf litter.",
            size: "Larger than a sparrow",
            habitat: "Chaparral, gardens",
            photoCredit: "Photo: placeholder, CC0"
        ),
        "Calypte anna": SpeciesProfile(
            photo: LensImage(id: "calypte-anna"),
            fieldMarks: "Green back, grey belly; the male's whole head flashes rose-pink. Buzzy, scratchy song.",
            size: "Tiny",
            habitat: "Gardens, eucalyptus",
            photoCredit: "Photo: placeholder, CC0"
        ),
    ]

    /// The first `count` fake species as a stack, in admission order.
    static func stack(count: Int) -> CandidateStack {
        CandidateStack(candidates: species.prefix(count).enumerated().map { offset, species in
            Candidate(
                species: species,
                score: scores[offset],
                windowsAboveThreshold: 2,
                firstHeardAt: Double(offset) * 10,
                lastHeardAt: Double(offset) * 10 + 3,
                admittedAt: Double(offset) * 10 + 3
            )
        })
    }

    static func profile(for species: Species) -> SpeciesProfile? {
        profiles[species.scientificName]
    }

    /// A 260-pixel bird symbol on a dark card. The Display lays a bundled image out at its pixel size on the
    /// 600-pixel canvas, so this is about the width the pack's lens crops should take to leave room for the name
    /// beside them.
    static func image(for image: LensImage) -> UIImage? {
        guard profiles.values.contains(where: { $0.photo == image }) else { return nil }
        let size = CGSize(width: 260, height: 260)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(white: 0.08, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let configuration = UIImage.SymbolConfiguration(pointSize: 140, weight: .regular)
            guard let symbol = UIImage(systemName: "bird.fill", withConfiguration: configuration)?
                .withTintColor(UIColor(white: 0.85, alpha: 1), renderingMode: .alwaysOriginal)
            else { return }
            let origin = CGPoint(x: (size.width - symbol.size.width) / 2, y: (size.height - symbol.size.height) / 2)
            symbol.draw(at: origin)
        }
    }
}
#endif
