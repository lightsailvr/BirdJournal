import Foundation

/// How a bird's name and what was said to the glasses are compared (issue #194, of #185). A recogniser does not know bird
/// names: it drops the apostrophe ("annas"), splits and joins words ("humming bird", "bush tit"), and writes what it heard
/// as words it knows ("morning dove", "black feeby"). So both sides are reduced to their letters run together, as written
/// and as they roughly sound, and a few sounds may differ.
///
/// Pure values: `NameableBirds.spoken(_:in:limit:)` is the search over them.
nonisolated enum SpokenName {
    /// A name, a run of a name's words, or what was said: the words run together, as written and as they sound.
    struct Form: Hashable, Sendable {
        /// Lowercase letters and digits only: "annashummingbird".
        let plain: String
        /// The same by ear: "anashamangbard".
        let sound: [UInt8]

        init(words: some Sequence<String>) {
            plain = words.joined()
            sound = SpokenName.sound(of: plain)
        }
    }

    /// How close what was said is to a bird's name.
    struct Closeness: Equatable, Sendable {
        /// What of the name was matched.
        enum Reach: Int, Sendable {
            /// The whole name.
            case name
            /// A run of the name's words: "hummingbird", "night heron".
            case part
        }

        let reach: Reach
        /// Letter for letter, rather than by ear.
        let isAsWritten: Bool
        /// The sounds that differ: none as written or by ear.
        let distance: Int

        /// What was said is the name, or the run of its words, as written or by ear; otherwise it is only near it.
        var soundsTheSame: Bool { distance == 0 }

        /// The order among matches that sound the same, the smaller the closer: the whole name as written, the whole name
        /// by ear, a part as written, a part by ear.
        var rank: Int { reach.rawValue * 2 + (isAsWritten ? 0 : 1) }
    }

    /// The ways of saying one bird: each of its names whole, and every run of a name's words short of the whole.
    struct Names: Sendable {
        let whole: [Form]
        let parts: [Form]

        /// - Parameter names: the bird's common names, as the pack and as BirdNET spell it. A possessive is also taken
        ///   without its s, which is how it is often heard: "Anna's Hummingbird" is "anna hummingbird" as well.
        init(_ names: [String]) {
            var whole: [Form] = []
            var parts: [Form] = []
            var seen = Set<String>()
            let spellings = names.flatMap { name in
                [name, name.replacing("'s ", with: " ").replacing("’s ", with: " ")]
            }
            for name in spellings {
                let words = SpokenName.words(of: name)
                guard !words.isEmpty else { continue }
                let form = Form(words: words)
                if seen.insert(form.plain).inserted { whole.append(form) }
                for start in words.indices {
                    for end in start..<words.count where end - start + 1 < words.count {
                        let part = Form(words: words[start...end])
                        if seen.insert(part.plain).inserted { parts.append(part) }
                    }
                }
            }
            self.whole = whole
            self.parts = parts
        }

        /// How close `said` is to this bird at its closest, nil when it is not close: what sounds the same before what is
        /// only near, and the whole name before a part of it.
        func closeness(to said: Form) -> Closeness? {
            if whole.contains(where: { $0.plain == said.plain }) { return Closeness(reach: .name, isAsWritten: true, distance: 0) }
            let nearName = Self.nearest(said, among: whole)
            if nearName == 0 { return Closeness(reach: .name, isAsWritten: false, distance: 0) }
            if parts.contains(where: { $0.plain == said.plain }) { return Closeness(reach: .part, isAsWritten: true, distance: 0) }
            let nearPart = Self.nearest(said, among: parts)
            if nearPart == 0 { return Closeness(reach: .part, isAsWritten: false, distance: 0) }
            if let nearName { return Closeness(reach: .name, isAsWritten: false, distance: nearName) }
            if let nearPart { return Closeness(reach: .part, isAsWritten: false, distance: nearPart) }
            return nil
        }

        private static func nearest(_ said: Form, among forms: [Form]) -> Int? {
            var nearest: Int?
            for form in forms {
                let limit = SpokenName.tolerance(max(said.sound.count, form.sound.count))
                guard let distance = SpokenName.distance(said.sound, form.sound, within: limit) else { continue }
                nearest = min(nearest ?? distance, distance)
            }
            return nearest
        }
    }

    /// The words people say around a name, dropped from the front of what was said: "it's a", "I think that's an", "um".
    static let filler: Set<String> = ["a", "an", "the", "its", "it", "is", "thats", "that", "i", "saw", "see", "think", "um", "uh", "oh"]

    /// What was said, without the filler before the name; nil when nothing is left.
    static func said(_ text: String) -> Form? {
        let words = words(of: text).drop { filler.contains($0) }
        return words.isEmpty ? nil : Form(words: words)
    }

    /// The words of `text`: lowercase, without accents or apostrophes, split wherever anything but a letter or a digit
    /// stands, so "Red-tailed Hawk." is red, tailed, hawk and "Anna's" is annas.
    static func words(of text: String) -> [String] {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var words: [String] = []
        var word = ""
        for character in folded {
            if character == "'" || character == "’" || character == "‘" { continue }
            if character.isASCII, character.isLetter || character.isNumber {
                word.append(character)
            } else if !word.isEmpty {
                words.append(word)
                word = ""
            }
        }
        if !word.isEmpty { words.append(word) }
        return words
    }

    /// How many sounds may differ between two forms, the longer of them `length` sounds long: none in a short word (a wren
    /// is no rail), one from four sounds, two from eight, three from twelve.
    static func tolerance(_ length: Int) -> Int {
        length < 4 ? 0 : min(3, 1 + (length - 4) / 4)
    }

    /// `plain` by ear, roughly, as English spells: letters that sound alike are one letter (ph and f, c and k or s, ch and
    /// sh, z and s), silent ones go (wr, kn, wh, gh), a doubled letter is one, and every run of vowels is one sound, since
    /// the vowels are what a recogniser gets wrong ("feeby", "tohee", "morning"). Not a phonetic alphabet: only enough
    /// that a name misspelt by ear lands on, or within a sound or two of, the name.
    static func sound(of plain: String) -> [UInt8] {
        let letters = Array(plain.utf8)
        var sound: [UInt8] = []
        sound.reserveCapacity(letters.count)
        func emit(_ letter: Character) {
            let byte = letter.asciiValue ?? 0
            if sound.last != byte { sound.append(byte) }
        }
        func letter(_ index: Int) -> Character {
            index < letters.count ? Character(UnicodeScalar(letters[index])) : " "
        }
        var index = 0
        while index < letters.count {
            let current = letter(index)
            let next = letter(index + 1)
            switch (current, next) {
            // Two or three letters with one sound, or with one of them silent. "X" stands for ch, sh and tch.
            case ("t", "c") where letter(index + 2) == "h":
                emit("X")
                index += 3
            case ("c", "h"), ("s", "h"):
                emit("X")
                index += 2
            case ("p", "h"):
                emit("f")
                index += 2
            case ("w", "r"):
                emit("r")
                index += 2
            case ("k", "n"):
                emit("n")
                index += 2
            case ("w", "h"):
                emit("w")
                index += 2
            case ("g", "h"):
                index += 2
            case ("c", "k"):
                emit("k")
                index += 2
            // Every run of vowels is one sound.
            case ("a", _), ("e", _), ("i", _), ("o", _), ("u", _), ("y", _):
                emit("a")
                index += 1
            case ("c", "e"), ("c", "i"), ("c", "y"):
                emit("s")
                index += 1
            case ("c", _), ("q", _):
                emit("k")
                index += 1
            case ("z", _):
                emit("s")
                index += 1
            case ("x", _):
                emit("k")
                emit("s")
                index += 1
            default:
                emit(current)
                index += 1
            }
        }
        return sound
    }

    /// The edit distance between two forms' sounds (a sound added, dropped or changed counts one), nil when it is more
    /// than `limit`.
    static func distance(_ lhs: [UInt8], _ rhs: [UInt8], within limit: Int) -> Int? {
        guard abs(lhs.count - rhs.count) <= limit else { return nil }
        if lhs == rhs { return 0 }
        guard limit > 0 else { return nil }
        var previous = Array(0...rhs.count)
        var current = [Int](repeating: 0, count: rhs.count + 1)
        for (row, left) in lhs.enumerated() {
            current[0] = row + 1
            var best = current[0]
            for (column, right) in rhs.enumerated() {
                let cost = min(previous[column] + (left == right ? 0 : 1), previous[column + 1] + 1, current[column] + 1)
                current[column + 1] = cost
                best = min(best, cost)
            }
            // Every way on from this row costs at least its smallest entry.
            guard best <= limit else { return nil }
            swap(&previous, &current)
        }
        return previous[rhs.count] <= limit ? previous[rhs.count] : nil
    }
}
