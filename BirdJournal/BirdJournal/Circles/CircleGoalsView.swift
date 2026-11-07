import Album
import Pack
import SwiftUI

/// The goal card on a Guild's page (issue #65): this month's goal, sized from the circle's last month, with its
/// progress in distinct species, then the Guild's custom goals (running, coming and just ended), and **New goal**.
/// A custom goal's creator or the Guild's creator swipes it away.
struct CircleGoalsSection: View {
    @Environment(CircleStore.self) private var circles
    let circleID: String
    let timeZone: String
    @State private var creating = false
    @State private var deleting: CircleGoal?
    @State private var error: String?

    private var goals: [CircleGoal]? { circles.goals[circleID] }

    var body: some View {
        Section {
            if let goals {
                ForEach(goals) { goal in
                    if goal.kind == .monthly {
                        MonthlyGoalCard(goal: goal, circleID: circleID)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                    } else {
                        CustomGoalRow(goal: goal, circleID: circleID, timeZone: timeZone)
                            .swipeActions {
                                if goal.canDelete { Button("Delete", role: .destructive) { deleting = goal } }
                            }
                            .contextMenu {
                                if goal.canDelete {
                                    Button("Delete goal", systemImage: "trash", role: .destructive) { deleting = goal }
                                }
                            }
                    }
                }
                Button {
                    creating = true
                } label: {
                    Label("New goal", systemImage: "flag.checkered")
                }
                .accessibilityIdentifier("newGoal")
                // On the button, not the section: a List's sections don't reliably present.
                .sheet(isPresented: $creating) { NewGoalSheet(circleID: circleID, timeZone: timeZone) }
                .confirmationDialog(
                    "Delete “\(deleting?.title ?? "this goal")”?",
                    isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                    titleVisibility: .visible,
                    presenting: deleting
                ) { goal in
                    Button("Delete goal", role: .destructive) { delete(goal) }
                } message: { _ in
                    Text("It goes for everyone in the Guild. The finds stay.")
                }
                #if DEBUG
                .task {
                    if UserDefaults.standard.bool(forKey: "autoNewGoal") {
                        UserDefaults.standard.removeObject(forKey: "autoNewGoal")
                        creating = true
                    }
                }
                #endif
                if let error {
                    InlineError(error, afterAction: true)
                }
            } else {
                GuildPlaceholder(rows: 1)
            }
        } header: {
            Text("Goals")
        } footer: {
            if goals?.contains(where: { $0.kind == .custom }) == true {
                Text("Goals count different species, not repeat sightings, among everyone's finds.")
            }
        }
    }

    private func delete(_ goal: CircleGoal) {
        Task {
            do {
                try await circles.deleteGoal(id: goal.id, circleID: circleID)
                error = nil
            } catch {
                self.error = CircleStore.message(for: error, doing: "delete the goal")
            }
        }
    }
}

/// This month's goal at the head of a Guild's page, on the felt (issue #150, G2, G6): the calm headline from the target, how far it's
/// got, and lavender thread, with this month's patches under it, or thread alone from a server too old to name them. VoiceOver hears
/// the whole sentence once, then each patch. No countdown and no leaderboard.
struct CompactGoal: View {
    let goal: CircleGoal
    let circleID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        headline
                        Spacer(minLength: 8)
                        count
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        headline
                        count
                    }
                }
                ThreadProgress(goal: goal, circleID: circleID)
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(GoalWords.spokenCompact(goal))
            .accessibilityIdentifier("goal-monthly")
            GoalPatchRow(goal: goal, circleID: circleID)
        }
    }

    private var headline: some View {
        Text(GoalWords.headline(goal))
            .font(JournalFont.heading)
            .foregroundStyle(Color.ink)
            .fixedSize(horizontal: false, vertical: true)
            .boardLabel()
    }

    private var count: some View {
        HStack(spacing: 4) {
            if goal.isReached { Image(systemName: "checkmark.circle") }
            Text(GoalWords.tally(goal))
                .monospacedDigit()
        }
        .font(JournalFont.supporting)
        .foregroundStyle(Color.ink)
        .fixedSize()
        .boardLabel()
    }
}

/// What a goal's row of patches holds: newest first, since the server counts earliest first and a new bird should show, then "+N" in
/// the last place for everything else. N makes the row add up to the goal's count, even if the list and the count disagree.
struct GoalPatchSlots: Equatable {
    var shown: [CircleGoal.Species]
    var more: Int

    init(goal: CircleGoal, places: Int) {
        var seen = Set<String>()
        let species = (goal.species ?? []).reversed().filter { seen.insert($0.scientificName).inserted }
        let total = max(species.count, goal.progress)
        guard !species.isEmpty, places > 0 else {
            shown = []
            more = 0
            return
        }
        // Everything fits only if all of it is in the list; one place goes to "+N" otherwise.
        let room = total <= places && species.count == total ? places : places - 1
        shown = Array(species.prefix(room))
        more = total - shown.count
    }
}

/// This period's patches under a goal's thread (issue #150, G6): small, in a row, a blank where this phone has no painting, with "+N"
/// past what fits. A patch opens the bird in the Atlas, and "+N" the whole board, since a goal's patches belong to nobody to open.
private struct GoalPatchRow: View {
    @Environment(PackLibrary.self) private var library
    @ScaledMetric(relativeTo: .body) private var scaledSide: CGFloat = GoalPatchRow.side
    let goal: CircleGoal
    let circleID: String

    /// The reference's seven small patches across the page: 34 px at 1.34.
    private static let side: CGFloat = 45
    private static let gap: CGFloat = 6

    private var side: CGFloat { min(scaledSide, 72) }

    var body: some View {
        if goal.species?.isEmpty == false {
            let names = library.birdNames
            GeometryReader { proxy in
                let places = max(1, Int((proxy.size.width + Self.gap) / (side + Self.gap)))
                let slots = GoalPatchSlots(goal: goal, places: places)
                let gap = places > 1 ? (proxy.size.width - CGFloat(places) * side) / CGFloat(places - 1) : 0
                HStack(spacing: gap) {
                    ForEach(slots.shown, id: \.scientificName) { species in
                        patch(species, name: names[species.scientificName])
                    }
                    if slots.more > 0 { more(slots.more) }
                }
            }
            .frame(height: side)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(goal.title) patches")
            .accessibilityIdentifier("goal-patches")
        }
    }

    @ViewBuilder
    private func patch(_ species: CircleGoal.Species, name: String?) -> some View {
        // Too small to read a tag, as on a row: VoiceOver says its name, and so does the page it opens.
        let picture = RowPatch(scientificName: species.scientificName, setID: species.edition)
            .frame(width: side, height: side)
            .contentShape(.rect)
        let spoken = GoalWords.spokenPatch(name: name, edition: library.editionLabel(setID: species.edition))
        if let name {
            NavigationLink(value: Route.species(scientificName: species.scientificName, commonName: name)) { picture }
                .buttonStyle(.patchLift)
                .accessibilityLabel(spoken)
                .accessibilityHint("Opens this bird in the Atlas.")
                .accessibilityIdentifier("goal-patch-\(species.scientificName)")
        } else {
            picture
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken)
                .accessibilityIdentifier("goal-patch-\(species.scientificName)")
        }
    }

    private func more(_ count: Int) -> some View {
        NavigationLink(value: Route.goalPatches(circleID: circleID, goalID: goal.id)) {
            Text("+\(count)")
                .font(JournalFont.supporting.weight(.semibold))
                .monospacedDigit()
                .minimumScaleFactor(0.7)
                .lineLimit(1)
                .foregroundStyle(Color.ink)
                .frame(width: side, height: side)
                .background(Color.raised, in: .circle)
                .overlay(Circle().strokeBorder(Color.ink.opacity(0.35), lineWidth: 1))
                .contentShape(.circle)
        }
        .buttonStyle(.patchLift)
        .accessibilityLabel("\(count) more")
        .accessibilityHint("Shows every patch of this goal.")
        .accessibilityIdentifier("goal-patches-more")
    }
}

/// Every patch of a goal so far, as a board on felt, for what "+N" stands for. Newest first, with no finder: a goal names nobody.
struct GoalPatchesView: View {
    @Environment(CircleStore.self) private var circles
    @Environment(PackLibrary.self) private var library
    let circleID: String
    let goalID: String

    private var goal: CircleGoal? { circles.goals[circleID]?.first { $0.id == goalID } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let goal {
                    SectionTitle(GoalWords.headline(goal), size: .lead, top: 8, onBoard: true)
                    Text(GoalWords.tally(goal))
                        .font(JournalFont.supporting)
                        .foregroundStyle(Color.ink)
                        .boardLabel()
                        .padding(.top, 2)
                    BoardTiles(tiles: tiles(of: goal), side: 79)
                        .padding(.top, 14)
                } else {
                    // Deleted from under the page, or its month ended and a read took it.
                    StateNotice("This goal isn't here any more", message: "It may have been deleted, or its days may be over.", mark: .symbol("flag.checkered"), messageInk: .ink)
                        .boardLabel()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                        .accessibilityIdentifier("goal-patches-gone")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, JournalLayout.margin)
            .padding(.bottom, JournalLayout.sectionGap)
        }
        .patchSheetBackground()
        .holdsPatchLight()
        .navigationTitle(goal?.title ?? "Goal")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func tiles(of goal: CircleGoal) -> [BoardTile] {
        let names = library.birdNames
        return GoalPatchSlots(goal: goal, places: .max).shown.map { species in
            let name = names[species.scientificName]
            return BoardTile(
                id: species.scientificName, scientificName: species.scientificName, setID: species.edition, name: name ?? BirdNames.unnamed,
                caption: nil,
                spoken: GoalWords.spokenPatch(name: name, edition: library.editionLabel(setID: species.edition)),
                hint: name == nil ? nil : "Opens this bird in the Atlas.",
                route: name.map { .species(scientificName: species.scientificName, commonName: $0) },
                identifier: "goal-patch-\(species.scientificName)"
            )
        }
    }
}

/// This month's goal, in the lavender of shared goals (design guide pages 3 and 13): the month, a calm headline from
/// the target ("Fourteen birds, together."), a bar, "9 of 14 species" and "5 still to discover", or that it's reached.
/// No countdown and no leaderboard, and no gold.
struct MonthlyGoalCard: View {
    let goal: CircleGoal
    let circleID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(goal.title)
                    .font(JournalFont.supporting.weight(.semibold))
                Spacer()
                if goal.isReached {
                    Label("Reached", systemImage: "checkmark.circle")
                        .font(.subheadline.weight(.semibold))
                }
            }
            Text(GoalWords.headline(goal))
                .font(JournalFont.section)
            ThreadProgress(goal: goal, circleID: circleID, thread: .onLavender)
                .accessibilityHidden(true)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    Text(GoalWords.count(goal)).font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Text(GoalWords.monthlyNote(goal)).font(JournalFont.supporting)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(GoalWords.count(goal)).font(.subheadline.weight(.semibold))
                    Text(GoalWords.monthlyNote(goal)).font(JournalFont.supporting)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(Color.onSharedGoal)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.sharedGoal, in: RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("goal-monthly")
    }
}

/// A custom goal: its title, its days, who made it, the count and a bar.
struct CustomGoalRow: View {
    let goal: CircleGoal
    let circleID: String
    let timeZone: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(goal.title).font(JournalFont.rowTitle)
                Spacer()
                if goal.isReached {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Reached")
                }
                Text(GoalWords.count(goal, short: true))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color.ink)
            }
            ThreadProgress(goal: goal, circleID: circleID)
                .accessibilityHidden(true)
            Text(GoalWords.customNote(goal, timeZone: timeZone))
                .font(JournalFont.supporting)
                .foregroundStyle(Color.inkSecondary)
        }
        .padding(.vertical, 4)
        .opacity(goal.status == .ended && !goal.isReached ? 0.7 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("goal-\(goal.id)")
    }
}

/// What the goal card says, apart from the views so the tests read it. Goals count distinct species (the server's
/// `progress`), never repeat cards.
enum GoalWords {
    /// What the thread reads when nothing beside it says the count: "9 of 14 species so far".
    static func sentence(_ goal: CircleGoal) -> String {
        "\(count(goal)) so far"
    }

    static func fraction(_ goal: CircleGoal) -> Double {
        guard goal.target > 0 else { return 0 }
        return min(1, Double(goal.progress) / Double(goal.target))
    }

    /// "9 of 14 species", or "9/14" in a row.
    static func count(_ goal: CircleGoal, short: Bool = false) -> String {
        short ? "\(goal.progress)/\(goal.target)" : "\(goal.progress) of \(goal.target) species"
    }

    /// "12 of 14", beside a headline that says what's being counted.
    static func tally(_ goal: CircleGoal) -> String {
        "\(goal.progress) of \(goal.target)"
    }

    /// "November goal. Fourteen birds, together. 9 of 14 species. 5 still to discover."
    static func spokenCompact(_ goal: CircleGoal) -> String {
        [goal.title, headline(goal), "\(count(goal)).", "\(monthlyNote(goal))"].map { $0.hasSuffix(".") ? $0 : "\($0)." }.joined(separator: " ")
    }

    /// "Black Phoebe, Citrus edition patch"; "Black Phoebe, patch".
    static func spokenPatch(name: String?, edition: String?) -> String {
        "\(name ?? BirdNames.unnamed), \(edition.map { "\($0) patch" } ?? "patch")"
    }

    /// The goal on Listen, after the Guild's name: "is 2 birds from its November goal".
    static func stillToGo(_ goal: CircleGoal) -> String {
        let left = max(0, goal.target - goal.progress)
        return "is \(left) \(left == 1 ? "bird" : "birds") from its \(goal.title)"
    }

    /// "Fourteen birds, together.": the target spelled out (in figures past a hundred), the guide's calm headline.
    static func headline(_ goal: CircleGoal, locale: Locale = Locale(identifier: "en")) -> String {
        guard goal.target <= 100 else { return "\(goal.target) birds, together." }
        let words = spelled(goal.target, locale: locale)
        return "\(words.capitalizedFirst) \(goal.target == 1 ? "bird" : "birds"), together."
    }

    private static func spelled(_ number: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = locale
        return formatter.string(from: number as NSNumber) ?? "\(number)"
    }

    /// "5 still to discover", or "Reached! …" once the target is met.
    static func monthlyNote(_ goal: CircleGoal) -> String {
        if goal.isReached { return "Reached! Every new bird this month is a bonus." }
        return stillToDiscover(goal)
    }

    /// "7 still to discover".
    static func stillToDiscover(_ goal: CircleGoal) -> String {
        "\(max(0, goal.target - goal.progress)) still to discover"
    }

    /// "7 Nov, by Maya Ortiz, starts in 5 days", "12 Oct – 9 Nov, by Maya Ortiz, 3 still to discover", or ending in
    /// "Reached" or "Ended". No countdown while it runs (design guide page 13: calm progress).
    static func customNote(_ goal: CircleGoal, timeZone: String, now: Date = .now) -> String {
        var parts = [days(goal, timeZone: timeZone)]
        if let creator = goal.createdBy { parts.append("by \(creator.name)") }
        switch goal.status {
        case .upcoming:
            let relative = RelativeDateTimeFormatter()
            relative.dateTimeStyle = .named
            parts.append("starts \(relative.localizedString(for: goal.startsAt, relativeTo: now))")
        case .active:
            parts.append(goal.isReached ? "Reached" : stillToDiscover(goal))
        case .ended:
            parts.append(goal.isReached ? "Reached" : "Ended")
        }
        return parts.joined(separator: ", ")
    }

    /// "7 Nov", or "12 Oct – 9 Nov", in the Guild's zone.
    static func days(_ goal: CircleGoal, timeZone: String) -> String {
        let zone = TimeZone(identifier: timeZone) ?? .current
        let style = Date.FormatStyle(timeZone: zone).day().month(.abbreviated)
        let last = goal.endsAt.addingTimeInterval(-1)
        let first = goal.startsAt.formatted(style)
        return goal.startDate == goal.endDate ? first : "\(first) – \(last.formatted(style))"
    }
}

/// Makes a custom goal: a title, a target and the days, in the Guild's time zone.
struct NewGoalSheet: View {
    @Environment(CircleStore.self) private var circles
    @Environment(\.dismiss) private var dismiss
    let circleID: String
    let timeZone: String
    @State private var title = ""
    @State private var target = 20
    @State private var start = Date.now
    @State private var end = Date.now.addingTimeInterval(7 * 86_400)
    @State private var saving = false
    @State private var error: String?

    private var zone: TimeZone { TimeZone(identifier: timeZone) ?? .current }
    private var trimmed: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { (1...40).contains(trimmed.count) && !saving }

    var body: some View {
        NavigationStack {
            PaperForm {
                Section {
                    TextField("Big Day in Ojai", text: $title)
                        .accessibilityIdentifier("goalTitle")
                } header: {
                    Text("Title")
                } footer: {
                    if trimmed.count > 40 { Text("Up to 40 characters.") }
                }
                Section {
                    Stepper(value: $target, in: 1...999) {
                        Text("\(target) species").monospacedDigit()
                    }
                    .accessibilityIdentifier("goalTarget")
                } header: {
                    Text("Target")
                } footer: {
                    Text("Different species among everyone's finds; repeat sightings count once.")
                }
                Section("Days") {
                    DatePicker("First day", selection: $start, in: Date.now.addingTimeInterval(-365 * 86_400)..., displayedComponents: .date)
                    // The server takes goals of up to a year.
                    DatePicker("Last day", selection: $end, in: max(start, .now)...start.addingTimeInterval(365 * 86_400), displayedComponents: .date)
                }
                if let error {
                    Section { Text(error).foregroundStyle(Color.alert) }
                }
            }
            .environment(\.timeZone, zone)
            .navigationTitle("New goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { save() }.disabled(!canSave).accessibilityIdentifier("createGoal")
                }
            }
            .onChange(of: start) { _, start in if end < start { end = start } }
        }
    }

    private func save() {
        let days = GoalDraft.dayFormatter(zone)
        let draft = GoalDraft(title: trimmed, target: target, startDate: days.string(from: start), endDate: days.string(from: max(start, end)))
        saving = true
        Task {
            do {
                try await circles.createGoal(draft, circleID: circleID)
                dismiss()
            } catch CircleError.rejected {
                error = "Check the title (up to 40 characters), and that the last day hasn't passed and is within a year of the first."
            } catch {
                self.error = CircleStore.message(for: error, doing: "make the goal")
            }
            saving = false
        }
    }
}
