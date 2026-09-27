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
- Glasses stream: camera at `.low` resolution, lowest frame rate, audio PCM mono. Sample rate 44.1 kHz (chosen in the phase A spike), resampled to the model rate.
- Video frames are not used for identification. The most recent frame at confirm time is stored with the sighting; the camera-assist re-ranker is out of scope.
- Model: BirdNET+ V3.0 preview 3.1 (11,560 species, 32 kHz input, CC BY-SA 4.0 weights, "Powered by BirdNET" attribution). Pinned to the exact Zenodo file. Engine sits behind a protocol so v2.4 can be swapped in.
- Geo prior: BirdNET geomodel v3.0.4 (Apache-2.0), raw lat/lon/week input, used as a pre-filter with the reference threshold 0.03. No GBIF/H3 tables in v1.
- Runtime: ONNX Runtime via the official Swift package (`microsoft/onnxruntime-swift-package-manager`), consumed through the fork `lightsailvr/onnxruntime-swift-package-manager` so Xcode Cloud can fetch it. Core ML conversion is a later optimization, not a dependency.
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
- Bundle ID `com.matthewcelia.mybirdjournal`, personal Apple team. Working name BirdJournal.
- URL scheme `birdjournal://` for Meta AI callbacks in Dev Mode. A universal link (https domain with an apple-app-site-association file) is only needed for Beta/production distribution; set up later.
- Wearables Developer Center integration exists (created by Matt). Permissions to request: Camera, Audio Streaming, Inputs, Voice Invocation.
- Repo: outer `BirdJournal/` folder becomes the git root (app, `packbuilder/`, docs, spec). License MIT for our code; pack and models carry their own licenses.
- BirdNET permission email: optional with V3.0's CC BY-SA license; Matt may still send it.

## Phases
- A: DAT skeleton — register, session, one card on the lens, Nav/Select echo, 20-minute audio + battery spike with the phone locked. Go/no-go.
- B: BirdNET engine on device with file-fed tests. Test clips: Matt's own labeled recordings (format specified at phase start).
- C: cards from the LA pack, confirm and save to SwiftData.
- D: minimal phone screen — connect, start/stop, live list, album list.

## Phase A go/no-go (issue #3) — GO, 2026-09-26
Run: glasses source, 44.1 kHz mono, `.low` at 2 fps, iPhone 17 Pro locked in a pocket, 19 min 45 s (`spike-20260926-193507.log`).
- Sample rate: **44.1 kHz**. 48 kHz is untested: the first attempt stalled on the Meta AI microphone grant, not on the rate.
- Coverage: 1,182.0 s of audio in 1,185.2 s of wall time (99.7 %; the shortfall is stream startup). Zero gaps over 2 s. Chunks every 23.2 ms on average (1,024 samples); the longest interval between chunks was 671 ms.
- Latency above best: 39–89 ms mean per 30 s interval, 689 ms worst. No upward drift over the run, so the link does not back up. Absolute glasses latency is unknown: presentation times are not on the phone's host clock (first offset 882,188 s).
- Glasses battery 100 → 88 % (about 0.6 %/min, so roughly 2.5–3 h of listening from full). Glasses thermal `none` throughout. Phone battery 65 → 65 %, thermal `nominal`.
- Background: status lines kept arriving every 30 s while locked (`background_locked` for 37 of 40 intervals). The Bluetooth and external-accessory modes are enough; no `AVAudioSession` is needed on the glasses path.
- One `stream_error "Critical error, the stream should end"` arrived 2 s after the app went to the background, but the stream kept `streaming` and audio never stopped. Watch for it; do not stop the source on stream errors alone.
- The first audio chunk after `streaming` was empty (0 samples); consumers must tolerate empty chunks.
- Doff does **not** pause (`spike-20260926-195716.log`): 12 s after taking the glasses off, the device ended the session (`session_error "Session ended by device"`, session and stream `stopped`) and the link dropped. After putting them back on, the glasses were `donned` and `connected` within about 35 s, but the session stayed stopped and no audio returned. The app must start a new session itself once the glasses are worn and connected again; waiting for `.paused` → `.started` never happens. Touchpad-tap pause is still untested.
- Verdict: **GO** for the audio path: continuous, survives a locked phone, and costs about 12 % glasses battery per 20 minutes. Follow-up needed: automatic session restart after doff/don (the listening session must survive taking the glasses off).
