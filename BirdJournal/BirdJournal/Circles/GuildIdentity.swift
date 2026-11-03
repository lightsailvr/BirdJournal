import SwiftUI

/// A Guild's look (issue #118, design guide page 13): a simple nature-derived emblem and a habitat cover, both chosen
/// from the circle's ID so every member sees the same ones and nothing new is stored or sent. Emblems are identity, not
/// ranks or purchases: one mark on a calm disc in aqua or a muted local colour, never gold (gold has one job, the
/// personal-first Legendary). The habitat cover is a designed `LandscapeArt`, illustrative, never a place.
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

    /// Habitats a Guild may wear: the wide, quiet landscapes (the editions' own stay with their sets).
    static let habitats: [Landscape] = [.forest, .wetland, .coastal, .meadow, .hills, .fog]

    let mark: String
    let tone: Tone
    let habitat: Landscape
    let seed: UInt64

    init(circleID: String) {
        let seed = SeededRandom.seed(circleID)
        self.seed = seed
        mark = Self.marks[Int(seed % UInt64(Self.marks.count))]
        tone = Self.tones[Int((seed >> 8) % UInt64(Self.tones.count))]
        habitat = Self.habitats[Int((seed >> 16) % UInt64(Self.habitats.count))]
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

/// The habitat cover across the top of a Guild's card and page.
struct GuildCover: View {
    let identity: GuildIdentity

    var body: some View {
        LandscapeArt(landscape: identity.habitat, seed: identity.seed)
            .accessibilityHidden(true)
    }
}

/// Member presence: the first few members' initials, overlapping, and "+N" for the rest. Initials only (spec v2,
/// "Accounts and the app client").
struct MemberFaces: View {
    let members: [CircleMember]
    var total: Int? = nil
    var shown = 4
    var size: CGFloat = 30

    /// Muted, never gold: each member keeps one tone by their ID.
    private static let tones: [Color] = [
        Color(guildHex: 0x8E9BC4), Color(guildHex: 0x9AAE7E), Color(guildHex: 0x6F9FB0), Color(guildHex: 0xA98390), Color(guildHex: 0x8FB3A5), Color(guildHex: 0xB79A7C),
    ]

    var body: some View {
        let more = max(0, (total ?? members.count) - min(shown, members.count))
        HStack(spacing: -size * 0.25) {
            ForEach(members.prefix(shown)) { member in
                Text(member.initials.isEmpty ? "·" : member.initials)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color(guildHex: 0x10292D))
                    .minimumScaleFactor(0.7)
                    .frame(width: size, height: size)
                    .background(Self.tones[Int(SeededRandom.seed(member.id) % UInt64(Self.tones.count))], in: .circle)
                    .overlay(Circle().strokeBorder(Color.paper, lineWidth: 2))
            }
            if more > 0 {
                Text("+\(more)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.ink)
                    .minimumScaleFactor(0.7)
                    .frame(width: size, height: size)
                    .background(Color.raised, in: .circle)
                    .overlay(Circle().strokeBorder(Color.paper, lineWidth: 2))
            }
        }
        // Decorative and fixed in size: initials don't grow with Dynamic Type (the names are in the members list).
        .dynamicTypeSize(...DynamicTypeSize.large)
        .accessibilityHidden(true)
    }
}
