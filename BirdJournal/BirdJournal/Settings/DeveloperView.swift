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
private struct AutoMockLens: ViewModifier {
    @Environment(GlassesConnection.self) private var connection
    @Environment(GlassesLensSession.self) private var lens
    @Environment(PushCenter.self) private var pushes
    @Binding var path: [DeveloperView.Screen]

    func body(content: Content) -> some View {
        content.task {
            guard UserDefaults.standard.bool(forKey: "autoMockLens") else { return }
            connection.pairMockGlasses()
            path = [.lens]
            await lens.start()
            lens.update(with: FakeLensStack.stack(count: 3), at: FakeLensStack.time(count: 3))
            let sequence = UserDefaults.standard.string(forKey: "autoMockLensInputs") ?? "navLeft navLeft"
            let inputs = sequence.split(whereSeparator: \.isWhitespace).compactMap { name in
                GlassesConnection.MockInput.allCases.first { String(describing: $0) == name }
            }
            for input in inputs {
                try? await Task.sleep(for: .seconds(1))
                connection.injectMockInput(input)
            }
            try? await Task.sleep(for: .seconds(1))
            lens.update(with: FakeLensStack.stack(count: 3), at: FakeLensStack.time(count: 3))
            // `-autoMockLensFriend YES`: a friend's notable find arrives as a push would (issue #67).
            if UserDefaults.standard.bool(forKey: "autoMockLensFriend") {
                await pushes.received(FriendBanners.samplePush())
            }
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



