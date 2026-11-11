import SwiftUI

/// "Capture a sighting" (issues #186 and #188, of #185), over the run: the camera, then, once the shutter has given a photo,
/// "Name this bird". The run goes on listening underneath the whole time, and the camera says so. Closing the camera takes
/// nothing. The photo is written to the album at the shutter, as an unnamed sighting, before the naming opens: "Name it
/// later", or anything else that closes this, leaves it waiting on the run's page.
struct CaptureSightingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.makeCaptureCamera) private var makeCamera
    @Environment(ListeningCoordinator.self) private var run
    @State private var camera: (any CaptureCamera)?
    /// The photo just taken, saved and waiting for its name.
    @State private var unnamed: UnnamedSighting?
    @State private var couldNotSave = false

    var body: some View {
        Group {
            if let unnamed {
                NameBirdView(unnamed: unnamed) { dismiss() }
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
        // The camera is for the shot: it isn't left open behind the naming, or after the cover has gone.
        .onChange(of: unnamed) { camera?.stop() }
        .onDisappear { camera?.stop() }
        // The camera stays open behind this, for another try.
        .alert("The photo couldn't be saved", isPresented: $couldNotSave) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Nothing was kept. Take it again.")
        }
    }

    /// The shutter's photo goes to the album before anything else happens to it.
    private func save(_ photo: CapturedPhoto) {
        if let saved = run.capture(photo) {
            unnamed = saved
        } else {
            couldNotSave = true
        }
    }
}

/// The camera inside the app: a way to close, a pill saying the run is still listening with its clock, the viewfinder, and
/// the shutter. Before the camera is open it says why not: the first use asks for it, a denial is explained with the way to
/// Settings, and a phone with no camera to give says that. The lens buttons, the zoom and the focus are the viewfinder's
/// (`CaptureViewfinder`, #187); #192 adds the library.
struct CaptureCameraView: View {
    @Environment(\.openURL) private var openURL
    let camera: any CaptureCamera
    let taken: (CapturedPhoto) -> Void
    let close: () -> Void
    @State private var isTaking = false
    @State private var failed = false

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
                        notice("No camera to use", message: "This iPhone's camera can't be opened right now. A run keeps listening without it.") { EmptyView() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)

                if failed {
                    Text("That photo didn't take. Try again.")
                        .font(JournalFont.supporting)
                        .foregroundStyle(.white)
                        .padding(.bottom, 8)
                        .accessibilityIdentifier("capture-failed")
                }
                Button(action: shoot) {
                    ZStack {
                        Circle().strokeBorder(.white, lineWidth: 4).frame(width: 76, height: 76)
                        Circle().fill(.white).frame(width: 62, height: 62)
                        if isTaking { ProgressView().tint(.black) }
                    }
                    .contentShape(Circle())
                }
                .buttonStyle(.journalPress)
                .disabled(camera.state != .ready || isTaking)
                .opacity(camera.state == .ready ? 1 : 0.35)
                .accessibilityLabel("Take photo")
                .accessibilityHint("Then you name the bird")
                .accessibilityIdentifier("capture-shutter")
                .padding(.bottom, 20)
            }
        }
        // The camera is dark whatever the app's appearance.
        .environment(\.colorScheme, .dark)
        .task { await camera.start() }
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
        failed = false
        Task {
            do {
                taken(try await camera.takePhoto())
            } catch {
                failed = true
            }
            isTaking = false
        }
    }
}

/// "Still listening · 12:51" over the camera: the run under it hasn't stopped, and this is its clock. It says so too when the
/// run is waiting for the glasses, or has ended while the camera was open; with no run it isn't there.
private struct ListeningPill: View {
    @Environment(ListeningCoordinator.self) private var run

    var body: some View {
        if let words = CaptureCameraText.listening(for: run.state) {
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

    /// "12 minutes 51 seconds", for VoiceOver.
    static func spokenClock(from start: Date?, to now: Date) -> String {
        let seconds = max(Int(now.timeIntervalSince(start ?? now)), 0)
        return "\(seconds / 60) \(seconds / 60 == 1 ? "minute" : "minutes") \(seconds % 60) \(seconds % 60 == 1 ? "second" : "seconds")"
    }
}

