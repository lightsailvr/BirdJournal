import SwiftUI

/// The goal card on a circle's page (issue #65): this month's goal, sized from the circle's last month, with its
/// progress in distinct species, then the circle's custom goals (running, coming and just ended), and **New goal**.
/// A custom goal's creator or the circle's creator swipes it away.
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
                        MonthlyGoalCard(goal: goal)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                    } else {
                        CustomGoalRow(goal: goal, timeZone: timeZone)
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
                    Text("It goes for everyone in the circle. The finds stay.")
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
                    Text(error).font(JournalFont.supporting).foregroundStyle(.red)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        } header: {
            Text("Goals")
        } footer: {
            if goals?.contains(where: { $0.kind == .custom }) == true {
                Text("Goals count different species, not repeat cards, among everyone's finds.")
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

/// This month's goal: the month, "9 of 14 species", a bar, and the days left or "Reached".
struct MonthlyGoalCard: View {
    let goal: CircleGoal

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(goal.title).font(JournalFont.heading)
                Spacer()
                if goal.isReached {
                    Label("Reached", systemImage: "checkmark.seal.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.goldInk)
                }
            }
            Text(GoalWords.count(goal))
                .font(.system(.title, design: .serif, weight: .semibold))
                .foregroundStyle(Color.ink)
            GoalBar(goal: goal, height: 10)
            Text(GoalWords.monthlyNote(goal))
                .font(JournalFont.supporting)
                .foregroundStyle(Color.inkSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.raised, in: RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous)
                .strokeBorder(goal.isReached ? Color.goldInk.opacity(0.6) : Color.rule, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("goal-monthly")
    }
}

/// A custom goal: its title, its days, who made it, the count and a bar.
struct CustomGoalRow: View {
    let goal: CircleGoal
    let timeZone: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(goal.title).font(JournalFont.rowTitle)
                Spacer()
                Text(GoalWords.count(goal, short: true))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(goal.isReached ? Color.goldInk : Color.ink)
            }
            GoalBar(goal: goal, height: 6)
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

private struct GoalBar: View {
    let goal: CircleGoal
    let height: CGFloat

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.rule.opacity(0.6))
                Capsule()
                    .fill(goal.isReached ? Color.goldInk : Color.moss)
                    .frame(width: geometry.size.width * GoalWords.fraction(goal))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// What the goal card says, apart from the views so the tests read it.
enum GoalWords {
    static func fraction(_ goal: CircleGoal) -> Double {
        guard goal.target > 0 else { return 0 }
        return min(1, Double(goal.progress) / Double(goal.target))
    }

    /// "9 of 14 species", or "9/14" in a row.
    static func count(_ goal: CircleGoal, short: Bool = false) -> String {
        short ? "\(goal.progress)/\(goal.target)" : "\(goal.progress) of \(goal.target) species"
    }

    /// "5 more to go · 18 days left", "Reached on 12 November", or "The month is over".
    static func monthlyNote(_ goal: CircleGoal, now: Date = .now) -> String {
        if goal.isReached { return "Reached! Every new bird this month is a bonus." }
        let left = goal.target - goal.progress
        return "\(left) more to go · \(daysLeft(goal, now: now))"
    }

    /// "Big Day · 7 Nov · by Maya Ortiz · starts in 5 days", or with "Reached" or "Ended".
    static func customNote(_ goal: CircleGoal, timeZone: String, now: Date = .now) -> String {
        var parts = [days(goal, timeZone: timeZone)]
        if let creator = goal.createdBy { parts.append("by \(creator.name)") }
        switch goal.status {
        case .upcoming:
            parts.append("starts \(goal.startsAt.formatted(.relative(presentation: .named, unitsStyle: .wide)))")
        case .active:
            parts.append(goal.isReached ? "Reached" : daysLeft(goal, now: now))
        case .ended:
            parts.append(goal.isReached ? "Reached" : "Ended")
        }
        return parts.joined(separator: " · ")
    }

    /// "7 Nov", or "12 Oct – 9 Nov", in the circle's zone.
    static func days(_ goal: CircleGoal, timeZone: String) -> String {
        let zone = TimeZone(identifier: timeZone) ?? .current
        let style = Date.FormatStyle(timeZone: zone).day().month(.abbreviated)
        let last = goal.endsAt.addingTimeInterval(-1)
        let first = goal.startsAt.formatted(style)
        return goal.startDate == goal.endDate ? first : "\(first) – \(last.formatted(style))"
    }

    /// "18 days left", "1 day left", "Last day".
    static func daysLeft(_ goal: CircleGoal, now: Date) -> String {
        let days = Int((goal.endsAt.timeIntervalSince(now) / 86_400).rounded(.up))
        switch days {
        case ...0: return "Ended"
        case 1: return "Last day"
        default: return "\(days) days left"
        }
    }
}

/// Makes a custom goal: a title, a target and the days, in the circle's time zone.
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
            Form {
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
                    Text("Different species among everyone's finds; repeat cards count once.")
                }
                Section("Days") {
                    DatePicker("First day", selection: $start, in: Date.now.addingTimeInterval(-365 * 86_400)..., displayedComponents: .date)
                    DatePicker("Last day", selection: $end, in: max(start, .now)..., displayedComponents: .date)
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .environment(\.timeZone, zone)
            .scrollContentBackground(.hidden)
            .background(Color.paper)
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
                error = "Check the title (up to 40 characters) and that the last day hasn't passed."
            } catch {
                self.error = CircleStore.message(for: error, doing: "make the goal")
            }
            saving = false
        }
    }
}
