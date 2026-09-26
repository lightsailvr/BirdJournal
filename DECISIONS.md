# BirdJournal — design decisions (grill sessions, 2026-09-26)

Source of truth for choices made on top of `spec.md`. Where this file and the spec disagree, this file wins.

## Product
- Glasses-first. The lens is the primary UI; the phone gets a minimal screen in phase D and social features later (out of scope).
- Personal project, published personally. Only the latest iOS is supported: deployment target iOS 27, Swift 6 language mode, Xcode 27.
- Android: out of scope. Web-app path: dropped (Web Apps have no mic or camera).

## Toolkit facts that shape the design
- Ambient audio only arrives in-band on a camera stream (`StreamConfiguration(audioCodec: .pcm(...))`). HFP is 8 kHz and beamformed to the wearer's voice; not usable.
- Camera audio, Inputs, photo capture, motion, speech and voice invocations are experimental in SDK 1.0.0: Dev Mode and Beta channel only.
- Real glasses do not deliver the Back event; the two-finger temple tap always ends the display session. Root view + system Back = quit.
- Display: one root `FlexBox` per `send`, 600×600 additive display, no scrolling, dims and sleeps on inactivity. Images from bundled `UIImage` work offline.
- Only one third-party app can be registered in Dev Mode at a time. Bundle IDs may not contain `-`.
- MockDeviceKit cannot inject audio frames; sound-ID tests run on recorded files.

## Audio and identification
- Glasses stream: camera at `.low` resolution, lowest frame rate, audio PCM mono. Sample rate chosen in the phase A spike (44.1 or 48 kHz, resampled to the model rate).
- Video frames are not used for identification. The most recent frame at confirm time is stored with the sighting; the camera-assist re-ranker is out of scope.
- Model: BirdNET+ V3.0 preview 3.1 (11,560 species, 32 kHz input, CC BY-SA 4.0 weights, "Powered by BirdNET" attribution). Pinned to the exact Zenodo file. Engine sits behind a protocol so v2.4 can be swapped in.
- Geo prior: BirdNET geomodel v3.0.4 (Apache-2.0), raw lat/lon/week input, used as a pre-filter with the reference threshold 0.03. No GBIF/H3 tables in v1.
- Runtime: ONNX Runtime via the official Swift package (`microsoft/onnxruntime-swift-package-manager`). Core ML conversion is a later optimization, not a dependency.
- Audio source is a protocol with three implementations: glasses stream, phone mic, WAV file (tests).
- Windows: 3 s with 1.5 s overlap; a species enters the stack after two windows above threshold. Thresholds tuned in phase B.
- Ring buffer exists only for live playback. No audio is saved to the album.
- Location: "when in use" permission; one fix at session start, refresh every 10 min; no background location mode.
- Background: the app must keep listening with the phone locked (audio + processing + Bluetooth background modes). Verified in phase A.

## Lens UI
- Gestures: swipe = Nav, tap = Select. Swipe up = in-app back. Two-finger tap = quit (system). Nested Back handler written behind `consumeBack: true` for when hardware delivers Back.
- Page map: Listening (root, "N species heard", updates on each new species and wakes the display) → swipe L/R between species photo pages → swipe down: description page (field marks, size, habitat, one-line photo credit) → swipe up: back to photo. Tap on a photo = confirm → info page with Save as the primary action.
- Stack never reorders while on a photo page; new species append at the end.
- Photo-first cards: close-up crops with dark backgrounds preferred. Text ≤ ~40 words per page.
- Audio chirp on new candidate: off by default.
- Session start: phone button in v1; "Hey Meta, start BirdJournal" once the Developer Center approves Voice Invocation.

## Species pack
- Region v1: Los Angeles area, ~150 species with photos and descriptions. All BirdNET species remain identifiable by name.
- LA pack bundled in the app binary (offline on first launch). Other packs downloaded from GitHub Releases via a JSON index into app storage.
- Pack = zip of SQLite + pre-sized JPEGs (lens ~600 px, phone ~1200 px).
- Pack builder (Python) adds a detector step (COCO "bird") to crop close-ups, scores crops on bird area, background luminance and sharpness, keeps top 3–5 per species, with a manual override list.
- Photo licenses: CC0, CC BY and CC BY-NC. Every photo carries observer, license and source URL. Credit shown on the description page and in a full credits screen on the phone.

## Identity and distribution
- Bundle ID `com.matthewcelia.birdjournal`, personal Apple team. Working name BirdJournal.
- URL scheme `birdjournal://` for Meta AI callbacks in Dev Mode. A universal link (https domain with an apple-app-site-association file) is only needed for Beta/production distribution; set up later.
- Wearables Developer Center integration exists (created by Matt). Permissions to request: Camera, Audio Streaming, Inputs, Voice Invocation.
- Repo: outer `BirdJournal/` folder becomes the git root (app, `packbuilder/`, docs, spec). License MIT for our code; pack and models carry their own licenses.
- BirdNET permission email: optional with V3.0's CC BY-SA license; Matt may still send it.

## Phases
- A: DAT skeleton — register, session, one card on the lens, Nav/Select echo, 20-minute audio + battery spike with the phone locked. Go/no-go.
- B: BirdNET engine on device with file-fed tests. Test clips: Matt's own labeled recordings (format specified at phase start).
- C: cards from the LA pack, confirm and save to SwiftData.
- D: minimal phone screen — connect, start/stop, live list, album list.
