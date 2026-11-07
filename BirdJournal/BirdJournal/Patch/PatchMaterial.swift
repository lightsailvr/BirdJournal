import SwiftUI
import UIKit

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
                    .overlay(Color.white.opacity(contrast == .increased ? 0.55 : 0.45))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Words on the board: straight on the material, or on a solid surface under Increase Contrast (guide page 14). A view that's
/// on the material only some of the time says so with `isOnBoard`, and elsewhere stays where it was.
struct BoardLabel: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    var horizontal: CGFloat = 6
    var vertical: CGFloat = 3
    var isOnBoard = true

    func body(content: Content) -> some View {
        let increased = isOnBoard && contrast == .increased
        content
            .padding(.horizontal, increased ? horizontal : 0)
            .padding(.vertical, increased ? vertical : 0)
            .background(increased ? Color.paper : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

extension View {
    func boardLabel(horizontal: CGFloat = 6, vertical: CGFloat = 3, isOnBoard: Bool = true) -> some View {
        modifier(BoardLabel(horizontal: horizontal, vertical: vertical, isOnBoard: isOnBoard))
    }

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

/// The fibre of an Atlas plate, as the reference prints it: at the mock's scale of one texture pixel to a CSS pixel,
/// which is 1.34 pt at this screen's width. It's coarser than the paper card's, and it starts at the plate's corner, as the mock's does.
struct PlatePaper: View {
    private static let fibre = UIImage(named: "MaterialPaper")?.cgImage

    var body: some View {
        if let fibre = Self.fibre {
            Image(decorative: fibre, scale: 1 / 1.34)
                .resizable(resizingMode: .tile)
                .blendMode(.multiply)
                // The mock's stock is a touch paler than the app's: this lands on its (222,209,181), measured on the rendered page.
                .opacity(0.9)
        }
    }
}

/// Paper card stock: the ivory under its fibre texture, a fine inner keyline, and a slot punched at the top, like the
/// backer a patch is sold on. Printed matter: no embossing, foil or glows. Everything on it reads in the light scheme.
/// On the linen (the light appearance) the fibre is eased so the card measures lighter than the cloth under it, and a fine
/// edge sets it off; on the felt it glows as it is (issue #150). A `.plate` is a page of the Atlas, printed rather than sold on a
/// card, and the same paper in both appearances (`PlatePaper`): it has no backer's slot or inner keyline, and it isn't eased for linen, since
/// a plate sits on the page.
struct CardStockSurface: ViewModifier {
    enum Kind {
        case backer, plate
    }

    static let radius: CGFloat = 8
    private let kind: Kind
    /// The backer's slot: a patch's card has one, a printed page doesn't.
    private let isPunched: Bool

    init(_ kind: Kind = .backer, isPunched: Bool = true) {
        self.kind = kind
        self.isPunched = isPunched
    }

    /// The page's appearance: this modifier reads it from outside the light scheme it sets below.
    @Environment(\.colorScheme) private var pageScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        let onLinen = pageScheme == .light
        content
            .background {
                Color.cardStock
                    .overlay {
                        if kind == .plate {
                            PlatePaper()
                        } else {
                            Image("MaterialPaper")
                                .resizable(resizingMode: .tile)
                                .blendMode(.multiply)
                                .opacity(onLinen ? 0.15 : 0.5)
                        }
                    }
                    .clipShape(shape)
                    // On the stock, not the card: on the whole card the type would take it too.
                    .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 6)
                    .overlay {
                        if onLinen, kind == .backer { shape.strokeBorder(Color.cardEdge.opacity(0.55), lineWidth: 1) }
                    }
                    .accessibilityHidden(true)
            }
            .overlay {
                if kind == .backer {
                    RoundedRectangle(cornerRadius: max(Self.radius - 5, 2), style: .continuous)
                        .strokeBorder(Color.cardEdge.opacity(0.4), lineWidth: 0.75)
                        .padding(7)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .top) {
                if kind == .backer, isPunched {
                    Capsule()
                        .fill(Color.black.opacity(0.32))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.5), lineWidth: 0.5))
                        .frame(width: 26, height: 7)
                        .padding(.top, 12)
                        .accessibilityHidden(true)
                }
            }
            .environment(\.colorScheme, .light)
    }
}
