import SwiftUI

/// A Guild's look (issue #118, design guide page 13): a simple nature-derived emblem, chosen from the circle's ID so every
/// member sees the same one and nothing new is stored or sent. Emblems are identity, not ranks or purchases: one mark on a
/// calm disc in aqua or a muted local colour, never gold (there is none since #132).
struct GuildIdentity: Equatable {
    /// One emblem tone: the deep disc and the light mark on it, the same in both appearances.
    struct Tone: Equatable {
        let name: String
        let disc: UInt32
        let mark: UInt32
    }

    /// The marks: leaves, feathers, water, hills and sky. All SF Symbols.
    static let marks = ["leaf.fill", "bird.fill", "tree.fill", "water.waves", "mountain.2.fill", "sun.horizon.fill", "camera.macro", "wind", "moon.stars.fill", "drop.fill"]

    /// Aqua and the muted local colours. No gold or ochre, and no lavender, which belongs to shared goals.
    static let tones = [
        Tone(name: "aqua", disc: 0x1F4B4C, mark: 0xBCE3D9),
        Tone(name: "slate", disc: 0x2B3F5C, mark: 0xC9D6EA),
        Tone(name: "sage", disc: 0x34503C, mark: 0xCFE0C6),
        Tone(name: "clay", disc: 0x5A3D33, mark: 0xEBD3C7),
        Tone(name: "reed", disc: 0x45502E, mark: 0xDDE3C2),
        Tone(name: "mist", disc: 0x2E4A55, mark: 0xD2E4EA),
    ]

    let mark: String
    let tone: Tone

    init(circleID: String) {
        let seed = SeededRandom.seed(circleID)
        mark = Self.marks[Int(seed % UInt64(Self.marks.count))]
        tone = Self.tones[Int((seed >> 8) % UInt64(Self.tones.count))]
    }
}

private extension Color {
    init(guildHex hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// The emblem: the mark on its disc with a fine ring. Decorative; the Guild's name says who it is.
struct GuildEmblem: View {
    let identity: GuildIdentity
    var size: CGFloat = 56

    var body: some View {
        ZStack {
            Circle().fill(Color(guildHex: identity.tone.disc))
            Circle()
                .strokeBorder(Color(guildHex: identity.tone.mark).opacity(0.55), lineWidth: max(1, size / 40))
                .padding(size * 0.07)
            Image(systemName: identity.mark)
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color(guildHex: identity.tone.mark))
                .padding(size * 0.27)
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(Color.paper, lineWidth: max(2, size / 22)))
        .accessibilityHidden(true)
    }
}

/// The one avatar (issue #150): a person's initials on a disc in their own tone, with a fine ring in the page colour. Initials
/// only (spec v2, "Accounts and the app client"). Decorative and fixed in size, so the initials don't grow with Dynamic Type
/// and VoiceOver skips it: say who it is in words next to it.
struct MemberFace: View {
    /// The initials' colour, on every tone.
    nonisolated static let ink: UInt32 = 0x10292D
    /// Muted, never gold: each member keeps one tone by their ID.
    nonisolated static let tones: [UInt32] = [0x8E9BC4, 0x9AAE7E, 0x6F9FB0, 0xA98390, 0x8FB3A5, 0xB79A7C]

    let id: String
    let initials: String
    var size: CGFloat = 30

    init(id: String, initials: String, size: CGFloat = 30) {
        self.id = id
        self.initials = initials
        self.size = size
    }

    init(member: CircleMember, size: CGFloat = 30) {
        self.init(id: member.id, initials: member.initials, size: size)
    }

    var body: some View {
        MemberDisc(text: initials.isEmpty ? "·" : initials, ink: Color(guildHex: Self.ink), fill: Color(guildHex: Self.tones[Int(SeededRandom.seed(id) % UInt64(Self.tones.count))]), size: size)
    }
}

/// Words on a member's disc, at a size that follows the disc.
private struct MemberDisc: View {
    let text: String
    let ink: Color
    let fill: Color
    let size: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: size * 0.37, weight: .semibold))
            .foregroundStyle(ink)
            .minimumScaleFactor(0.7)
            .frame(width: size, height: size)
            .background(fill, in: .circle)
            .overlay(Circle().strokeBorder(Color.paper, lineWidth: 2))
            .accessibilityHidden(true)
    }
}

/// Member presence: the first few members' faces, overlapping, and "+N" for the rest.
struct MemberFaces: View {
    let members: [CircleMember]
    var total: Int? = nil
    var shown = 4
    var size: CGFloat = 30

    var body: some View {
        let more = max(0, (total ?? members.count) - min(shown, members.count))
        HStack(spacing: -size * 0.25) {
            ForEach(members.prefix(shown)) { MemberFace(member: $0, size: size) }
            if more > 0 {
                MemberDisc(text: "+\(more)", ink: Color.ink, fill: Color.raised, size: size)
            }
        }
        .accessibilityHidden(true)
    }
}
