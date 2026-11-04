import Foundation

/// The one compatibility seam for the find's old name (issue #136). The app's own model says `newPatch` everywhere; this
/// is all that still knows `legendary`. **Delete this file and its callers after the backend deploy**:
/// `grep -rn LegacyFindWire BirdJournal` lists them.
///
/// Why it's needed: the server deployed before #136 refuses any unknown field (`extra="forbid"`), so a find carrying
/// `new_patch` or `edition` comes back 422, which the outbox would take as final and drop. It also only ever sends
/// `legendary`. So until the deploy the phone offers the new form first and falls back to the old one, and reads either.
enum LegacyFindWire {
    enum Keys: String, CodingKey {
        case newPatch = "new_patch"
        case legendary
        /// `FindOutbox.Published`'s name for the flag in a `FindOutbox.json` from before #136.
        case isLegendary
        /// The outbox's own key for the flag now.
        case newPatchInOutbox = "newPatch"
    }

    private static let writesOldForm = CodingUserInfoKey(rawValue: "LegacyFindWire.writesOldForm")!

    /// An encoder that makes a find write what the deployed server takes: `legendary`, with no `new_patch` or `edition`.
    static func oldFormEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.userInfo[writesOldForm] = true
        return encoder
    }

    static func writesOldForm(_ encoder: Encoder) -> Bool {
        encoder.userInfo[writesOldForm] as? Bool == true
    }

    /// The flag from the server, under whichever name it used.
    static func newPatch(from decoder: Decoder) throws -> Bool {
        let values = try decoder.container(keyedBy: Keys.self)
        return try values.decodeIfPresent(Bool.self, forKey: .newPatch) ?? values.decodeIfPresent(Bool.self, forKey: .legendary) ?? false
    }

    /// The flag from a persisted outbox, under whichever name it was saved.
    static func newPatchInOutbox(from decoder: Decoder) throws -> Bool {
        let values = try decoder.container(keyedBy: Keys.self)
        return try values.decodeIfPresent(Bool.self, forKey: .newPatchInOutbox) ?? values.decodeIfPresent(Bool.self, forKey: .isLegendary) ?? false
    }

    /// Whether a `FindOutbox.json` still has the old name, so loading it should save it again under the new one.
    static func outboxNeedsRewrite(_ data: Data) -> Bool {
        data.range(of: Data(Keys.isLegendary.rawValue.utf8)) != nil
    }

    /// The edition of a find from a server that doesn't send one: the deployed server stores no edition, but the find's
    /// pack-art key names the pack, `packs/us-ca-la/…`.
    static func edition(ofArtKey key: String?) -> String? {
        let parts = key?.split(separator: "/") ?? []
        guard parts.count >= 3, parts[0] == "packs" else { return nil }
        return String(parts[1])
    }
}
