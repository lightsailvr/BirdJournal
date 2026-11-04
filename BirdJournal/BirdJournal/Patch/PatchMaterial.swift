import SwiftUI

/// The materials of what you collect (issue #134, guide page 16): felt, card stock and the shadow. Chrome stays native and
/// matte: these belong to the patches, their board and their paper card, never to controls, lists or navigation.
enum PatchMaterial {
    /// The blue of the transfer pen on a pattern.
    static let transferPen = Color(hex: 0x3F5FA8)
    /// The felt's veil: #081A1D at 60%, so the board sits in the page's colour.
    static let feltVeil = Color(hex: 0x081A1D)

    /// The soft shadow's strength: 38%, lightening to 28% on the light board.
    nonisolated static func softShadow(_ scheme: ColorScheme) -> Float {
        scheme == .dark ? 0.38 : 0.28
    }
}

extension Color {
    /// Card stock: warm ivory cotton paper, fixed in both appearances.
    static let cardStock = Color(hex: 0xF1EBDD)
}

/// The board's material behind patches: deep petrol wool felt under its veil, or oatmeal linen in the light appearance;
/// the felt darkens under Increase Contrast.
struct BoardMaterial: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Group {
            if colorScheme == .dark {
                Image("MaterialFelt")
                    .resizable(resizingMode: .tile)
                    .overlay(PatchMaterial.feltVeil.opacity(contrast == .increased ? 0.85 : 0.6))
            } else {
                Image("MaterialLinen")
                    .resizable(resizingMode: .tile)
                    .overlay(Color.white.opacity(contrast == .increased ? 0.72 : 0.45))
            }
        }
        .accessibilityHidden(true)
    }
}

extension View {
    /// The material behind a whole sheet of patches, reaching under the bars (issue #134: only behind the patches, it stopped
    /// short of the page's edges and looked pasted on).
    func patchSheetBackground() -> some View {
        background { BoardMaterial().ignoresSafeArea() }
    }
}

/// A small panel of patches on a page that isn't theirs: the material inside a quiet inner keyline.
struct FeltBoard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 18)
            .background {
                BoardMaterial()
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.ink.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .padding(6)
                            .accessibilityHidden(true)
                    }
            }
    }
}

/// Paper card stock: the ivory under its fibre texture, a fine inner keyline, and a slot punched at the top, like the
/// backer a patch is sold on. Printed matter: no embossing, foil or glows. Everything on it reads in the light scheme.
struct CardStockSurface: ViewModifier {
    static let radius: CGFloat = 8

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        content
            .background {
                Color.cardStock
                    .overlay {
                        Image("MaterialPaper")
                            .resizable(resizingMode: .tile)
                            .blendMode(.multiply)
                            .opacity(0.5)
                    }
                    .clipShape(shape)
                    // On the stock, not the card: on the whole card the type would take it too.
                    .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 6)
                    .accessibilityHidden(true)
            }
            .overlay {
                RoundedRectangle(cornerRadius: max(Self.radius - 5, 2), style: .continuous)
                    .strokeBorder(Color.cardEdge.opacity(0.4), lineWidth: 0.75)
                    .padding(7)
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .top) {
                Capsule()
                    .fill(Color.black.opacity(0.32))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.5), lineWidth: 0.5))
                    .frame(width: 26, height: 7)
                    .padding(.top, 12)
                    .accessibilityHidden(true)
            }
            .environment(\.colorScheme, .light)
    }
}
