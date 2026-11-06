import SwiftUI

/// The mascot: the House Finch in glasses on its branch, as a cut patch with its soft shadow (issue #150). It's a plain picture,
/// made from the maintainer's approved patch by `packbuilder mascot-assets`, with no lit layers and no shader. It's for the first
/// launch, the sign-in page and the empty pages, never a set's header or the Listen hero; decorative, so VoiceOver skips it.
struct PerchedFinch: View {
    /// The picture's side, patch and shadow: the patch is 110 pt at the default text size. It grows with the text, not all the way.
    @ScaledMetric(relativeTo: .title2) private var side: CGFloat = 132
    private let largest: CGFloat = 200

    var body: some View {
        Image("PerchedFinch")
            .resizable()
            .scaledToFit()
            .frame(width: min(side, largest), height: min(side, largest))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
