import SwiftUI

/// One patch as an object (issue #134, guide pages 9 and 13): its painting, lit by the phone's tilt with a shadow opposite
/// the light, or the same patch part way through being sewn (issue #135). Without a painting on the phone it's the edition's
/// blank (guide page 15), with a paper tag naming the bird when `tag` says so. A decoration: whoever shows it says what it is
/// to VoiceOver.
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
    /// What's already decoded shows at once: a patch scrolled back to doesn't flash its blank for a frame.
    @State private var loaded: PatchTextures.Loaded?

    /// - Parameter decoded: the pictures, for a surface that has them to hand: a stitch-in redraws this every frame, and the
    ///   cache may let go of them during it.
    init(art: PatchArt?, edition: PatchEdition, face: Face = .sewn, size: PatchTextures.Size = .thumbnail, tag: String? = nil, decoded: PatchTextures.Loaded? = nil) {
        self.art = art
        self.edition = edition
        self.face = face
        self.size = size
        self.tag = tag
        _loaded = State(initialValue: decoded ?? art.flatMap { PatchTextures.cached($0, size: size) })
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
                    PatchBlank(edition: edition, tag: art == nil ? tag : nil)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: art) {
                guard let art else {
                    loaded = nil
                    return
                }
                loaded = await PatchTextures.load(art, size: size)
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

/// An edition's blank: the bare twill in its shape with its cord (guide page 15), and the bird's name on a paper tag when
/// the bird's painting isn't on the phone. Never an error patch.
struct PatchBlank: View {
    @Environment(\.colorScheme) private var colorScheme
    let edition: PatchEdition
    var tag: String? = nil

    var body: some View {
        GeometryReader { proxy in
            let cord = max(proxy.size.width * 0.035, 3)
            PatchOutline(shape: edition.shape)
                .fill(edition.twill)
                .overlay {
                    PatchOutline(shape: edition.shape)
                        .stroke(edition.cord, lineWidth: cord)
                }
                .shadow(color: .black.opacity(Double(PatchMaterial.softShadow(colorScheme))), radius: 5, x: 3, y: 5)
                .overlay(alignment: .bottom) {
                    if let tag {
                        PaperTag(text: tag)
                            .padding(.bottom, proxy.size.height * 0.12)
                    }
                }
        }
    }
}

/// The small paper tag on a blank: the species' name in live type, never stitched.
private struct PaperTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(CardFont.tileStoryTitle)
            .foregroundStyle(Color.cardInk)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.cardStock, in: RoundedRectangle(cornerRadius: 3))
            .shadow(color: .black.opacity(0.3), radius: 2, x: 1, y: 2)
            .padding(.horizontal, 12)
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
