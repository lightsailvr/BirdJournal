import SwiftUI

/// Create and creator-only editing share the same name and emblem controls.
struct GuildEditorSheet: View {
    @Environment(CircleStore.self) private var circles
    @Environment(\.dismiss) private var dismiss
    let circle: CircleSummary?
    @State private var name: String
    @State private var emblem: CircleEmblem?
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focused: Bool

    init(circle: CircleSummary?) {
        self.circle = circle
        _name = State(initialValue: circle?.name ?? "")
        _emblem = State(initialValue: circle?.emblem)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var identity: GuildIdentity {
        var preview = circle ?? CircleSummary(id: "new-guild", name: name, createdBy: "", createdAt: .now, timeZone: "UTC", memberCount: 1, isCreator: true)
        preview.emblem = emblem
        return GuildIdentity(circle: preview)
    }

    var body: some View {
        NavigationStack {
            PaperList {
                Section {
                    TextField("Guild name", text: $name)
                        .focused($focused)
                        .accessibilityIdentifier("guildName")
                        .submitLabel(.done)
                        .onSubmit(save)
                } footer: {
                    Text("Up to 40 characters. Everyone in the Guild sees it.")
                }
                Section {
                    HStack {
                        Spacer()
                        GuildEmblem(identity: identity, size: 96)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    Picker("Mark", selection: Binding(
                        get: { identity.mark },
                        set: { emblem = CircleEmblem(mark: $0, tone: identity.tone.name) }
                    )) {
                        ForEach(Array(zip(GuildIdentity.marks, Self.markNames)), id: \.0) { mark, name in
                            Label(name, systemImage: mark).tag(mark)
                        }
                    }
                    .accessibilityIdentifier("guildEmblemMark")
                    Picker("Colour", selection: Binding(
                        get: { identity.tone.name },
                        set: { emblem = CircleEmblem(mark: identity.mark, tone: $0) }
                    )) {
                        ForEach(GuildIdentity.tones, id: \.name) { tone in
                            Text(tone.name.capitalized).tag(tone.name)
                        }
                    }
                    .accessibilityIdentifier("guildEmblemTone")
                    if circle == nil, emblem != nil {
                        Button("Choose automatically") { emblem = nil }
                    }
                } header: {
                    Text("Guild icon")
                } footer: {
                    Text(circle == nil && emblem == nil
                         ? "An icon is chosen automatically when you create your Guild. Pick a mark or colour to choose your own."
                         : "Everyone in the Guild and anyone opening its invitation sees this icon.")
                }
                if let error {
                    Section { InlineError(error, afterAction: true) }
                }
            }
            .disabled(saving)
            .navigationTitle(circle == nil ? "New Guild" : "Edit Guild")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else {
                        Button(circle == nil ? "Create" : "Save", action: save)
                            .disabled(trimmed.isEmpty || trimmed.count > 40)
                            .accessibilityIdentifier("saveGuild")
                    }
                }
            }
        }
        .onAppear { focused = circle == nil }
        .presentationDetents([.large])
        .interactiveDismissDisabled(saving)
    }

    private func save() {
        guard !trimmed.isEmpty, trimmed.count <= 40, !saving else { return }
        saving = true
        Task {
            do {
                if let circle {
                    try await circles.updateCircle(id: circle.id, name: trimmed, emblem: emblem)
                } else {
                    try await circles.create(named: trimmed, emblem: emblem)
                }
                dismiss()
            } catch {
                self.error = CircleStore.message(for: error, doing: circle == nil ? "create the Guild" : "update the Guild")
            }
            saving = false
        }
    }

    private static let markNames = ["Leaf", "Bird", "Tree", "Water", "Mountains", "Sunrise", "Flower", "Wind", "Moon and stars", "Raindrop"]
}
