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
      `UIBackgroundModes` = processing, bluetooth-central, bluetooth-peripheral, external-accessory (+ `audio` for mic),
      `UISupportedExternalAccessoryProtocols` = com.meta.ar.wearable, `NSBluetoothAlwaysUsageDescription`,
      `NSLocalNetworkUsageDescription`, `NSBonjourServices` = _bonjour._tcp, `NSMicrophoneUsageDescription`.
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
      #7 drives the real pages on it: `-autoMockLens YES` starts the lens with three fake species and walks to a description
      page; `-autoMockLensInputs "navLeft select"` walks any other sequence of mock input names for screenshots.
- [x] Inputs injection: `services.input.navDown()/select()/back()`; camera feed from an HEVC .mp4 or JPEG/PNG. Done in #4:
      Display and Inputs attach to one mock session; a `.metaRayBanDisplay` mock delivers `.nav`, `.select` and, unlike real
      glasses, `.back` (source `neuralBand`) within 100 ms of injection. Injection before Inputs is `.active` is dropped.
      Mock `powerOff()` ends the session on the device side (`.stopped` while running), so the "ended by the glasses"
      path has a mock test; the real two-finger tap still needs the hardware run below.
- [ ] Limit: no deterministic audio-frame injection. Test the identification engine with WAV files directly, not through the mock.
- [x] Found in #3: an audio-enabled camera stream on the mock fails with `StreamError.videoStreamingError` unless
      `services.camera.setCameraFeed(fileURL:)` is given an image first. With a feed it reaches `.streaming`, then
      stops with `StreamError.timeout` a few seconds later (no audio frames). `AutoDeviceSelector` resolves its device
      asynchronously; creating a session before `activeDevice` is set fails with `noEligibleDevice`.
- [x] Found in #3: mock `doff()` does not pause the session or stream. Pause and resume are verified on hardware only.
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
   launch the app with `-autoMockLens YES` to pair, start and inject three gestures without tapping). #7 sends every lens
   page (listening, photo, description, confirm, saved) and navigates them with injected nav, select and back. Clicking
   the confirm page's Save button through the mock is not exercised; Select stands in for it.
4. [ ] Device run with Dev Mode: register from the app, accept in Meta AI, session reaches `.started`, Display shows the card on the lens.
   #4 adds the "Lens card" screen for this: start, swipe and tap with the Neural Band, watch the list on the phone, then
   two-finger tap to end from the glasses and check the run reads "Ended by the glasses".
5. [x] Audio spike: camera stream with `audioCodec: .pcm(sampleRate: .rate44100, numberOfChannels: 1)` at `.low`/2 fps; log frame cadence, latency and glasses battery over 20 min. Done 2026-09-26, results in DECISIONS.md "Phase A go/no-go".
   Found: glasses audio arrives as 1,024-sample chunks every ~23 ms at 44.1 kHz; presentation timestamps are not host time; the first chunk can be empty; a `StreamError` ("Critical error, the stream should end") can fire on backgrounding while the stream keeps delivering. Taking the Display glasses off ends the session (`DeviceSessionError` "Session ended by device") and drops the link; it does not pause. A new session is needed after they are put back on.

## Facts that change the spec (see grill questions)
- No standalone microphone capability. Ambient audio only arrives in-band on a **camera stream** (experimental, dev/beta channels only). HFP is 8 kHz mono and beamformed to the wearer's voice — useless for birdsong.
- Inputs (Neural Band events), camera audio, photo capture, motion and speech are all **experimental**: usable in Dev Mode and the Beta channel, not publishable to production yet.
- Web Apps for Display have **no camera and no microphone** — they cannot host the core loop.
- Display: one root `FlexBox` per `send`, 600×600 additive display, images from bundled `UIImage` or HTTPS. A bundled image
  takes its pixel size in the layout (`ImageSize` is only `.icon` or `.fill`), so size lens crops to about 260 px for a
  photo-beside-text card; the root `FlexBox` needs `.alignSelf(.stretch)` to span the canvas width.
