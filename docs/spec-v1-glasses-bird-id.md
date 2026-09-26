# BirdJournal v1 — Bird identification on Meta Ray-Ban Display

Status: ready-for-agent · 2026-09-26 · Synthesized from `spec.md`, `DECISIONS.md` and three grill rounds.

## Problem Statement

When I hear a bird while wearing my Meta Ray-Ban Display glasses, I want to know what it is without pulling out my phone, opening Merlin and looking down. Existing bird ID apps live entirely on the phone. The glasses have microphones, a lens display and a Neural Band, but no app uses them for birding. I also bird in places with no cell service, so anything that depends on the network is useless in the field.

## Solution

An iOS app that turns the glasses into the ears and eyes of a bird identifier. The user starts a listening session from the phone and puts it in a pocket. The glasses stream microphone audio to the phone, where BirdNET identifies likely species filtered by location and week. The lens shows one bird at a time as a photo-first card; the user swipes between species, swipes down to read how to tell the bird apart, taps to confirm what they see, and saves the sighting to a local album. Everything works offline with the bundled Los Angeles species pack.

## User Stories

### Setup and connection
1. As a birder, I want the app to register itself with the Meta AI app on first launch, so that my glasses trust it.
2. As a birder, I want to see whether my glasses are connected, compatible and registered on the phone screen, so that I know why a session cannot start.
3. As a birder, I want the app to tell me when the glasses firmware or the DAT glasses app needs updating and open the update flow, so that I am not stuck guessing.
4. As a birder, I want the app to ask for camera and microphone permission through the Meta AI app only after explaining why, so that the hand-off does not surprise me.
5. As a birder, I want the app to remember that I am registered across launches, so that I do not repeat the flow.

### Listening
6. As a birder, I want to start a listening session with one tap on the phone, so that I can pocket the phone and look up.
7. As a birder, I want listening to keep running while the phone is locked in my pocket, so that the glasses do all the work.
8. As a birder, I want the lens to show "Listening" and how many species have been heard, so that I know the app is alive.
9. As a birder, I want the lens to wake and update when a new species is detected, so that I do not miss a bird while the display is asleep.
10. As a birder, I want a species to appear only after it has been heard convincingly more than once, so that the stack is not full of noise.
11. As a birder, I want candidates ranked by confidence and filtered by my location and the week of the year, so that implausible species do not show up.
12. As a birder, I want a species already in the stack to keep its position when its score changes, so that the card I am looking at does not move under me.
13. As a birder, I want the session to pause when I take the glasses off or tap the touchpad and resume when I put them back on or tap again, so that the toolkit's pause behavior does not look like a crash.
14. As a birder, I want to stop the session with the two-finger back gesture from the listening page or from the phone, so that ending is always one action away.
15. As a birder, I want the glasses stream at its lowest video setting, so that battery lasts a morning walk.
16. As a birder, I want to fall back to the phone microphone when no glasses are connected, so that I can still test and use the app.

### Cards on the lens
17. As a birder, I want to swipe left and right between candidate species, so that I can compare what I hear with the likely birds.
18. As a birder, I want each species card to lead with a close-up photo and the common name, so that I can match the bird by sight in under two seconds.
19. As a birder, I want the confidence shown on the card, so that I know how much to trust it.
20. As a birder, I want to swipe down to a description page with field marks, size and habitat, so that I can confirm subtle differences.
21. As a birder, I want the description page to credit the photographer in one line, so that the people who took the photos are recognized.
22. As a birder, I want to swipe up from the description to return to the photo, so that navigation is reversible.
23. As a birder, I want to swipe up from a photo page to return to the listening page, so that I can check the count and come back.
24. As a birder, I want no page to require scrolling or more than about forty words, so that everything is readable at a glance.
25. As a birder, I want photos with dark backgrounds preferred, so that they stay legible on the additive display.
26. As a birder, I want new species to append to the end of the stack, so that my current position is not disturbed.
27. As a birder, I want the two-finger back gesture to quit the session and, once the toolkit delivers Back to apps, to go back one page instead unless I am on the root, so that back behaves like every other app.

### Confirm and save
28. As a birder, I want to tap on a photo page to confirm the bird, so that the confirmation is one gesture.
29. As a birder, I want the confirm page to show a Save action as the primary button, so that saving is one more tap.
30. As a birder, I want a "Saved" acknowledgment on the lens and then a return to the stack, so that I can keep listening.
31. As a birder, I want a sighting to record species, time, location, sound confidence and the most recent camera frame, so that I have context later.
32. As a birder, I do not want audio saved with sightings, so that storage stays small and my conversations are not recorded.
33. As a birder, I want to confirm the same species twice in a session without creating confusing duplicates, so that the album stays clean.

### Phone app
34. As a birder, I want a phone screen with connection status, start and stop, and the live candidate list, so that I can use the app without glasses.
35. As a birder, I want an album list of sightings with photo, species, date and place, so that I can review what I saw.
36. As a birder, I want a credits screen listing every photo's observer, license and link plus "Powered by BirdNET", so that the license obligations are met.
37. As a birder, I want to see the crop of the last camera frame with a sighting on the phone, so that I get whatever view the glasses managed.

### Species packs
38. As a birder, I want the Los Angeles pack bundled with the app, so that the first launch works with no signal.
39. As a birder, I want to download other regional packs when I have connectivity, so that I can bird elsewhere.
40. As a birder, I want species not in my pack to still be identified by name, so that a rare bird is never hidden.
41. As a maintainer, I want a reproducible Python pack builder, so that anyone can regenerate or extend a pack.
42. As a maintainer, I want the pack builder to crop close-ups with a bird detector and rank them by bird size, background darkness and sharpness, so that cards are useful on the lens.
43. As a maintainer, I want the pack builder to keep only CC0, CC BY and CC BY-NC photos with full attribution data, so that redistribution is lawful.
44. As a maintainer, I want a manual override list per species, so that a bad automatic pick can be replaced.

### Testing and development
45. As a developer, I want to run the whole lens flow against Mock Device Kit with a display preview inside the app, so that I can iterate without wearing the glasses.
46. As a developer, I want to feed recorded WAV clips through the identification engine in tests, so that identification accuracy is measured repeatably.
47. As a developer, I want the lens page logic to be a pure function of state and events, so that navigation is unit-tested without the toolkit.
48. As a developer, I want a logging build of the audio spike that records frame cadence, latency and glasses battery over twenty minutes, so that phase A is a measured go/no-go.

## Implementation Decisions

### Platform and toolchain
- iOS 27 deployment target, Swift 6 language mode, Xcode 27, SwiftUI. No backwards compatibility.
- Meta Wearables Device Access Toolkit 1.0.0 via Swift Package Manager. Products: MWDATCore, MWDATCamera, MWDATDisplay, MWDATInputs, MWDATMockDevice; MWDATMockDeviceTestClient only in the UI test target.
- ONNX Runtime through Microsoft's official Swift package for model inference.
- SwiftData for the album. Pack data in SQLite plus image files on disk.
- Bundle identifier `com.matthewcelia.birdjournal` (no dashes), custom URL scheme `birdjournal://` for Meta AI callbacks. MetaAppID left empty in Developer Mode. Background modes: audio, processing, bluetooth-central, bluetooth-peripheral, external-accessory, plus the external accessory protocol, Bluetooth, local network, Bonjour and microphone usage descriptions.
- Repository root is the outer BirdJournal folder containing the app project, a `packbuilder` Python package, docs and specs. MIT license for our code.

### Architecture: three modules behind two seams
- **Identification engine** (pure Swift, no UI, no toolkit dependency). Consumes an `AudioSource` (async stream of PCM chunks with sample rate) plus a location and date, produces a `CandidateStack` (ordered species with scores). Resamples to the model's rate, slices 3-second windows with 1.5-second overlap, runs the acoustic model, applies the geo pre-filter, aggregates per-species scores across the session, and admits a species after two windows above threshold. Model access is behind a `BirdModel` protocol with V3.0 as the shipped implementation and v2.4 as a possible swap. Three `AudioSource` implementations: glasses stream, phone microphone, WAV file.
- **Lens session** (pure state machine). Input: `CandidateStack` updates and semantic input events (nav up/down/left/right, select, back, session paused/resumed). Output: the `LensPage` to render (listening, photo, description, confirm, saved, error) and side effects (save sighting, end session). Rules: stack never reorders on a photo page, new species append, swipe up is back, Back on root ends the session, nested Back is handled when the event arrives.
- **Glasses adapter** (thin). Wraps the toolkit: registration, device selection filtered to display-capable devices, session lifecycle, camera stream with audio codec at low resolution and lowest frame rate, Display sends built from `LensPage`, Inputs events mapped to the lens session's event type. Holds all listener tokens. This layer has no logic worth unit testing; it is covered by Mock Device Kit smoke tests.
- **Card renderer** maps a `LensPage` plus pack data to a Display root FlexBox: photo page (image, common name, confidence), description page (field marks, size, habitat, credit line), confirm page (ButtonGroup with Save as primary), listening page (heading and count). Same page model feeds the phone view.
- **Album store**: Sighting (species id, confirmed at, latitude, longitude, accuracy, sound confidence, frame image path, source glasses or phone) and Session (started, ended, location, candidates seen). No audio.
- **Pack store**: read-only SQLite per pack with species, photo, lookalike and pack tables as in the original spec, minus the occurrence table. A pack manifest JSON index on GitHub Releases lists downloadable packs.

### Audio path
- The camera stream is the only ambient audio path. Video codec raw, resolution low, frame rate 2, audio PCM mono at the rate chosen in the phase A spike (44.1 or 48 kHz) and resampled to 32 kHz for V3.0.
- A ring buffer of the last 30 seconds exists for live playback only.
- Location: when-in-use permission, one fix at session start and every ten minutes.
- Listening continues with the phone locked; the audio background mode is declared and the engine runs off the main actor.

### Model
- BirdNET+ V3.0 preview 3.1 pruned FP16 ONNX, 11,560 species, raw waveform input at 32 kHz, sigmoid in-graph. Geomodel v3.0.4 with raw latitude, longitude and week input, threshold 0.03 as a species pre-filter. Both files pinned by exact name and checksum in the repo's model manifest and downloaded by a script, not committed.
- Attribution "Powered by BirdNET" on the credits screen. Model license CC BY-SA 4.0; geomodel Apache-2.0.

### Inputs mapping
- Nav left/right: previous or next species. Nav down: description page. Nav up: previous page. Select on a photo page: confirm. Select on the confirm page: activates the focused button. Back: end session on root, else previous page. Capture and action button events are ignored in v1. Drag is ignored.
- Inputs is attached only after the device session reaches started, with consumeBack true.

### Pack builder
- Python package with DuckDB or SQLite. Inputs: iNaturalist Open Data metadata, a curated LA species list of about 150 species mapped to BirdNET labels, Wikipedia summaries for descriptions. Steps: filter research-grade observations and allowed licenses, download candidate photos, run a COCO bird detector to crop, score crops (bird area, background luminance, sharpness), keep top 3 to 5 per species with a manual override list, resize to lens and phone sizes, write SQLite and a LICENSE file listing every credit.

### Phases
- A: repo restructure, SDK and Info.plist, registration and session, one card on the lens, Nav and Select echo, audio spike with logging for a 20-minute locked-phone run. Go/no-go on latency, battery and background survival.
- B: identification engine with file-fed tests on Matt's labeled recordings.
- C: cards from the LA pack, lens session state machine, confirm and save.
- D: minimal phone screen and album list; credits screen.

## Testing Decisions

- A good test drives a seam from the outside with real inputs and asserts on observable outputs. No test asserts on toolkit calls, internal state or private methods.
- **Engine seam** (primary): tests feed WAV files through the file `AudioSource` with a fixed location and week and assert that the expected species appears in the top three within a time budget, and that noise clips produce an empty stack. Fixtures are Matt's labeled recordings, kept out of the repo and pulled by a script. A small synthetic tone fixture is committed for smoke tests.
- **Lens session seam**: table-driven tests over (state, event) pairs asserting the resulting page and side effects: swipe rules, no reorder on photo pages, append on new species, Back on root versus nested, pause and resume.
- **Card renderer**: snapshot-style tests that a `LensPage` produces a Display tree with the expected text and a single root, and that no page exceeds the word budget.
- **Glasses adapter**: Mock Device Kit smoke tests pairing a `metaRayBanDisplay` mock, reaching session started, sending a page, injecting nav and select, and observing the resulting page. No audio assertions through the mock, since it cannot inject audio frames.
- **Pack builder**: pytest over a tiny fixture pack: license filtering, crop scoring order, manifest and LICENSE output.
- Prior art: none in the repo yet. The DAT CameraAccess and DisplayAccess samples' Mock Device Kit test base class is the pattern for adapter smoke tests.

## Out of Scope

- Android, the web-app path, camera-assisted re-ranking, audio saved with sightings, eBird submission, multi-user or social features, iCloud sync, GBIF-derived occurrence tables, backwards compatibility below iOS 27, App Store or Beta channel distribution, voice invocation until the Developer Center approves it, life list and species pages on the phone beyond the album list.

## Further Notes

- Facts that constrain the design come from Meta's DAT docs as of 2026-09-26 and are recorded in `DECISIONS.md` and `DAT-SETUP-CHECKLIST.md`: no standalone microphone capability, experimental status of audio and Inputs, Back not delivered by real glasses, one registered Dev Mode app at a time, 600 by 600 additive display with one root view per send.
- Hardware and accounts on hand: Meta Ray-Ban Display glasses with Neural Band, iPhone 17 Pro on iOS 27, Wearables Developer Center integration created. To verify before phase A on hardware: Meta AI app v290 or later, glasses firmware v128 or later, no other app registered in Dev Mode.
- The universal link field in the Developer Center is not needed for Dev Mode. It becomes required for Beta distribution and needs an https domain serving an apple-app-site-association file.
- The BirdNET permission email is optional under V3.0's CC BY-SA license; the V3.0 model is a preview and may change, which is why the model sits behind a protocol.
