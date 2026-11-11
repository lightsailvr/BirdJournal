import Album
import Identification
import LensSession
import Pack
import SwiftData
import SwiftUI

#if DEBUG
/// The development hub that was the app's front page before the field journal (issue #28): the raw listening
/// screens with their diagnostics, the lens and the audio spike, the mock device, and one fact per module. Debug
/// builds only, behind Settings; the launch flags for screenshots open it on their own.
struct DeveloperView: View {
    @Query private var sightings: [Sighting]
    @Environment(PackLibrary.self) private var library
    @Environment(ListeningCoordinator.self) private var run
    @Environment(PushCenter.self) private var pushes
    @State private var path: [Screen] = []

    private let planner = WindowPlanner()

    enum Screen: Hashable {
        case glassesListening
        case phoneListening
        case audioSpike
        case lens
    }

    /// Whether any launch flag asks for this hub, so the root can present it.
    static var isRequestedAtLaunch: Bool {
        let defaults = UserDefaults.standard
        return defaults.bool(forKey: "autoMockLens") || defaults.object(forKey: "autoPhoneListening") != nil || defaults.bool(forKey: "developer")
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    NavigationLink("Glasses run (diagnostics)", value: Screen.glassesListening)
                    NavigationLink("Phone run (diagnostics)", value: Screen.phoneListening)
                    NavigationLink("Lens", value: Screen.lens)
                    NavigationLink("Audio spike", value: Screen.audioSpike)
                } header: {
                    Text("Raw screens")
                } footer: {
                    Text("The same sessions the Listen tab drives (\(String(describing: run.state))), with every state the toolkit reports.")
                }

                GlassesSection()

                if pushes.isAvailable {
                    Section {
                        LabeledContent("Permission", value: pushes.permission.map { String(describing: $0) } ?? "not read")
                        LabeledContent("Environment", value: pushes.environment.rawValue)
                        Text(pushes.deviceToken ?? "No token yet")
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    } header: {
                        Text("Push token")
                    } footer: {
                        Text("For infra/scripts/push-wizard.sh's test push (issue #63): touch and hold the token to copy it.")
                    }
                }

                FriendBannerSection()
                DictationSection()

                Section("Modules") {
                    LabeledContent("Identification", value: "\(planner.sampleRate) Hz, \(planner.samplesPerWindow) samples per window")
                    LabeledContent("LensSession", value: "\(LensCardRenderer.wordBudget) words per page")
                    LabeledContent("Pack", value: library.packs.isEmpty ? "\(PackIndex.bundledPackID) missing" : library.packs.map { "\($0.info.id) v\($0.info.version), \($0.species.count) species" }.joined(separator: "; "))
                    LabeledContent("Album", value: "\(sightings.count) sightings")
                }
            }
            .navigationTitle("Developer")
            .navigationDestination(for: Screen.self) { screen in
                switch screen {
                case .glassesListening: GlassesListeningView()
                case .phoneListening: PhoneListeningView()
                case .audioSpike: SpikeView()
                case .lens: LensSessionView()
                }
            }
            .modifier(AutoMockLens(path: $path))
            .modifier(AutoPhoneListening(path: $path))
        }
    }
}
#endif

#if DEBUG
/// Launch with `-autoMockLens YES` to pair the mock, open the lens screen, start the pages, hear three fake
/// species and walk to the second species card: a screenshot of the simulator then shows the mock lens without any taps.
/// `-autoMockLensInputs "navLeft select"` walks a different sequence (mock input names, one second apart). The
/// stack is fed again once the sequence is done, so the two newest species are calling now for the next few
/// seconds (issue #42) and a screenshot taken then shows the marked rows. `-autoMockLensFriend YES` then hands the
/// push center a friend's notable find, which the lens shows as a friend banner (issue #67).
///
/// `-autoMockLensCamera YES` gives this lens, which has no run and so no camera, a stand-in for one (issue #193): its
/// viewfinders show a drawn frame, and a tap on the capture viewfinder writes that frame as an unnamed sighting from the
/// glasses, so the lens goes on to "Photo saved" and the Collection lists it under "To name". `wait` in the inputs is a
/// second with no input, to step past the viewfinder's echo window ("navUp select wait select"),
/// `-autoMockLensSpecies <n>` hears that many fake species instead of three (0: the empty list; 6: all of them, a second page), and
/// `-autoMockLensPhotoSeconds <s>` holds the stand-in's photo that long, with the lens on "Saving the photo…".
///
/// With the camera the lens goes on to ask for the bird's name (issue #194), as a run's does: "navUp select wait select"
/// ends on "Say the bird's name", listening (`-dictationSilenceSeconds 60` keeps it there for a screenshot).
/// `-autoMockLensSay "black feeby"` is what the mock's glasses then hear, at these names in the inputs: `hear` tells the
/// words as heard so far, `say` as final (the birds' page), and `speechError` is a recognition error. So
/// "navUp select wait select wait say" ends on the birds, "… say select" on "Added", and "… say navDown navDown navDown
/// select" on "Say it again"'s second listening. `-autoMockLensDictation NO` is a lens that cannot ask (no microphone
/// permission): the photo goes straight to "Photo saved".
private struct AutoMockLens: ViewModifier {
    @Environment(GlassesConnection.self) private var connection
    @Environment(GlassesLensSession.self) private var lens
    @Environment(PushCenter.self) private var pushes
    @Environment(ListeningCoordinator.self) private var run
    @Environment(PackLibrary.self) private var library
    @Binding var path: [DeveloperView.Screen]

    func body(content: Content) -> some View {
        content.task {
            let defaults = UserDefaults.standard
            guard defaults.bool(forKey: "autoMockLens") else { return }
            connection.pairMockGlasses()
            path = [.lens]
            if defaults.bool(forKey: "autoMockLensCamera") {
                let jpeg = DebugSeeds.frameJPEG()
                lens.viewfinderFrame = { CameraFrame(jpegData: { jpeg }) }
                let hold = defaults.double(forKey: "autoMockLensPhotoSeconds")
                let asksName = defaults.object(forKey: "autoMockLensDictation") == nil || defaults.bool(forKey: "autoMockLensDictation")
                let naming = MockLensNaming(run: run, fieldGuide: library.fieldGuideBirds)
                lens.names = asksName ? naming.source(heard: { [lens] in lens.stack.candidates.map(\.species.scientificName) }) : nil
                lens.onCapture = { [lens, run] id in
                    let photo = CapturedPhoto(data: jpeg, takenAt: .now)
                    Task {
                        try? await Task.sleep(for: .seconds(hold))
                        guard let unnamed = run.capture(photo, at: nil, source: .glasses) else {
                            lens.captureFailed(id)
                            return
                        }
                        naming.captured[id] = unnamed
                        lens.captureSaved(id, askName: asksName, photo: DisplayCardBuilder.capturedPhotoImage(jpeg))
                    }
                }
            }
            await lens.start()
            let species = defaults.object(forKey: "autoMockLensSpecies") == nil ? 3 : min(defaults.integer(forKey: "autoMockLensSpecies"), FakeLensStack.species.count)
            lens.update(with: FakeLensStack.stack(count: species), at: FakeLensStack.time(count: species))
            let sequence = defaults.string(forKey: "autoMockLensInputs") ?? "navLeft navLeft"
            let said = defaults.string(forKey: "autoMockLensSay") ?? ""
            for name in sequence.split(whereSeparator: \.isWhitespace) {
                try? await Task.sleep(for: .seconds(1))
                // "wait" is a second with no input; a name that is no input is skipped, with its second.
                if let input = GlassesConnection.MockInput.allCases.first(where: { String(describing: $0) == name }) {
                    connection.injectMockInput(input)
                } else if ["hear", "say", "speechError"].contains(name) {
                    // The mock drops what it is told while Speech is not listening: give the lens a moment to start it.
                    for _ in 0..<50 where !connection.mockSpeechIsListening { try? await Task.sleep(for: .milliseconds(100)) }
                    switch name {
                    case "hear": connection.simulateMockSpeech(said, isFinal: false)
                    case "say": connection.simulateMockSpeech(said, isFinal: true)
                    default: connection.simulateMockSpeechError()
                    }
                }
            }
            try? await Task.sleep(for: .seconds(1))
            lens.update(with: FakeLensStack.stack(count: species), at: FakeLensStack.time(count: species))
            // `-autoMockLensFriend YES`: a friend's notable find arrives as a push would (issue #67).
            if UserDefaults.standard.bool(forKey: "autoMockLensFriend") {
                await pushes.received(FriendBanners.samplePush())
            }
        }
    }
}
#endif

#if DEBUG
/// The field check's switch for saying a bird's name on the lens (issue #194, DAT-SETUP-CHECKLIST.md step 16): whether
/// the camera stream stays on while the glasses listen. Read as each dictation starts, so it can be flipped mid-run.
private struct DictationSection: View {
    @AppStorage(DictationSettings.keepsStreamKey) private var keepsStream = true

    var body: some View {
        Section {
            Toggle("Keep the camera stream on while saying a name", isOn: $keepsStream)
        } header: {
            Text("Dictation on the lens")
        } footer: {
            Text("On: the glasses listen for the bird's name with the listening stream running. Off: the stream comes off the session for those seconds, as it does for a reference clip, and goes back after. Flip it if the lens never hears a name with it on.")
        }
    }
}
#endif

#if DEBUG
/// The friend banner's checks (issue #67, DAT-SETUP-CHECKLIST.md): a notable push handled as if APNs had delivered
/// it, so it reaches whichever lens holds a run's pages, and an ordinary local notification, to see whether the
/// glasses mirror it. Both wait 10 s, time to put the glasses on a page or lock the phone.
private struct FriendBannerSection: View {
    @Environment(PushCenter.self) private var pushes
    @State private var status: String?

    var body: some View {
        Section {
            Button("Friend's find on the lens in 10 s") {
                status = "Arrives in 10 s."
                Task {
                    try? await Task.sleep(for: .seconds(10))
                    await pushes.received(FriendBanners.samplePush())
                    status = "Sent to the lens."
                }
            }
            Button("Post a local notification in 10 s") {
                Task { status = await FriendBanners.postLocalNotification(after: 10) }
            }
        } header: {
            Text("Friend banner")
        } footer: {
            Text(status ?? "\"Maya heard a Black Phoebe · Pasadena\" on a running lens, held on the viewfinder, a details page or a sounds page.")
        }
    }
}
#endif

#if DEBUG
/// Launch with `-autoPhoneListening YES` (or a WAV path, see `BirdJournalApp`) to open the phone listening screen
/// and start a session, for screenshots and simulator checks of the location and model paths.
private struct AutoPhoneListening: ViewModifier {
    @Environment(ListeningSession.self) private var session
    @Binding var path: [DeveloperView.Screen]

    func body(content: Content) -> some View {
        content.task {
            guard UserDefaults.standard.object(forKey: "autoPhoneListening") != nil else { return }
            path = [.phoneListening]
            await session.start()
        }
    }
}
#endif



