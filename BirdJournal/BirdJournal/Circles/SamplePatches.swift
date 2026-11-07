import Pack
import SwiftUI

/// What a Guild shares, for someone not in one yet (issue #150, G8): a felt panel of patches from the bundled pack, labelled as
/// samples. They're nobody's finds. The join screen shows no real ones: the invite preview carries none, and it stays that way.
struct SamplePatches: View {
    @Environment(PackLibrary.self) private var library
    @Environment(\.dynamicTypeSize) private var typeSize

    /// A few well-known Los Angeles birds. The bundled pack paints them all, and a phone without it shows blanks.
    private static let birds: [(scientificName: String, commonName: String)] = [
        ("Sayornis nigricans", "Black Phoebe"),
        ("Calypte anna", "Anna's Hummingbird"),
        ("Melanerpes formicivorus", "Acorn Woodpecker"),
    ]
    private static let setID = "us-ca-la"

    var body: some View {
        FeltBoard {
            VStack(spacing: 10) {
                let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
                layout {
                    ForEach(Self.birds, id: \.scientificName) { bird in
                        PatchView(
                            state: library.patchArtState(scientificName: bird.scientificName, setID: Self.setID),
                            edition: PatchEdition.of(setID: Self.setID), tag: bird.commonName
                        )
                        .frame(maxWidth: 104)
                    }
                }
                .frame(maxWidth: .infinity)
                Text(Self.label)
                    .font(JournalFont.attribution)
                    .foregroundStyle(Color.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .boardLabel()
                    .accessibilityIdentifier("sample-patches-label")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous))
        .holdsPatchLight()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Self.label) \(Self.birds.map(\.commonName).formatted(.list(type: .and))).")
        .accessibilityIdentifier("sample-patches")
    }

    static let label = "Sample patches, to show what a Guild shares."
}
