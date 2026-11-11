import PhotosUI
import SwiftUI

/// "Capture a sighting" (issues #186 and #188, of #185), over the run: the camera, then, once the shutter has given a photo,
/// "Name this bird". The run goes on listening underneath the whole time, and the camera says so. Closing the camera takes
/// nothing. The photo is written to the album at the shutter, as an unnamed sighting, before the naming opens: "Name it
/// later", or anything else that closes this, leaves it waiting on the run's page. A photo chosen from the library (#192)
/// goes the same way, with the date and place it carries, and the naming says which were its own.
///
/// From the idle Listen tab (#191) it is the same camera and naming with no run under them: the camera says nothing of
/// listening, the photo is recorded where the phone is now, and one left unnamed waits in the Collection's "To name".
struct CaptureSightingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.makeCaptureCamera) private var makeCamera
    @Environment(ListeningCoordinator.self) private var run
    @State private var camera: (any CaptureCamera)?
    /// The photo just taken, saved and waiting for its name.
    @State private var unnamed: UnnamedSighting?
    /// For a photo from the library: whether its date and place are its own.
    @State private var note: String?
    /// What the photo just taken says of itself, without its picture: its note is written again if its place arrives late.
    @State private var facts: CapturedPhoto?
    @State private var couldNotSave = false

    var body: some View {
        Group {
            if let unnamed {
                NameBirdView(unnamed: unnamed, note: note) { dismiss() }
            } else if let camera {
                CaptureCameraView(camera: camera, taken: save, close: { dismiss() })
            } else {
                Color.black.ignoresSafeArea()
            }
        }
        .task {
            if camera == nil { camera = makeCamera() }
            #if DEBUG
            // `-autoScreen name-bird`: straight to the naming of a stand-in photo, for the screenshots.
            if UserDefaults.standard.bool(forKey: "autoNameBird") {
                UserDefaults.standard.removeObject(forKey: "autoNameBird")
                save(CapturedPhoto(data: DebugSeeds.frameJPEG(), takenAt: .now))
            }
            #endif
        }
        // With no run, a shutter quicker than the phone's first fix: the place arrives a moment into the naming (issue #191).
        .task(id: unnamed?.id) {
            guard let taken = unnamed, let placed = await run.placed(taken), unnamed?.id == placed.id else { return }
            unnamed = placed
            if let facts { note = LibraryPhotoText.note(for: facts, currentPlace: placed.location) }
        }
        // The camera is for the shot: it isn't left open behind the naming, or after the cover has gone.
        .onChange(of: unnamed) { camera?.stop() }
        .onDisappear { camera?.stop() }
        // The camera stays open behind this, for another try.
        .alert("The photo couldn't be saved", isPresented: $couldNotSave) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Nothing was kept. Try again.")
        }
    }

    /// The shutter's photo, or the one chosen from the library, goes to the album before anything else happens to it.
    private func save(_ photo: CapturedPhoto) {
        if let saved = run.capture(photo) {
            note = LibraryPhotoText.note(for: photo, currentPlace: run.capturePlace)
            facts = CapturedPhoto(data: Data(), takenAt: photo.takenAt, place: photo.place, origin: photo.origin)
            unnamed = saved
        } else {
            couldNotSave = true
        }
    }
}

/// The camera inside the app: a way to close, a pill saying the run is still listening with its clock, the viewfinder, and
/// the shutter. Before the camera is open it says why not: the first use asks for it, a denial is explained with the way to
/// Settings, and a phone with no camera to give says that. The lens buttons, the zoom and the focus are the viewfinder's
/// (`CaptureViewfinder`, #187).
///
/// Beside the shutter is the library (issue #192): the system's photo picker, for a picture taken earlier or with a real
/// camera. It works whatever the camera's state, a refused camera included. Every photo the shutter takes is also copied to
/// the birder's Photos library (`PhotosCopies`), behind the naming; one chosen from the library is not.
struct CaptureCameraView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.photosCopies) private var copies
    @Environment(ListeningCoordinator.self) private var run
    #if DEBUG
    @Environment(\.standInLibraryPhoto) private var standInLibraryPhoto
    #endif
    let camera: any CaptureCamera
    let taken: (CapturedPhoto) -> Void
    let close: () -> Void
    @State private var isTaking = false
    /// What went wrong with the last photo, taken or chosen.
    @State private var failure: String?
    @State private var pickerItem: PhotosPickerItem?
    /// A chosen photo is on its way from the library: one kept in iCloud takes a moment.
    @State private var isReading = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.white.opacity(0.18), in: Circle())
                    }
                    .accessibilityLabel("Close camera")
                    .accessibilityIdentifier("capture-close")
                    Spacer(minLength: 0)
                    ListeningPill()
                    Spacer(minLength: 0)
                    // Opposite Close, so the pill sits in the middle: the flash, which is off and stays off (#187). It is
                    // said, not offered: there is nothing to press.
                    if camera.state == .ready {
                        Image(systemName: "bolt.slash.fill")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            // A mark in the bar: it stops growing where the pill beside it does.
                            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                            .accessibilityElement()
                            .accessibilityLabel("Flash off")
                            .accessibilityIdentifier("capture-flash-off")
                    } else {
                        Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Group {
                    switch camera.state {
                    case .ready:
                        CaptureViewfinder(camera: camera)
                    case .starting:
                        ProgressView("Opening the camera")
                            .tint(.white)
                            .foregroundStyle(.white)
                    case .denied:
                        notice(
                            "Camera access is off",
                            message: "Featherguild uses the camera to photograph a bird you've seen, for a sighting you name. Allow the camera in Settings > Featherguild."
                        ) {
                            Button {
                                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                            } label: {
                                // White on the camera's black: the tint's light green under white words measured too little.
                                Text("Open Settings")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 22)
                                    .frame(minHeight: 44)
                                    .background(.white, in: RoundedRectangle(cornerRadius: JournalLayout.cornerRadius, style: .continuous))
                            }
                            .buttonStyle(.journalPress)
                            .accessibilityIdentifier("capture-open-settings")
                        }
                    case .unavailable:
                        notice("No camera to use", message: CaptureCameraText.unavailable(onRun: !run.isCapturingOutsideRun)) { EmptyView() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)

                if let failure {
                    Text(failure)
                        .font(JournalFont.supporting)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                        .accessibilityIdentifier("capture-failed")
                } else if isReading {
                    ProgressView("Getting your photo")
                        .font(JournalFont.supporting)
                        .tint(.white)
                        .foregroundStyle(.white)
                        .padding(.bottom, 8)
                }
                // The shutter in the middle, the library to its left, and as much room again to its right.
                HStack(spacing: 0) {
                    libraryButton
                        .frame(maxWidth: .infinity)
                    Button(action: shoot) {
                        ZStack {
                            Circle().strokeBorder(.white, lineWidth: 4).frame(width: 76, height: 76)
                            Circle().fill(.white).frame(width: 62, height: 62)
                            if isTaking { ProgressView().tint(.black) }
                        }
                        .contentShape(Circle())
                    }
                    .buttonStyle(.journalPress)
                    .disabled(camera.state != .ready || isTaking || isReading)
                    .opacity(camera.state == .ready ? 1 : 0.35)
                    .accessibilityLabel("Take photo")
                    .accessibilityHint("Then you name the bird")
                    .accessibilityIdentifier("capture-shutter")
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: 1)
                        .accessibilityHidden(true)
                }
                .padding(.bottom, 20)
            }
        }
        // The camera is dark whatever the app's appearance.
        .environment(\.colorScheme, .dark)
        .task { await camera.start() }
        .task(id: pickerItem) {
            guard let pickerItem else { return }
            await choose { try? await pickerItem.loadTransferable(type: Data.self) }
            self.pickerItem = nil
        }
    }

    /// The library, whatever the camera's state: the system's picker, which runs outside the app, so the app needs no
    /// permission to read the library and sees only the picture chosen.
    private var libraryButton: some View {
        Group {
            #if DEBUG
            if let standInLibraryPhoto {
                Button {
                    Task { await choose { standInLibraryPhoto } }
                } label: {
                    libraryMark
                }
            } else {
                picker
            }
            #else
            picker
            #endif
        }
        .buttonStyle(.journalPress)
        .disabled(isTaking || isReading)
        .accessibilityLabel("Choose from library")
        .accessibilityHint("Then you name the bird")
        .accessibilityIdentifier("capture-library")
    }

    /// `.current`: the file as the library has it, a HEIC or a camera's RAW included, and not a JPEG made from it.
    private var picker: some View {
        PhotosPicker(selection: $pickerItem, matching: .images, preferredItemEncoding: .current) { libraryMark }
    }

    private var libraryMark: some View {
        Image(systemName: "photo.on.rectangle")
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 52, height: 52)
            .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            // A mark beside the shutter: it stops growing where the bar's marks do.
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .contentShape(Rectangle())
    }

    /// A photo from the library: its file, what the picture says of itself, then on to its naming as the shutter's goes.
    /// Nothing is copied to Photos: it is there already.
    private func choose(_ file: () async -> Data?) async {
        failure = nil
        isReading = true
        defer { isReading = false }
        let data = await file()
        guard !Task.isCancelled else { return }
        let photo = await Task.detached(priority: .userInitiated) { data.flatMap { CapturedPhoto.chosenFromLibrary($0) } }.value
        if let photo {
            taken(photo)
        } else {
            failure = "That photo couldn't be read. Try another."
        }
    }

    /// In the middle of the camera's room where it fits, and scrolling where the text is too large to.
    private func notice<Action: View>(_ title: String, message: String, @ViewBuilder action: () -> Action) -> some View {
        let words = noticeWords(title, message: message, action: action)
        return ViewThatFits(in: .vertical) {
            words
            ScrollView { words }
        }
    }

    private func noticeWords<Action: View>(_ title: String, message: String, @ViewBuilder action: () -> Action) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "camera")
                .font(.largeTitle)
                .accessibilityHidden(true)
            Text(title)
                .font(JournalFont.section)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(JournalFont.body)
                .fixedSize(horizontal: false, vertical: true)
            action()
                .padding(.top, 6)
        }
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 20)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
    }

    private func shoot() {
        guard !isTaking else { return }
        isTaking = true
        failure = nil
        Task {
            do {
                let photo = try await camera.takePhoto()
                taken(photo)
                // The birder's own copy, behind the naming: the first asks to add to Photos, and nothing waits for the answer.
                Task { await copies.keep(photo) }
            } catch {
                failure = "That photo didn't take. Try again."
            }
            isTaking = false
        }
    }
}

/// "Still listening · 12:51" over the camera: the run under it hasn't stopped, and this is its clock. It says so too when the
/// run is waiting for the glasses, or has ended while the camera was open; with no run it isn't there, nor over a camera
/// opened from the idle tab after a run that left nothing (issue #191).
private struct ListeningPill: View {
    @Environment(ListeningCoordinator.self) private var run

    var body: some View {
        if !run.isCapturingOutsideRun, let words = CaptureCameraText.listening(for: run.state) {
            TimelineView(.periodic(from: .now, by: run.clockStoppedAt == nil ? 1 : 3_600)) { context in
                let now = run.clockStoppedAt ?? context.date
                HStack(spacing: 7) {
                    Circle()
                        .fill(run.state == .listening ? AnyShapeStyle(.tint) : AnyShapeStyle(.white.opacity(0.6)))
                        .frame(width: 8, height: 8)
                    Text(words.showsClock ? "\(words.text) · \(ElapsedTime.text(from: run.clockStart, to: now))" : words.text)
                        .font(JournalFont.supporting.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 1))
                // A line of status over the viewfinder: past this size it would be the screen.
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(words.showsClock ? "\(words.text), \(CaptureCameraText.spokenClock(from: run.clockStart, to: now))" : words.text)
                .accessibilityIdentifier("capture-listening")
            }
        }
    }
}

/// What the camera says about the run under it.
enum CaptureCameraText {
    /// What the pill says for a run's state, and whether its clock goes with it; nil when no run is on or was.
    static func listening(for state: ListeningCoordinator.State) -> (text: String, showsClock: Bool)? {
        switch state {
        case .starting, .listening: ("Still listening", true)
        case .interrupted, .paused, .resuming: ("Listening paused", false)
        case .stopping, .ended: ("Listening stopped", false)
        case .idle: nil
        }
    }

    /// What the camera says when the phone has none to give. On a run, that the run goes on; with no run (issue #191), the
    /// way on that is left, which is the library button beside the shutter.
    static func unavailable(onRun: Bool) -> String {
        onRun
            ? "This iPhone's camera can't be opened right now. A run keeps listening without it."
            : "This iPhone's camera can't be opened right now. You can still choose a photo from your library."
    }

    /// "12 minutes 51 seconds", for VoiceOver.
    static func spokenClock(from start: Date?, to now: Date) -> String {
        let seconds = max(Int(now.timeIntervalSince(start ?? now)), 0)
        return "\(seconds / 60) \(seconds / 60 == 1 ? "minute" : "minutes") \(seconds % 60) \(seconds % 60 == 1 ? "second" : "seconds")"
    }
}

