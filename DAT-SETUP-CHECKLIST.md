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
      `MWDATMockDeviceTestClient` (UI-test target only).
- [x] Deployment target ≥ iOS 17.2. Decided: iOS 27.0 (DECISIONS.md), Swift 6 language mode, strict concurrency.
- [x] Bundle ID with **no dash** (DAT rejects `-`): `com.matthewcelia.mybirdjournal`.
- [x] Info.plist: URL scheme + `MWDAT` dict (`AppLinkURLScheme`, `MetaAppID` empty/0 for Dev Mode, `ClientToken`, `TeamID`),
      `UIBackgroundModes` = processing, bluetooth-central, bluetooth-peripheral, external-accessory (+ `audio` for mic;
      `processing` needs a non-empty `BGTaskSchedulerPermittedIdentifiers` or App Store Connect rejects the upload, ITMS-90771),
      `UISupportedExternalAccessoryProtocols` = com.meta.ar.wearable, `NSBluetoothAlwaysUsageDescription`,
      `NSLocalNetworkUsageDescription`, `NSBonjourServices` = _bonjour._tcp, `NSMicrophoneUsageDescription`.
      App Store Connect also wants `NSCameraUsageDescription` and `NSSpeechRecognitionUsageDescription` (ITMS-90683):
      the toolkit references those APIs even though the app never asks for either permission.
      Done in #3: `BirdJournal/Info.plist` (outside the synchronized source folder), merged with the generated keys.
- [x] `Wearables.configure()` at launch; `.onOpenURL` forwards links containing `metaWearablesAction` to `Wearables.shared.handleUrl`.
- [x] Wearables Developer Center: iOS integration created. Universal link field: not needed for Dev Mode; use custom scheme `birdjournal://` now, add an https universal link before Beta distribution.

## Meta AI app and glasses versions (SDK 1.0.0 row of the version matrix)
- [ ] Meta AI app (iOS) **v290+** — check App Store update.
- [ ] Meta Ray-Ban Display firmware **v128+** — Meta AI app > Devices > glasses > gear > General > About > Version.
- [ ] Neural Band paired (needed for select/nav on the lens).
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
- [ ] Chrome "Meta Ray-Ban Display Simulator" extension previews the 600×600 additive display for layout checks.

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
   glasses connected to the phone as a Bluetooth audio device (they show in Control Center's audio route):
   - A2DP beside the stream: open a species with clips, tap. The song plays through the glasses' speakers, full range,
     not the phone's speaker, while the camera stream's audio keeps coming (the waveform moves, later birds still
     arrive). The photo page reads "Playing song… tap to stop", not "Song on the phone…". If it reads "on the phone",
     the route was not `.bluetoothA2DP`: note what Control Center shows. Record whether A2DP and the DAT stream share.
   - Latency: time from the tap to the first sound; and whether one tap arrives once (one Inputs select) or twice (the
     clip would start and stop at once; the Developer screen's input log shows each event).
   - Leak: play a clip with a bird the run has not heard. It must not appear on the list during the clip or in the 1.5 s
     after (`AudioSuppression.defaultTail`); then play the same clip with the phone microphone as the source. If a
     species does appear, lengthen the tail and note by how much.
   - Dim: let a clip play out without touching anything. The page stays lit and goes back to "Tap: its call" at the end
     (the 8 s clip is under the 20 s dim); note whether the end's re-send wakes a display that dimmed.
   - Stop: a swipe, swiping right to the list, a doff and the two-finger quit each stop the clip at once.
   - Record the answers in DECISIONS.md, "Reference sounds in the packs".

## Facts that change the spec (see grill questions)
- No standalone microphone capability. Ambient audio only arrives in-band on a **camera stream** (experimental, dev/beta channels only). HFP is 8 kHz mono and beamformed to the wearer's voice — useless for birdsong.
- Inputs (Neural Band events), camera audio, photo capture, motion and speech are all **experimental**: usable in Dev Mode and the Beta channel, not publishable to production yet.
- Web Apps for Display have **no camera and no microphone** — they cannot host the core loop.
- Display: one root `FlexBox` per `send`, 600×600 additive display, images from bundled `UIImage` or HTTPS. A bundled image
  takes its pixel size in the layout (`ImageSize` is only `.icon` or `.fill`), so lens crops are cut to 552 × 368, the
  card's width under its padding (#24); the root `FlexBox` needs `.alignSelf(.stretch)` to span the canvas width. Tall
  views scroll vertically per the docs ("Views are presented one at a time with vertical scrolling"); any `FlexBox`
  takes `.onTap` and the Neural Band moves focus between tappable elements with Nav and activates with Select.
