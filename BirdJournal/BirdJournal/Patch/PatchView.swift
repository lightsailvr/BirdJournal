import SwiftUI

/// One patch as an object (issue #134, guide pages 9 and 13): its painting, lit by the phone's tilt with a shadow opposite
/// the light, or the same patch part way through being sewn (issue #135). Without a painting it's the edition's blank (guide
/// page 15): the bird's name on a paper tag when `tag` says so, whether the painting isn't on the phone or wouldn't decode, or
/// "Being sewn" while it's on its way. A decoration: whoever shows it says what it is to VoiceOver.
struct PatchView: View {
    enum Face: Equatable {
        case sewn
        /// Thread laid along the stitch order as far as `sewnTo` (`StitchTimeline`); bare twill and transfer pen beyond it.
        case stitching(sewnTo: Float)
    }

    let art: PatchArt?
    let edition: PatchEdition
    let face: Face
    let size: PatchTextures.Size
    /// The name on a blank's paper tag.
    let tag: String?
    /// The painting is on its way (`PatchArtState.beingSewn`); it fills in when it arrives.
    let beingSewn: Bool
    /// What's already decoded shows at once: a patch scrolled back to doesn't flash its blank for a frame.
    @State private var loaded: PatchTextures.Loaded?
    /// `art` couldn't be read. A file that won't decode is a missing painting, not a patch left loading.
    @State private var failed = false

    /// - Parameter decoded: the pictures, for a surface that has them to hand: a stitch-in redraws this every frame, and the
    ///   cache may let go of them during it.
    init(art: PatchArt?, edition: PatchEdition, face: Face = .sewn, size: PatchTextures.Size = .thumbnail, tag: String? = nil, decoded: PatchTextures.Loaded? = nil) {
        self.art = art
        self.edition = edition
        self.face = face
        self.size = size
        self.tag = tag
        beingSewn = false
        _loaded = State(initialValue: decoded ?? art.flatMap { PatchTextures.cached($0, size: size) })
    }

    /// A found bird's patch, however its painting stands: `tag` is its name, for the blank's paper tag.
    init(state: PatchArtState, edition: PatchEdition, size: PatchTextures.Size = .thumbnail, tag: String, decoded: PatchTextures.Loaded? = nil) {
        art = state.art
        self.edition = edition
        face = .sewn
        self.size = size
        self.tag = tag
        beingSewn = state == .beingSewn
        _loaded = State(initialValue: decoded ?? state.art.flatMap { PatchTextures.cached($0, size: size) })
    }

    private var sewnTo: Float {
        if case .stitching(let sewnTo) = face { return sewnTo }
        return StitchTimeline.allSewn
    }

    /// The edition's one twill, so every stitch-in in a set starts from the same cloth; a pack's own measured ground (it
    /// varies with what was painted beside the cord) only for a set the app doesn't know yet.
    private var twill: Color {
        if edition == PatchEdition.of(setID: nil), let ground = art.flatMap({ Color(hexString: $0.ground) }) { return ground }
        return edition.twill
    }

    var body: some View {
        Color.clear
            .aspectRatio(edition.aspect, contentMode: .fit)
            .overlay {
                if let loaded {
                    LitPatch(loaded: loaded, ground: twill, sewnTo: sewnTo, room: size == .thumbnail ? 14 : 34)
                } else {
                    PatchBlank(edition: edition, tag: art == nil || failed ? tag : nil, beingSewn: beingSewn)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: art) {
                failed = false
                guard let art else {
                    loaded = nil
                    return
                }
                let decoded = await PatchTextures.load(art, size: size)
                guard !Task.isCancelled else { return }
                loaded = decoded
                failed = decoded == nil
            }
    }
}

/// The patch under the shader. The only view reading the light, so a tilt re-runs its shader and not the board's layout.
struct LitPatch: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let loaded: PatchTextures.Loaded
    let ground: Color
    /// How far along the stitch order the thread is laid.
    let sewnTo: Float
    /// Around the patch for its shadow, in points.
    let room: CGFloat
    /// A light that stays put, for an image rather than a screen (the share image, #136); nil follows the phone's.
    var fixedLight: SIMD2<Double>? = nil

    var body: some View {
        let light = fixedLight ?? PatchLight.shown(PatchLight.shared.direction, reduceMotion: PatchMotion.reduces(system: reduceMotion))
        let direction = CGPoint(x: light.x, y: light.y)
        let softStrength = PatchMaterial.softShadow(colorScheme)
        let (room, sewnTo) = (room, sewnTo)
        let (layers, texel, ground) = (loaded.layers, loaded.texel, ground)
        loaded.colour
            .resizable()
            .padding(room)
            .visualEffect { content, proxy in
                let face = CGSize(width: proxy.size.width - room * 2, height: proxy.size.height - room * 2)
                return content.layerEffect(
                    ShaderLibrary.patchLit(
                        .float2(direction),
                        .float4(room, room, face.width, face.height),
                        .float2(texel),
                        .float(max(min(face.width / 300, 1), 0.28)),
                        .float(softStrength),
                        .float(sewnTo),
                        .color(ground),
                        .color(PatchMaterial.transferPen),
                        .image(layers)
                    ),
                    maxSampleOffset: CGSize(width: room, height: room)
                )
            }
            .padding(-room)
    }
}

/// An edition's blank: the bare cloth in its shape with its cord (guide page 15). A paper tag is tied through a slot in it,
/// with the bird's name when the bird's painting isn't on the phone, or "Being sewn" while it's on its way. Never an error
/// patch.
struct PatchBlank: View {
    @Environment(\.colorScheme) private var colorScheme
    let edition: PatchEdition
    var tag: String? = nil
    var beingSewn = false

    private var words: String? { beingSewn ? "Being sewn" : tag }

    var body: some View {
        GeometryReader { proxy in
            let cord = max(proxy.size.width * 0.035, 3)
            PatchOutline(shape: edition.shape)
                .fill(edition.twill)
                .overlay {
                    PatchCloth(isCanvas: edition.isCanvas)
                        .clipShape(PatchOutline(shape: edition.shape))
                }
                .overlay {
                    PatchOutline(shape: edition.shape)
                        .stroke(edition.cord, lineWidth: cord)
                }
                .shadow(color: .black.opacity(Double(PatchMaterial.softShadow(colorScheme))), radius: 5, x: 3, y: 5)
                .overlay {
                    if let words {
                        TiedTag(text: words, size: proxy.size)
                    }
                }
        }
    }
}

/// The blank's cloth: a twill's diagonal rib, or Uncharted's plain canvas weave. Printed under the cord, quiet enough that it
/// reads as cloth and nothing else.
private struct PatchCloth: View {
    let isCanvas: Bool

    var body: some View {
        Canvas { context, size in
            var lines = Path()
            if isCanvas {
                for x in stride(from: 0, through: size.width, by: 2.5) {
                    lines.move(to: CGPoint(x: x, y: 0))
                    lines.addLine(to: CGPoint(x: x, y: size.height))
                }
                for y in stride(from: 0, through: size.height, by: 2.5) {
                    lines.move(to: CGPoint(x: 0, y: y))
                    lines.addLine(to: CGPoint(x: size.width, y: y))
                }
            } else {
                for x in stride(from: -size.height, through: size.width, by: 3) {
                    lines.move(to: CGPoint(x: x, y: size.height))
                    lines.addLine(to: CGPoint(x: x + size.height, y: 0))
                }
            }
            context.stroke(lines, with: .color(.black.opacity(isCanvas ? 0.07 : 0.09)), lineWidth: 0.75)
        }
    }
}

/// A small paper tag in live type, tied on through a slot near the top of the blank: never stitched. The same words are in
/// type beside the patch wherever one shows, and those grow with Dynamic Type, so the tag stops growing before it outgrows
/// the patch.
private struct TiedTag: View {
    let text: String
    let size: CGSize

    private var isSmall: Bool { size.width < 200 }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.black.opacity(0.5))
                .frame(width: max(size.width * 0.12, 10), height: max(size.height * 0.022, 3))
            Rectangle()
                .fill(Color.cardEdge)
                .frame(width: 1, height: size.height * 0.1)
            Text(text)
                .font(isSmall ? .system(.caption2, design: .serif, weight: .semibold) : CardFont.tileStoryTitle)
                .dynamicTypeSize(...(isSmall ? DynamicTypeSize.large : .xxLarge))
                .foregroundStyle(Color.cardInk)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, isSmall ? 6 : 12)
                .padding(.vertical, isSmall ? 3 : 6)
                .background(Color.cardStock, in: RoundedRectangle(cornerRadius: 3))
                .shadow(color: .black.opacity(0.3), radius: 2, x: 1, y: 2)
        }
        .padding(.top, size.height * 0.1)
        .padding(.horizontal, size.width * 0.1)
        .frame(width: size.width, height: size.height, alignment: .top)
    }
}

/// Reduce Motion, with the debug flag the UI tests turn it on with (the simulator's own setting can't be set per run).
enum PatchMotion {
    static func reduces(system: Bool) -> Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "reduceMotion") { return true }
        #endif
        return system
    }

    /// VoiceOver, with the same kind of flag for its path through the ceremony (issue #135).
    static func voiceOver(system: Bool) -> Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "voiceOverPath") { return true }
        #endif
        return system
    }
}

extension View {
    /// Holds the phone's light on while this surface is on screen: the lit surface's half of `PatchLight`.
    func holdsPatchLight() -> some View {
        onAppear { PatchLight.shared.hold() }
            .onDisappear { PatchLight.shared.release() }
    }
}
