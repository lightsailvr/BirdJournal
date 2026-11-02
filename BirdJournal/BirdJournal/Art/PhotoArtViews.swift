import Album
import Pack
import PhotosUI
import SwiftUI

/// The rules of the photo-art flow that the views follow (issue #69).
enum PhotoArtFlow {
    /// Attaching a photo to a Heard card asks "Did you see it?" before it would switch to Seen (spec v2, "Method changes
    /// on the phone"). The card's own glasses photo isn't an attachment, so painting it asks nothing.
    static func asksDidYouSeeIt(method: SightingMethod, attaching: Bool) -> Bool {
        attaching && method == .heard
    }
}

/// Where the photo for photo art comes from.
private enum PhotoChoice: Equatable {
    /// The card's glasses photo, already on the phone.
    case glasses(path: String)
    /// A photo from the library, not attached until the birder confirms it.
    case library(Data)
}

/// Asking for photo art (issue #69, spec v2 stories 53 and 54): choose the card's glasses photo or one from the library,
/// then confirm the bird in it is the card's species, since nothing checks it automatically. A library photo is then
/// attached to the card as an original (on a Heard card, "Did you see it?") and the painting is asked for. Shows the
/// public launch's "N left today".
struct PhotoArtRequestSheet: View {
    @Environment(ArtJobs.self) private var art
    @Environment(JournalEdits.self) private var edits
    @Environment(\.dismiss) private var dismiss
    let sighting: Sighting
    let commonName: String
    @State private var choice: PhotoChoice?
    @State private var pickerItem: PhotosPickerItem?
    @State private var askingDidYouSeeIt = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            PaperPage {
                VStack(alignment: .leading, spacing: JournalLayout.rowGap) {
                    if let choice {
                        confirm(choice)
                    } else {
                        choose
                    }
                    if let line = CardText.allowanceLine(art.allowance) {
                        Text(line)
                            .font(JournalFont.supporting)
                            .foregroundStyle(Color.inkSecondary)
                            .accessibilityIdentifier("photo-art-allowance")
                    }
                    if let failure {
                        Text(failure).font(JournalFont.supporting).foregroundStyle(Color.inkSecondary)
                    }
                }
                .padding(.top, 4)
            }
            .navigationTitle("Art from your photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await art.refreshAllowance() }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        choice = .library(data)
                    } else {
                        failure = "That photo couldn't be read. Try another."
                    }
                    pickerItem = nil
                }
            }
            .alert("Did you see it?", isPresented: $askingDidYouSeeIt) {
                Button("Yes, I saw it") {
                    edits.setMethod(.seen, on: sighting)
                    dismiss()
                }
                Button("No, I only heard it", role: .cancel) { dismiss() }
            } message: {
                Text("You attached a photo to a card marked Heard. If you saw the bird too, the card can say Seen.")
            }
        }
    }

    private var hasPaintingsLeft: Bool { art.allowance?.hasPaintingsLeft ?? true }

    @ViewBuilder private var choose: some View {
        Text("Your own photo of this \(commonName), embellished into card art. You'll see it beside your photo before anything changes, and your photo is kept as it is.")
            .font(JournalFont.body)
            .foregroundStyle(Color.ink)
            .fixedSize(horizontal: false, vertical: true)
        if let frame = sighting.frameImagePath {
            Button {
                choice = .glasses(path: frame)
            } label: {
                Label("Use the glasses photo", systemImage: "eyeglasses").frame(maxWidth: .infinity)
            }
            .buttonStyle(.journalOutlined)
            .accessibilityIdentifier("photo-art-glasses")
        }
        libraryButton
            .disabled(!hasPaintingsLeft)
        if !hasPaintingsLeft {
            Text(ArtJobs.allowanceSpentMessage(art.allowance))
                .font(JournalFont.supporting)
                .foregroundStyle(Color.inkSecondary)
        }
    }

    @ViewBuilder private var libraryButton: some View {
        #if DEBUG
        // `-fakeLibraryPhoto`: the UI tests can't drive the system photo picker, so this picks the card's glasses photo
        // as if it came from the library (attached as a new original).
        if UserDefaults.standard.bool(forKey: "fakeLibraryPhoto") {
            Button {
                if let frame = sighting.frameImagePath, let data = try? Data(contentsOf: frameURL(frame)) { choice = .library(data) }
            } label: {
                Label("Choose from your library", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.journalOutlined)
            .accessibilityIdentifier("photo-art-library")
        } else {
            picker
        }
        #else
        picker
        #endif
    }

    @Environment(\.frameStore) private var frameStore

    private func frameURL(_ path: String) -> URL {
        frameStore?.url(for: path) ?? URL(filePath: path)
    }

    private var picker: some View {
        PhotosPicker(selection: $pickerItem, matching: .images) {
            Label("Choose from your library", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity)
        }
        .buttonStyle(.journalOutlined)
        .accessibilityIdentifier("photo-art-library")
    }

    @ViewBuilder private func confirm(_ choice: PhotoChoice) -> some View {
        Group {
            switch choice {
            case .glasses(let path): StoredPhoto(path: path, label: "Your glasses photo")
            case .library(let data): DataPhoto(data: data, label: "Your photo")
            }
        }
        .frame(maxHeight: 360)
        Text("Is this bird a \(commonName)?")
            .font(JournalFont.title)
            .foregroundStyle(Color.ink)
            .accessibilityAddTraits(.isHeader)
        Text("Nothing checks the photo automatically, so make sure the bird in it is the one on this card.")
            .font(JournalFont.supporting)
            .foregroundStyle(Color.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
        Button {
            paint(choice)
        } label: {
            Text("Yes, it's a \(commonName)").frame(maxWidth: .infinity)
        }
        .buttonStyle(.journalPrimary)
        .disabled(!hasPaintingsLeft)
        .accessibilityIdentifier("photo-art-confirm")
        Button {
            self.choice = nil
        } label: {
            Text("Choose another photo").frame(maxWidth: .infinity)
        }
        .buttonStyle(.journalOutlined)
        .accessibilityIdentifier("photo-art-choose-again")
    }

    private func paint(_ choice: PhotoChoice) {
        let source: String
        let attaching: Bool
        switch choice {
        case .glasses(let path):
            source = path
            attaching = false
        case .library(let data):
            do {
                source = try art.attachPhoto(data, to: sighting)
            } catch {
                failure = "The photo couldn't be saved on this iPhone."
                return
            }
            attaching = true
        }
        Task { await art.paintPhoto(sighting, from: source) }
        if PhotoArtFlow.asksDidYouSeeIt(method: sighting.method, attaching: attaching) {
            askingDidYouSeeIt = true
        } else {
            dismiss()
        }
    }
}

/// The comparison (issue #69, style guide "Art direction"): the original and the painting side by side, with Approve,
/// Keep original and Try again. Nothing on the card changes until the birder approves.
struct PhotoArtComparisonSheet: View {
    @Environment(ArtJobs.self) private var art
    @Environment(\.dismiss) private var dismiss
    let sighting: Sighting

    var body: some View {
        NavigationStack {
            PaperPage {
                VStack(alignment: .leading, spacing: JournalLayout.rowGap) {
                    if case .preview(let path, let source) = sighting.art.photoStatus {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(spacing: 4) {
                                if let source { StoredPhoto(path: source, label: "Your photo") }
                                caption("Your photo")
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("photo-art-original")
                            VStack(spacing: 4) {
                                StoredPhoto(path: path, label: "AI-embellished from your photo")
                                caption("AI-embellished from your photo")
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("photo-art-generated")
                        }
                        Text("Your photo stays as it is, whatever you choose.")
                            .font(JournalFont.supporting)
                            .foregroundStyle(Color.inkSecondary)
                        Button {
                            art.approvePhotoArt(sighting)
                            dismiss()
                        } label: {
                            Label("Approve", systemImage: "checkmark").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.journalPrimary)
                        .accessibilityHint("Puts this painting on the card.")
                        .accessibilityIdentifier("photo-art-approve")
                        Button {
                            art.keepOriginalPhoto(sighting)
                            dismiss()
                        } label: {
                            Label("Keep original", systemImage: "photo").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.journalOutlined)
                        .accessibilityHint("Lets this painting go. The card stays as it was.")
                        .accessibilityIdentifier("photo-art-keep-original")
                        Button {
                            Task { await art.paintPhotoAgain(sighting) }
                            dismiss()
                        } label: {
                            Label("Try again", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.journalOutlined)
                        .disabled(!(art.allowance?.hasPaintingsLeft ?? true))
                        .accessibilityHint("Paints a new picture from the same photo.")
                        .accessibilityIdentifier("photo-art-try-again")
                        if let line = CardText.allowanceLine(art.allowance) {
                            Text(line)
                                .font(JournalFont.supporting)
                                .foregroundStyle(Color.inkSecondary)
                                .accessibilityIdentifier("photo-art-allowance")
                        }
                    } else {
                        ContentUnavailableView("Nothing to review", systemImage: "photo.artframe")
                    }
                }
                .padding(.top, 4)
            }
            .navigationTitle("Your photo art")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") { dismiss() }
                }
            }
            .task { await art.refreshAllowance() }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(JournalFont.attribution)
            .foregroundStyle(Color.inkSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}

/// Photo art's controls under the card (issue #69): ask for it, review a waiting painting, and Retry art or Keep current
/// art after a failure. Asking needs the account; a waiting painting can be reviewed without one.
struct PhotoArtActions: View {
    @Environment(ArtJobs.self) private var art
    @Environment(PackLibrary.self) private var library
    let sighting: Sighting
    @State private var requesting = false
    @State private var reviewing = false

    var body: some View {
        let status = sighting.art.photoStatus
        VStack(spacing: 8) {
            if let line = CardText.photoArtLine(status) {
                Label(line, systemImage: status == .failed ? "exclamationmark.circle" : "paintbrush.pointed")
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(line)
                    .accessibilityIdentifier("card-photo-art-status")
            }
            if let refusal = art.refusal {
                Text(refusal)
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("card-photo-art-refusal")
            }
            switch status {
            case .preview:
                Button {
                    reviewing = true
                } label: {
                    Label("Review your photo art", systemImage: "photo.artframe").frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("card-photo-art-review")
            case .failed:
                HStack(spacing: 10) {
                    if art.isAvailable {
                        Button("Retry art", systemImage: "arrow.clockwise") { Task { await art.paintPhotoAgain(sighting) } }
                            .accessibilityIdentifier("card-photo-art-retry")
                    }
                    Button("Keep current art", systemImage: "checkmark") { art.keepCurrentPhotoArt(sighting) }
                        .accessibilityIdentifier("card-photo-art-keep")
                }
            case .none, .approved:
                if art.isAvailable {
                    Button {
                        art.refusal = nil
                        requesting = true
                    } label: {
                        Label(status == .approved ? "New art from your photo" : "Art from your photo", systemImage: "wand.and.sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("card-photo-art")
                }
            case .pending:
                EmptyView()
            }
        }
        .buttonStyle(.journalOutlined)
        .sheet(isPresented: $requesting) {
            PhotoArtRequestSheet(sighting: sighting, commonName: library.commonName(for: sighting))
        }
        #if DEBUG
        // `-autoPhotoArt request|review` opens the request or the comparison, for screenshots.
        .task {
            switch UserDefaults.standard.string(forKey: "autoPhotoArt") {
            case "request": requesting = true
            case "review": if case .preview = sighting.art.photoStatus { reviewing = true }
            default: break
            }
        }
        #endif
        .sheet(isPresented: $reviewing) {
            PhotoArtComparisonSheet(sighting: sighting)
        }
    }
}

/// A photo kept on the phone (an original or a painting), fitted to its frame.
private struct StoredPhoto: View {
    @Environment(\.frameStore) private var frameStore
    let path: String
    let label: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Color.inkSecondary.opacity(0.1).aspectRatio(3 / 4, contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isImage)
        .task(id: path) {
            guard let url = frameStore?.url(for: path) else { return }
            image = await Task.detached(priority: .userInitiated) { (try? Data(contentsOf: url)).flatMap(UIImage.init(data:)) }.value
        }
    }
}

/// A photo just picked from the library, before it is attached.
private struct DataPhoto: View {
    let data: Data
    let label: String

    var body: some View {
        Group {
            if let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                ContentUnavailableView("Photo unavailable", systemImage: "photo")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isImage)
    }
}
