# DAT setup checklist (iOS) — verified 2026-09-26

Target: iOS (Xcode project `BirdJournal/BirdJournal.xcodeproj`, SwiftUI). Android is a non-goal.

## Tooling (Mac) — all verified present
- [x] Xcode 27.0 (27A266a), Swift 6.4, iOS 27.0 simulator runtime. SDK needs Xcode 26.4+ / Swift 6.3+.
- [x] Claude Code plugin `mwdat-ios@mwdat-ios-marketplace` v1.0.0 installed and enabled (17 skills).
- [x] Hosted docs MCP `https://mcp.developer.meta.com/wearables` registered by the plugin; `search_dat_docs` and `search_webapps_docs` answer queries. No auth needed.
- [x] iPhone 17 Pro connected to Xcode (UDID 00008150-001643C91E08401C).

## SDK prerequisites (to do when app code starts)
- [x] Add Swift Package `https://github.com/facebook/meta-wearables-dat-ios` at **1.0.0** (released 2026-09-24). Done in #2: pinned `exact: 1.0.0` in the app target and `BirdJournalKit`. Consumed through the fork
      `lightsailvr/meta-wearables-dat-ios` (same 1.0.0 revision) so Xcode Cloud can fetch it.
      Products by phase: `MWDATCore` + `MWDATMockDevice` (always); `MWDATCamera` (audio + camera);
      `MWDATDisplay` (lens cards); `MWDATInputs` (Neural Band nav/select/drag, experimental);
      `MWDATMockDeviceTestClient` (UI-test target only). `MWDATSpeech` (dictation of a bird's name on the lens,
      experimental) since #194, in the app and its unit tests.
- [x] Deployment target ≥ iOS 17.2. Decided: iOS 27.0 (DECISIONS.md), Swift 6 language mode, strict concurrency.
- [x] Bundle ID with **no dash** (DAT rejects `-`): `com.matthewcelia.mybirdjournal`.
- [x] Info.plist: URL scheme + `MWDAT` dict (`AppLinkURLScheme`, `MetaAppID` empty/0 for Dev Mode, `ClientToken`, `TeamID`),
      `UIBackgroundModes` = processing, bluetooth-central, bluetooth-peripheral, external-accessory (+ `audio` for mic;
      `processing` needs a non-empty `BGTaskSchedulerPermittedIdentifiers` or App Store Connect rejects the upload, ITMS-90771),
      `UISupportedExternalAccessoryProtocols` = com.meta.ar.wearable, `NSBluetoothAlwaysUsageDescription`,
      `NSLocalNetworkUsageDescription`, `NSBonjourServices` = _bonjour._tcp, `NSMicrophoneUsageDescription`.
      App Store Connect also wants `NSCameraUsageDescription` and `NSSpeechRecognitionUsageDescription` (ITMS-90683):
      the toolkit references those APIs. Since #186 the app does ask for the phone's camera, for "Capture a sighting",
      and the camera text says so. Since #194 the app does use speech: the toolkit's Speech capability hears a bird's name
      on the glasses, which recognise it themselves, so iOS's own speech-recognition question should never appear on a
      phone (Mock Device Kit's live source, the host's recogniser, is the one path that would ask). The text now says
      what the feature is instead of denying it; whether iOS ever shows it is on the #195 walk (step 16).
      Done in #3: `BirdJournal/Info.plist` (outside the synchronized source folder), merged with the generated keys.
- [x] `Wearables.configure()` at launch; `.onOpenURL` forwards links containing `metaWearablesAction` to `Wearables.shared.handleUrl`.
- [x] Wearables Developer Center: iOS integration created. Universal link field: not needed for Dev Mode; use custom scheme `birdjournal://` now, add an https universal link before Beta distribution.

## Meta AI app and glasses versions (SDK 1.0.0 row of the version matrix)
- [ ] Meta AI app (iOS) **v290+** — check App Store update.
- [ ] Meta Ray-Ban Display firmware **v128+** — Meta AI app > Devices > glasses > gear > General > About > Version.
- [ ] Neural Band paired (needed for select/nav on the lens).
- [ ] Speech enabled for the app in the Wearables Developer Center (#194: the DAT docs' Speech guide asks for it before the
      capability starts; experimental, so Dev Mode and the Beta channel only). Without it, expect the lens to go from
      "Say the bird's name" to "Photo saved" with "Speech unavailable" or "Speech error" in the glasses log.
- [ ] DAT glasses app installed on the Display glasses (Dev Mode screen has an Install button; wear the glasses, keep Meta AI open ~10 s, accept the Wi-Fi prompt).

## Developer Mode
- [ ] Meta AI app > Settings > App Info > tap App Version 5× > toggle Developer Mode on. Re-check after every firmware update (it resets).
- [ ] Only ONE third-party app can be registered at a time in Dev Mode; registering BirdJournal unregisters any other DAT test app.
- [ ] Internet required during registration; Bluetooth on.

## Mock Device Kit fallback (no glasses needed)
- [x] Simulator/phone run with `MockDeviceKit.shared.enable()` + `pairGlasses(model: .metaRayBanDisplay)` + `powerOn()/unfold()/don()`.
- [x] Lens preview inside the app: `mockDevice.services.display.createPreviewView()` (done in #4: the "Lens" screen embeds
      it while a mock is paired; taps via `sendClick(identifier:)` are unused, the card's button is verified on hardware).
      #7 drives the real pages on it: `-autoMockLens YES` starts the lens with three fake species and walks to the second
      species card; `-autoMockLensInputs "navLeft select"` walks any other sequence of mock input names for screenshots.
- [x] Inputs injection: `services.input.navDown()/select()/back()`; camera feed from an HEVC .mp4 or JPEG/PNG. Done in #4:
      Display and Inputs attach to one mock session; a `.metaRayBanDisplay` mock delivers `.nav`, `.select` and, unlike real
      glasses, `.back` (source `neuralBand`) within 100 ms of injection. Injection before Inputs is `.active` is dropped.
      Mock `powerOff()` ends the session on the device side (`.stopped` while running), so the "ended by the glasses"
      path has a mock test; the real two-finger tap still needs the hardware run below.
- [ ] Limit: no deterministic audio-frame injection. Test the identification engine with WAV files directly, not through the mock.
- [x] Found in #9: with a still-image feed the mock delivers no video frames at all. A video-only stream reaches `.streaming` and
      stays there without frames; an audio-enabled one reaches `.streaming` after about 6 s and stops with `StreamError.timeout`
      right away. Attaching Display and Inputs to the same session changes nothing. The run's frame capture is tested with a
      stand-in source (`ManualAudioSource` with a `CameraFrame`); the real stream's frames are verified on hardware.
- [x] Found in #9: `DeviceSessionError.sessionAlreadyExists` exists, so one device session per device. The run shares one session
      (`DeviceSessionLease.shared`) between camera, Display and Inputs.
- [x] Found in #3: an audio-enabled camera stream on the mock fails with `StreamError.videoStreamingError` unless
      `services.camera.setCameraFeed(fileURL:)` is given an image first. With a feed it reaches `.streaming`, then
      stops with `StreamError.timeout` a few seconds later (no audio frames). `AutoDeviceSelector` resolves its device
      asynchronously; creating a session before `activeDevice` is set fails with `noEligibleDevice`.
- [x] Found in #3: mock `doff()` does not pause the session or stream. Pause and resume are verified on hardware only.
- [x] Found in #10 (probe on the mock): `services.captouch.tap()` puts the session in `.paused` and a second tap returns it to
      `.started` (the toolkit's touchpad pause). `doff()` only sets `donState` to `.doffed`. `powerOff()` drops the link
      (`.disconnected`, then `.connecting`), publishes `unexpectedError("Session ended by device")` and stops the session,
      which is the order the hardware doff showed in phase A; `powerOn()` connects again and `don()` sets `.donned`, and a
      new session starts at once. So the run's pause and resume paths have mock tests (`GlassesInterruptionTests`).
- [x] Found in #3: permission checks throw `PermissionError.noDevice` until the device is linked; wait for a connected device.
- [x] Limit (found in #2): `MockDeviceKit.enable()` traps unless `Wearables.configure()` succeeded, and `configure()` throws
      `WearablesError.missingAppName/…Version/…BuildNumber` in a hostless test bundle. Mock-device tests must run in an
      app-hosted test target, not in `BirdJournalKit`. Loading `MWDATMockDevice` next to `MWDATCamera`/`MWDATDisplay` also
      logs many `objc[…]: Class … is implemented in both` duplicate-class warnings; they come from the SDK binaries.
- [x] Chrome "Meta Ray-Ban Display Simulator" extension previews the 600×600 additive display for layout checks. Done in #82:
      `BIRDJOURNAL_SIMULATOR=BJ-82 scripts/mock-lens-in-chrome.sh` builds, installs and launches the app with
      `-autoMockLens YES` and waits until the preview server answers on `127.0.0.1:9000`; the open tab then shows the
      lens. One simulator at a time (the simulators share the Mac's loopback); `--port` and `-mockPreviewPort` pick another.
- [x] **What the DAT 1.0 docs prescribe, against what we did** (checked in #82 with the `mockdevice-testing` and `debugging`
      skills and `search_dat_docs`: "Testing with Mock Device Kit (iOS)", "Display simulation", the
      `MockDeviceKitInterface` reference):
      - *Pair*: `enable()` (registered, permissions granted) then `pairGlasses(model:)`; the device shows in
        `Wearables.devices` only once powered on and unfolded, so wait for it before `createSession`. **We** waited for
        *any* connected device (`connection.connectedDevice != nil`), which a stale device from the previous test also
        satisfies. **Now** `withMockDisplay` waits until the paired device itself (`glasses.deviceIdentifier`) is connected.
      - *Teardown*: the docs' XCTest base class calls `await MockDeviceKit.shared.disable()`, and the reference prefers the
        async `disable()` and `unpairDevice(_:)` overloads because the sync ones race "fire-and-forget cleanup, a common
        source of flakiness when cycling enable/disable", adding that "the underlying stream I/O may still be closing on its
        background thread when this returns". **We** awaited `disable()` and went straight to the next test's `enable()`;
        four interruption tests also stopped their run from `defer { Task { await run.stop() } }`, so the stop ran after
        `disable()`. **Now** the teardown awaits `unpairDevice`, then `disable()`, then waits for `Wearables.devices` to
        empty and 300 ms more, and every run is stopped (awaited) before it.
      - *Don and power*: as documented (`powerOn()`, `unfold()`, `don()`); the docs' Chrome sample skips `unfold()`, which
        changes nothing for a Display.
      - *Test server*: `startTestServer(port: 9000)` after pairing, then `stopTestServer()` and `disable()` at the end, for
        Chrome; `startTestServer(portFilePath:)` on a system-assigned port plus `MWDATMockDeviceTestClient` for XCUITest
        to drive the mock from the test process. **We** start it only from the DEBUG `pairMockGlasses()` (same order;
        `unpairMockGlasses()` now also awaits `unpairDevice`). The unit suites start it only when asked
        (`BIRDJOURNAL_MOCK_PREVIEW_PORT`). In `BirdJournalUITests` only `SewingUITests`' glasses runs use the mock, inside the
        app (`-autoScreen glasses-run`, its inputs from the app's own `MockLensAdds`), each launch on a port of its own.
- [x] **Found in #82 (toolkit bug, worked around): the mock link wedges.** When a mock device is torn down and the next one
      paired while the old link's stream I/O is still closing, a toolkit thread (`MWDATCore`, one run-loop thread for the
      whole process) spins at 100% CPU in a single run-loop block calling `CFReadStreamRead` on a bound stream pair, and
      nothing in that process gets an answer over the mock link again. Seen as: every following lens test failing with
      "No connected display glasses." (the selector never sees the new device), permission checks that never return, and
      a test host that does not exit after the run. The CoreBluetooth "XPC connection invalid" lines are noise: passing
      runs log them on every `enable()`. Repro: `MockDeviceKitStressProbe` (40 cycles of pair, stream, teardown;
      `TEST_RUNNER_BIRDJOURNAL_MDK_STRESS=40`). With the old teardown the link wedged at cycle 7; with the settle (wait for
      the device list to empty, then 300 ms) 40 of 40 passed, with or without the unpair. Recovery once wedged: a new test
      host process (kill the run, `simctl shutdown` the simulator); the script's watchdog does this.

- [x] Found in #194 (Speech on the mock, `glasses.services.speech`, with the `speech` and `mockdevice-testing` skills and
      `search_dat_docs`): `session.addSpeech()` on the run's started session returns a `Speech` beside Display, Inputs and
      a stand-in stream, and `removeSpeech()` then `addSpeech()` again on the same session works, so one dictation can
      follow another ("Say it again"). After `start()` the state goes `.starting`, `.started`; `isListening` is true a
      moment later and false after `stop()`. `simulateTranscription(text:isFinal:confidence:)` arrives on
      `transcriptionPublisher` at once, partial or final (the docs: dropped while Speech is not listening).
      `simulateError(errorCode: 5, message:)` arrives on `errorPublisher` as an error that reads "Unexpected error" (the
      code is the recogniser's raw one, not a `SpeechError`). **`simulateCompletion()` reports nothing to the app**: no
      state change and no transcription, so a dictation the mock completes ends at the app's own silence limit, and
      Speech stopping by itself (`.stopped`, which the docs say real glasses do after inactivity or a timeout) cannot be
      staged; `DictationProgressTests` holds that path as a value. `removeSpeech()` on a session the glasses already
      ended throws "Session has already been stopped", which is harmless.
      `MockDeviceKit.shared.permissions.set(.microphone, .denied)` makes `checkPermissionStatus(.microphone)` answer
      `.denied` mid-session, and `setRequestResult` sets the request's answer.
      **Not on the mock**: a real voice, real partial results and their timing, whether Speech and the camera stream's
      audio coexist (the mock's stream carries no audio at all), and what the glasses do at the end of an utterance.

## Local verification steps (in order)
1. Build the untouched project for the simulator — baseline compiles.
2. Add package 1.0.0 + Info.plist keys; build again.
3. [x] Mock run: pair a mock Display device, send one FlexBox card, see it in the preview view. Done in #4 ("Lens" screen;
   launch the app with `-autoMockLens YES` to pair, start and inject two gestures without tapping). #24 sends the species
   list and the species cards and navigates them with injected nav, select and back. Clicking a details page's "Add to my
   list" button through the mock is not exercised; Select stands in for it.
4. [ ] Device run with Dev Mode: register from the app, accept in Meta AI, session reaches `.started`, Display shows the card on the lens.
   #4 adds the "Lens card" screen for this: start, swipe and tap with the Neural Band, watch the list on the phone, then
   two-finger tap to end from the glasses and check the run reads "Ended by the glasses".
5. [x] Audio spike: camera stream with `audioCodec: .pcm(sampleRate: .rate44100, numberOfChannels: 1)` at `.low`/2 fps; log frame cadence, latency and glasses battery over 20 min. Done 2026-09-26, results in DECISIONS.md "Phase A go/no-go".
   Found: glasses audio arrives as 1,024-sample chunks every ~23 ms at 44.1 kHz; presentation timestamps are not host time; the first chunk can be empty; a `StreamError` ("Critical error, the stream should end") can fire on backgrounding while the stream keeps delivering. Taking the Display glasses off ends the session (`DeviceSessionError` "Session ended by device") and drops the link; it does not pause. A new session is needed after they are put back on.
6. [ ] End-to-end run with Dev Mode (#9): "Listen with the glasses", pocket the phone, hear a bird, see the card within 6 s,
   swipe down to its details, tap "Add to my list", then check the Album count on the phone and that the sighting's frame file exists.
7. [ ] Lens UI probes (#24), on the glasses with the Neural Band, from the "Lens" screen with the fake stack:
   - [x] Scrolling: with Inputs attached the glasses do not scroll a tall card; swipe up/down reach the app (2026-09-27).
     Every send is one screenful: a species has a photo page and, on swipe down, a details page.
   - [x] Back: the middle-finger tap ends the session from any card; no Back event reaches the app (2026-09-27, and the
     Inputs docs' "Current limitations"). Swipe right on a card is the app's way back to the list.
   - [x] List focus: swipe down did not move the glasses' focus between tappable rows while Inputs was attached
     (2026-09-27); the app now moves the selection itself and re-sends the list.
   - [ ] Photo: is the 552 × 368 photo fully on the photo page with the name under it? If it is cut at the bottom, shrink
     the lens crop height in `packbuilder/src/packbuilder/crops.py` (`LENS_HEIGHT`) and rebuild the pack.
   - Select on the details page: does it click "Add to my list" (a Display click), arrive as an Inputs `select` (logged
     on the phone), or both? Either way one sighting must be written.
   - Record the answers in DECISIONS.md, "Lens UI".
8. [ ] Pause and disconnect (#10), from "Listen with the glasses" with the phone in a pocket:
   - Doff: take the glasses off for a minute. The phone should read "Paused: glasses off" within about 15 s (the glasses end
     the session themselves). Put them on: within about a minute the phone reads "Listening" again, the lens shows the page
     it was on, and the next bird call updates it. Note the time from don to "Listening".
   - Out of range: walk away from the phone until the link drops. The phone should read "Paused: glasses disconnected".
     Walk back: "Listening", and the lens shows "Connection lost" with swipe right back to the page.
   - Touchpad: tap the touchpad. Does the session pause (`.paused` on the phone, "Paused by the glasses")? Does a second tap
     resume it, and does the card come back on the lens?
   - Quit: two-finger tap. After the 2 s grace period the phone should read "Ended by the glasses", not paused.
   - Three cycles: Start, hear a bird, Stop, three times; the third works like the first.
   - Record the answers in DECISIONS.md, "Pause, disconnect and error handling".
9. [ ] The field journal's Listen tab (#28), which drives the same glasses run as step 8 from the normal app:
   - Listen tab, source row "Ray-Ban Display · Connected", Start listening: the title reads "Listening", the dot is green,
     the elapsed time ticks and the waveform moves with sound near the glasses. Lock the phone in a pocket; on return the
     time has kept counting and the species heard are listed in the order heard.
   - Add on the lens ("Add to my list"): the phone row shows the check and "Added to journal" and the summary counts it.
     Then tap Review on another row on the phone and Add to journal: the Journal shows one sighting with "Your glasses
     snapshot" (the frame from the moment of the phone tap), not two entries when the lens adds the same species later.
   - Switch to the Journal tab while listening: the strip above the tab bar shows the time and Stop; the run carries on.
   - Doff, out of range, touchpad and the two-finger quit as in step 8, read on the Listen tab: "Paused: glasses off",
     "Paused: glasses disconnected", "Paused by the glasses", "Ended by the glasses"; nothing reads paused after a quit.
   - Record the answers in DECISIONS.md, "The phone as a field journal".
10. [ ] A fresh location for every sighting (#44), on a walk with the phone locked in a pocket:
   - Start listening (either source), lock the phone, walk a quarter mile, add a bird, walk another quarter mile, add
     another. Open the second sighting's map card: the full map shows the two pins apart, not stacked where the walk began.
   - The blue location indicator shows in the status bar while the run is on, and is gone after Stop.
   - Battery: note the phone's and the glasses' drop over a 30-minute run against the #3 spike figures in DECISIONS.md
     "Phase A go/no-go"; live location on top of the audio stream should cost a few percent, not double it.
   - Record the answers in DECISIONS.md, "A fresh location for every sighting".
11. [ ] Reference clips on the lens (#41, phase 4), from "Listen with the glasses" with the phone in a pocket and the
   glasses connected to the phone as a Bluetooth audio device (they show in Control Center's audio route).
   First run (2026-10-10): the page read "Playing song…", so iOS routed the clip to the glasses' A2DP output, but
   nothing played on them or on the phone while the camera streamed. The clip now holds the stream: the camera
   comes off the session for the clip and goes back 1 s after it ends, the gap filled with silence.
   - Glasses speakers: open a species, swipe up to its sounds, tap. The song plays through the glasses' speakers, full
     range, not the phone's speaker; the sounds page reads "Playing song… tap to stop", not "Song on the phone…". If
     still silent, note it: the camera off the session was not enough (the next try is a stream with no audio codec).
   - Restart: about a second after the clip ends the waveform moves again and later birds still arrive. Note the time
     from the clip's end to the first chunk (the phone's stream state goes back to streaming), and whether the
     restart ever fails. Failed on the first hardware try (2026-10-10, listening never came back); now it waits for the
     old camera to stop and retries with a fresh one. `glasses-audio` in Console (filter on the subsystem
     `com.matthewcelia.mybirdjournal`) logs "holding the stream for a clip", then "stream back (attempt N)", or per
     attempt "stream restart, attempt N: …" and finally "the stream did not come back". Verified on the glasses the
     same day: listening came back after a clip.
   - Latency: time from the tap to the first sound, now including the stream stopping; and whether one tap arrives
     once (one Inputs select) or twice (the clip would start and stop at once; the Developer screen's input log
     shows each event).
   - Leak: play a clip with a bird the run has not heard. It must not appear on the list during the clip or in the
     1.5 s after (`AudioSuppression.defaultTail`); then play the same clip with the phone microphone as the source. If
     a species does appear, lengthen the tail and note by how much.
   - Dim: let a clip play out without touching anything. The page stays lit and goes back to "Tap: play its call" at
     the end (the 8 s clip is under the 20 s dim); note whether the end's re-send wakes a display that dimmed.
   - Stop: a swipe, swiping right to the list, a doff and the two-finger quit each stop the clip at once.
   - Misread swipes: swipe down on a photo page a dozen times. Nothing plays, whatever the band reads.
   - Record the answers in DECISIONS.md, "Reference sounds in the packs".
12. [ ] The viewfinder (2026-10-10; fast camera since #46, 2026-10-25), from "Listen with the glasses":
   - "Add to my list" opens the viewfinder at once on the listening stream's frames (360×640, 2 fps): no stream
     switch, no "Waiting for the camera…" unless a clip just took the camera off. Note the time from the press to
     the first picture, and from a tap to "photo taken in N s" in the camera log.
   - The camera log is also a file now: after the walk, pull it with
     `xcrun devicectl device copy from --device <udid> --domain-type appDataContainer --domain-identifier
     com.matthewcelia.mybirdjournal --source "Library/Application Support/Logs/glasses-<yyyy-MM-dd>.log"
     --destination <path>`.
   - The crop box: what sits inside the white frame is what the journal's picture shows. Check that against the
     sighting; if the stream's field of view differs from the photo's, the box is off and needs scaling.
   - One press of "Add to my list": the viewfinder opens and stays (a doubled press, click and select, takes no photo).
   - A tap takes the photo in the stream (the standalone full-resolution still is off since #46: it failed on every
     hardware try, 2026-10-10 and 2026-10-25). The stored file is about 1080×1440 and the stream stays on for it; a
     failure logs "photo not taken …" and the sighting keeps the stream frame from the tap (360×640).
   - Listening survives a walk of adds and clips: after several of each, back on the species list, new birds still
     come in. A stream that died logs "stream down at the species list (…): restarting", then "stream back".
   - A swipe adds the bird without a photo; the journal shows the pack's photo for it.
   - Add the same bird again ("Add another" on its details page): the journal has two sightings of it, and the
     details page reads "New card" (issue #51; see step 13).
   - Record the answers in DECISIONS.md, "Sounds page and viewfinder".
13. [ ] Cards on the lens (issue #51), from "Listen with the glasses" with a species the journal does not have yet:
   - Add it: back on the details page the saved line reads "Your first <species>" with a star, within a second or two
     of the photo (the line names the card once the sighting is written; "Added to my list" shows until then).
   - "Add another": the line reads "New card" with a check. The phone's Cards view shows both, the first framed gold.
   - A long name ("Your first Northern Rough-winged Swallow") fits on one line or wraps without pushing the button
     off the page; the field marks above give way.
   - Record the answers in DECISIONS.md, "Every sighting is a card".
14. [ ] The friend banner on the lens (issue #67), a Debug build signed in, from "Listen with the glasses". Settings →
   Developer → Friend banner has two buttons that each act 10 s after the tap, time to set up the page or lock the phone.
   - **Shown, held, replaced, dismissed** ("Friend's find on the lens in 10 s", which hands the push center a notable push
     as if APNs had delivered it): on the species list or a photo page the lens shows "A friend's find" / "Maya heard a
     Black Phoebe · Pasadena" / "Tap or swipe right to close" within a second. A tap dismisses it; again, and a swipe
     right does. Tap the button, then open a details page (or the viewfinder, or a sounds page with a clip playing):
     nothing shows there; swipe back to the photo page and the banner is there. Two taps of the button 5 s apart while
     on a details page show only one banner on return. Record whether the banner reads at a glance and fits one screen.
   - [ ] **Does a backgrounded glasses run get the push in time?** Needs the deploy, the APNs key (`push-wizard.sh`) and
     this phone's token on the account (Circles → create or join a circle → allow notifications). Start "Listen with the
     glasses", sit on the species list, lock the phone and pocket it. Then either run `WIZARD_FROM=5
     infra/scripts/push-wizard.sh` and send the test push to this phone's token (Settings → Developer → Push token; the
     test push carries a find, so it makes the banner), or have a second account in a shared circle add a species it has
     never added (a new patch, so notable). Note the time the push is sent and the time the banner appears on the lens.
     Repeat three times, once after 10+ minutes locked. Record in DECISIONS.md, "Friend banner on the lens": every delay,
     any push that never made a banner, and whether the phone's own notification arrived meanwhile (iOS can throttle
     background pushes; the banner needs the app to wake for `content-available`).
   - [ ] **Do the glasses mirror an ordinary iOS notification?** With the glasses on and connected (no run needed, then
     again during a glasses run), tap "Post a local notification in 10 s" and lock the phone. Record whether "Maya Ortiz
     found a Black Phoebe" appears on the glasses' display by itself (Meta AI app → Devices → notifications settings may
     list Bird Journal; note what it says), and if it does, whether it covers or interrupts the app's lens pages. If the
     glasses mirror it, a friend's push may show twice on the lens (the system's copy and the banner): record it, and
     DECISIONS.md decides whether the banner stays.
15. [ ] Capture a sighting from the lens (issue #193; the hardware walk is #195), from "Listen with the glasses":
   - **The row.** Before any bird is heard the species list reads "No species yet", "Birds appear as they call." and a
     highlighted "Capture a sighting" row. With birds on it the row is above the first bird and the highlight is on the
     first bird; one swipe up moves it to the row, a swipe down or right moves it back. Record whether the row's
     icon (the viewfinder's four corners) reads as one, and whether a full page (the row and five birds, with
     "Page 1 of 2." on the hint line; six species heard) fits the lens without anything cut at the bottom. On the mock
     it takes about 500 of the 600 pixels.
   - **The viewfinder.** A tap on the highlighted row opens it on the listening stream's frames with the journal's crop
     frame, "Capture a sighting" and "Tap: take the photo · swipe right: back". One tap on the row opens it and it
     stays: nothing is taken by the same tap (the echo window, as for "Add to my list"). A swipe returns to the list and
     nothing appears on the phone.
   - **The photo.** A tap on the viewfinder shows "Saving the photo…", then "Photo saved" / "Name it on your phone.".
     Note the time between the two (the in-stream photo crosses Bluetooth; `photo taken in N s` in the camera log). On
     the phone the photo is under "Seen this run" as "Unnamed sighting · Your photo" while the run is on, in the run's
     review after Stop, and under "To name" in the Collection. Name it there: its page says "Seen, photographed with
     Ray-Ban Display", with the place of the walk and the time of the tap.
   - **No photo.** If a tap lands while the camera is off (right after a clip, or with the stream down), the lens shows
     "No photo taken" and nothing is on the phone. Record whether it happens when the viewfinder was showing a picture.
   - **Interruptions.** Take the glasses off with the capture viewfinder open and put them back on: the viewfinder is
     back and still waits for a tap. With the phone's Developer tools, send a friend's find while on the viewfinder: it
     shows only once back on the list.
   - Record the answers in DECISIONS.md, "Seen birds: capture a sighting from the lens".

16. [ ] Say the bird's name on the lens (issue #194; the hardware walk is #195), a Debug build, from "Listen with the
   glasses". Everything here was built against Mock Device Kit's injected transcriptions; none of it has heard a voice.
   The glasses log (the Developer screen's glasses run, Console category `glasses-audio`, and the day's file, step 12)
   says what Speech did: "dictation: listening", "dictation: Speech started" and each later state, then
   `dictation: heard "<words>"` (the words only in a Debug build), or "nothing heard in time", "Speech stopped with
   nothing heard", "Speech error: …", "Speech unavailable: …".
   - **Before the walk**: Speech is enabled for the app in the Wearables Developer Center (above). The glasses'
     microphone permission is the one the run already asks for at Start, so nothing new is asked in Meta AI.
   - **Does Speech run beside the camera stream?** (#185's first open question.) Take a photo from the lens: "Capture a
     sighting", a tap, a tap. After "Saving the photo…" the lens reads "Say the bird's name" with the photo and
     "Listening…". Say "Black Phoebe". Record whether the words appear, whether the birds are listed, and the log lines.
     - If the lens always ends on "Photo saved" (the log says a Speech error, unavailable, or nothing heard) with the
       stream on: Settings → Developer → "Dictation on the lens" → turn **off** "Keep the camera stream on while saying a
       name", and take another photo. The log then reads "holding the stream for a dictation" before "dictation:
       listening", and "stream restart" / "stream back" after. Record which setting hears a name. With it off, record how
       long listening is away (the phone's waveform is flat) and whether the stream ever fails to come back.
     - If it works with the stream on: does the phone's waveform keep moving during a dictation, and does the wearer's
       own voice ever put a bird on the species list (the run is still listening, and nothing suppresses it)?
     - Either way, record the answer in DECISIONS.md and set the switch's default to match
       (`DictationSettings.keepsStreamByDefault`: a Release build never reads the Developer screen's toggle, so the
       default in code is what ships).
   - **Partial and final words.** Do words appear while speaking (partial results), and does a final result come by
     itself at a pause? If no final ever comes, the lens takes the words as final 3 s after the last one
     (`GlassesDictation.Limits.pause`): record the wait from the end of the name to the birds, and whether 3 s is right.
     Say nothing: the lens gives up after 8 s (`Limits.silence`) and reads "Photo saved". Record whether Speech stops by
     itself sooner ("Speech stopped with nothing heard"). Say "Anna's humming" and stop: a name cut off part way through
     a word should still offer its bird (the review of #185).
   - **What the recogniser writes.** Say ten birds of the walk, among them Anna's Hummingbird, Black Phoebe, California
     Towhee, Bushtit, Lesser Goldfinch, Red-tailed Hawk, Mourning Dove, and one outside the field guide. For each, note
     what the log says was heard and whether the bird was the first of the three offered, in the three, or missing. A
     name that is never found goes into `SpokenNameTests` as it was written, and the matcher is fixed there.
   - **The pages.** The birds' page (the "You said" line, three birds, "Say it again", "Name it later", the hint) fits the
     lens; on the mock it is about 420 of the 600 pixels, and "Say the bird's name" with its photo about 450. "New
     patch" is beside a bird you have no patch of here and not beside one you have. Swipe down and up move the highlight and stop at the ends; a tap on a bird shows "Added", the
     bird, "Seen", the set (no such line outside every set), and "New patch, sewn on your phone." or "Seen again · N
     times". "Say it again" listens again
     (does Speech come back on the same session every time?). "Name it later", and a tap while the lens listens, read
     "Photo saved" / "Name it on your phone.". Words no bird answers to read "No bird by that name".
   - **Echoed taps.** A tap that lands within a second of the press that opened "Say the bird's name" (after "Say it
     again"), "Photo saved" or "Added" is taken for that press again and dropped, as on the viewfinders. Record whether
     a select on a row is ever delivered twice (the Developer screen's input log), and whether a deliberate second tap
     ever feels swallowed.
   - **The phone gets there first.** With the birds listed on the lens, name the photo on the phone (its row under
     "Seen this run"), then tap a bird on the lens: it reads "Nothing to name" / "That photo was named or deleted on
     your phone.", and swipe right is the list.
   - **On the phone.** While the run is on, the named photo is under "Seen this run" with the bird's name and nothing
     else happens on the phone. After Stop the stitch-in of a new patch plays once, as for an add on the lens. The
     sighting's page says "Seen, photographed with Ray-Ban Display", at the place and time of the photo. Its photo is
     shown at the journal's crop on its row, in "Name this bird" and on its page ("Your glasses snapshot"): check that
     the bird sits where the viewfinder's frame had it, and that "View original photo" shows the whole frame.
   - **Without the permission.** If Meta AI lets the microphone be taken away while a run is on, do it and take a photo:
     the lens goes straight to "Photo saved", and the run's page on the phone shows "Say the bird's name on your glasses"
     with "Allow in Meta AI", which opens Meta AI. If it cannot be taken away mid-run, record that: the offer then never
     shows, since Start itself asks for the same permission.
   - **A doff while the lens listens**: the lens comes back on "Photo saved", and the photo is on the phone.
   - **iOS's speech-recognition question** never appears on the phone. If it does, note when, and the wording shown.
   - Record the answers in DECISIONS.md, "Seen birds: say the bird's name on the lens".

## Facts that change the spec (see grill questions)
- No standalone microphone capability. Ambient audio only arrives in-band on a **camera stream** (experimental, dev/beta channels only). HFP is 8 kHz mono and beamformed to the wearer's voice — useless for birdsong.
- Inputs (Neural Band events), camera audio, photo capture, motion and speech are all **experimental**: usable in Dev Mode and the Beta channel, not publishable to production yet.
- Web Apps for Display have **no camera and no microphone** — they cannot host the core loop.
- Display: one root `FlexBox` per `send`, 600×600 additive display, images from bundled `UIImage` or HTTPS. A bundled image
  takes its pixel size in the layout (`ImageSize` is only `.icon` or `.fill`), so lens crops are cut to 552 × 368, the
  card's width under its padding (#24); the root `FlexBox` needs `.alignSelf(.stretch)` to span the canvas width. Tall
  views scroll vertically per the docs ("Views are presented one at a time with vertical scrolling"); any `FlexBox`
  takes `.onTap` and the Neural Band moves focus between tappable elements with Nav and activates with Select.
