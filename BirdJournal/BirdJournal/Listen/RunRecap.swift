import Album
import SwiftUI
import UIKit

/// What a run's recap says (issue #150): the date, the place the share may carry, the time listened, the birds heard and the
/// patches sewn. All of it decided here, so the rules are tested without drawing. There's no new kind of find: this goes out
/// through the system share and nowhere else.
struct RunRecap: Equatable {
    /// "November 6, 2026".
    var dateText: String
    /// Only what `SharePolicy.recapPlace` allows.
    var place: String?
    /// "42 min".
    var listenedText: String
    /// "42 minutes".
    var listenedSpoken: String
    var birdsHeard: Int
    /// The patches this run sewed, by bird.
    var patchNames: [String]

    /// One patch as the recap shows it: already flat, since it goes into an image.
    struct Picture: Identifiable {
        let id: CardCollection.Patch.Key
        let image: UIImage
    }

    init(startedAt: Date?, endedAt: Date, place: String?, birdsHeard: Int, patchNames: [String], calendar: Calendar = .current, locale: Locale = .current) {
        let start = startedAt ?? endedAt
        var style = Date.FormatStyle(locale: locale, calendar: calendar).month(.wide).day().year()
        style.timeZone = calendar.timeZone
        dateText = start.formatted(style)
        self.place = place
        let seconds = max(Int(endedAt.timeIntervalSince(start)), 0)
        (listenedText, listenedSpoken) = Self.listened(seconds: seconds)
        self.birdsHeard = birdsHeard
        self.patchNames = patchNames
    }

    /// Rounded to the minute, with under a minute said as such.
    private static func listened(seconds: Int) -> (String, String) {
        if seconds < 60 { return ("<1 min", "under a minute") }
        let minutes = (seconds + 30) / 60
        let (hours, left) = (minutes / 60, minutes % 60)
        let spokenMinutes = "\(left) \(left == 1 ? "minute" : "minutes")"
        if hours == 0 { return ("\(left) min", spokenMinutes) }
        let spokenHours = "\(hours) \(hours == 1 ? "hour" : "hours")"
        return left == 0 ? ("\(hours) hr", spokenHours) : ("\(hours) hr \(left) min", "\(spokenHours) \(spokenMinutes)")
    }

    /// What heads the card: the place, "A secret spot" as a title has it, or the date with no place to give.
    var title: String {
        guard let place else { return dateText }
        return place.prefix(1).uppercased() + place.dropFirst()
    }

    var patchesSewn: Int { patchNames.count }
    /// "bird heard", "birds heard".
    var birdsLabel: String { birdsHeard == 1 ? "bird heard" : "birds heard" }
    /// "patch sewn", "patches sewn".
    var patchesLabel: String { patchesSewn == 1 ? "patch sewn" : "patches sewn" }

    private var dateAndPlace: String {
        [dateText, place].compactMap { $0 }.joined(separator: ", ")
    }

    /// What VoiceOver reads for the whole card.
    var spokenText: String {
        let sewn = patchNames.isEmpty ? "\(patchesSewn) \(patchesLabel)" : "\(patchesSewn) \(patchesLabel): \(patchNames.formatted(.list(type: .and)))"
        return [dateAndPlace, "Listened for \(listenedSpoken)", "\(birdsHeard) \(birdsLabel)", sewn].joined(separator: ". ") + "."
    }

    /// The words under the card, the same way the share sheet says them.
    func placeExplanation(hasLocation: Bool, includeCity: Bool) -> String {
        if !hasLocation { return "No location was recorded on this run." }
        if !includeCity { return "No place goes with it." }
        if place == FindPolicy.secretSpot { return "A sensitive bird is on this, so it says \"a secret spot\" instead of a city." }
        if place == nil { return "No city is known for this run, so no place goes with it." }
        return "Only the city goes with it, never the exact spot."
    }

    /// The text that goes with the image: the run in a line, the app's credits, and the patches' photo credits.
    func shareText(credits: [String]) -> String {
        var lines = ["\(dateAndPlace). Listened for \(listenedSpoken), \(birdsHeard) \(birdsLabel), \(patchesSewn) \(patchesLabel)."]
        lines.append(SharePolicy.appCredit)
        if !credits.isEmpty { lines.append("Patches: AI illustrations from reference photos (\(credits.joined(separator: "; ")))") }
        return lines.joined(separator: "\n")
    }

    /// "AI illustration, Featherguild", the wordmark small: a blank isn't an illustration.
    static func imprint(hasPainting: Bool) -> String {
        hasPainting ? "AI illustration, Featherguild" : "Featherguild"
    }

    /// The photo credits as the image prints them; nil when nothing needs crediting.
    static func creditLine(_ credits: [String]) -> String? {
        credits.isEmpty ? nil : "Patches from reference photos: \(credits.joined(separator: "; "))."
    }
}

/// The recap, printed on card stock (issue #150, "if you read it, it's printed on paper"): the place as the title in New York
/// with the date beside it, as a plate's caption has it, the three figures, and the patches the run sewed.
struct RunRecapCard: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let recap: RunRecap
    let pictures: [RunRecap.Picture]
    /// What only the image carries, under its figures.
    var imprint: String? = nil
    var credits: String? = nil

    /// One patch or a few get the room; a big morning's fit five across.
    private var perRow: Int {
        switch pictures.count {
        case ...3: 3
        case 4: 4
        default: 5
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading
            Rectangle()
                .fill(Color.cardEdge.opacity(0.6))
                .frame(height: 0.75)
            figures
            if !pictures.isEmpty { patches }
            if let imprint {
                VStack(alignment: .leading, spacing: 2) {
                    Text(imprint)
                        .font(CardFont.credit)
                    if let credits {
                        Text(credits)
                            // Fixed: this is a picture at a fixed type size, as on the patch's share image.
                            .font(.system(size: 8))
                    }
                }
                .foregroundStyle(Color.cardInkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CardStockSurface(isPunched: false))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(recap.spokenText)
        .accessibilityIdentifier("run-recap")
    }

    @ViewBuilder private var heading: some View {
        let title = Text(recap.title)
            .font(JournalFont.title)
            .foregroundStyle(Color.cardInk)
            .fixedSize(horizontal: false, vertical: true)
        if recap.place == nil {
            title
        } else {
            let date = Text(recap.dateText)
                .font(JournalFont.supporting)
                .foregroundStyle(Color.cardInkSecondary)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    title.lineLimit(1)
                    Spacer(minLength: 0)
                    date.lineLimit(1)
                }
                VStack(alignment: .leading, spacing: 4) {
                    title
                    date.fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private var figures: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 10) { figureCells }
        } else {
            HStack(alignment: .top, spacing: 12) { figureCells }
        }
    }

    @ViewBuilder private var figureCells: some View {
        RecapFigure(value: recap.listenedText, label: "listened")
        RecapFigure(value: "\(recap.birdsHeard)", label: recap.birdsLabel)
        RecapFigure(value: "\(recap.patchesSewn)", label: recap.patchesLabel)
    }

    /// The patches in equal cells, so one patch is the size of ten. An image can't lazily draw, and neither can this.
    private var patches: some View {
        let perRow = perRow
        return VStack(spacing: 2) {
            ForEach(Array(stride(from: 0, to: pictures.count, by: perRow)), id: \.self) { start in
                HStack(spacing: 2) {
                    ForEach(start..<(start + perRow), id: \.self) { index in
                        if index < pictures.count {
                            Image(uiImage: pictures[index].image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity)
                        } else {
                            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                        }
                    }
                }
            }
        }
        // The pictures' room for their shadows, so the first patch's edge lines up with the type above it.
        .padding(.horizontal, -10)
        .allowsHitTesting(false)
    }
}

private struct RecapFigure: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.title2, design: .serif))
                .monospacedDigit()
                .foregroundStyle(Color.cardInk)
                .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(JournalFont.attribution)
                .foregroundStyle(Color.cardInkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The recap as an image: a composed object, never a screenshot (as `PatchShareImage`). The card on undyed linen at a fixed
/// type size and appearance. `CardExport` renders it.
struct RunRecapShareImage: View {
    let recap: RunRecap
    let pictures: [RunRecap.Picture]
    let imprint: String
    let credits: String?

    var body: some View {
        RunRecapCard(recap: recap, pictures: pictures, imprint: imprint, credits: credits)
            .padding(.horizontal, 24)
            .padding(.vertical, 34)
            .frame(width: 360)
            .background {
                Image("MaterialLinen")
                    .resizable(resizingMode: .tile)
            }
            .environment(\.colorScheme, .light)
            .environment(\.dynamicTypeSize, .large)
    }
}
