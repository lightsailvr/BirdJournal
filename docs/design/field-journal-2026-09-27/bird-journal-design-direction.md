# Bird Journal — design workshop 01

September 27, 2026 · Quiet field journal · Design concepts, no app implementation

## Direction

A personal field notebook that helps you look up, notice birds, and remember them. Warm paper, ink, moss green, restrained serif titles, and generous wildlife photography. The interface should feel thoughtful and lived with, while its navigation and controls behave like native iOS.

Use **Listen / Journal / Field Guide** as the three persistent destinations. Put downloadable packs inside Field Guide and connection settings behind the glasses status row or Settings. Sharing starts from a sighting or a selection of journal entries. A community feed would be a separate future product decision.

The boards are generated, static visual concepts, not captures of running iOS screens. Their bird images are illustrative, not verified identification assets or licensed source photography. Dates, sightings, and future pack offerings are sample content. Native controls and typography need final platform layout and accessibility validation during implementation.

## What the repository supports

Reviewed `lightsailvr/BirdJournal` at commit `d518342b4dd4617b424241a8594dde4b8fbfd011`.

| Area | Observed in the repository | Design implication |
| --- | --- | --- |
| Listening | Phone microphone and glasses listening paths, live candidates, start/stop | One welcoming Listen destination; choose audio source in a compact row |
| Identification | Audio-based BirdNET pipeline; stable candidate ordering | Say “heard” or “possible match”; keep rows stable as results arrive |
| Saving | Species, first confirmation time/place, confidence, source, optional glasses frame; repeat confirmation in one run updates that sighting | Separate detected suggestions from entries the person explicitly adds |
| Photos | Bundled Los Angeles pack has 10 species and 50 photos with attribution metadata | Real credited photography is available for a later production design pass |
| Learning | Summary, field marks, size, and habitat fields exist; the current bundled records are empty | The rich field guide requires editorial content work, not only a visual redesign |
| Packs | Bundled pack loading and a downloadable-pack index data structure | Download management and its user interface are proposed work |
| Journal and sharing | Sighting storage exists; current root UI is a development hub | The journal browser, personal notes, sharing, and persistent outings are proposed product features |

The repository's earlier scope favors a minimal phone companion and defers social features and richer species pages. This workshop intentionally expands that direction in response to the current request. No repository files were changed.

## Screen system

### 1. Listen, ready

Open on a quiet page with one clear **Start listening** action. Show **Ray-Ban Display · Connected** and **Using glasses microphones** before starting. The source row opens a choice of glasses or phone. A small drawing can give this otherwise empty screen warmth; it should never delay the main action or compete with it.

Keep a recent sighting below the start control. First use replaces it with a short, welcoming explanation, not fabricated activity. Request permissions in context. Explain that the glasses camera stream is required for ambient audio and may provide a snapshot when adding a bird. Avoid implying that the camera identifies the species. Location improves local suggestions; denied location should have an explicit, understandable alternative.

### 2. Listen, active

Show audio source, elapsed time, modest waveform, and **3 species heard · 1 added**. Each row has a bird thumbnail, name, last-heard time, and **Review** or **Added to journal**. New species append; existing rows do not jump around as scores change. A persistent **Stop listening** action ends collection immediately, then opens a calm review of the outing.

Review opens the bird profile with **Add to journal** available in this listening context. A guide page opened independently is educational and does not silently create a sighting. Provide an explicit Undo after adding. Make observation type a future design refinement: hearing a match does not prove a visual sighting.

Keep the numerical model score in an optional match-details disclosure with an explanation that it is not a calibrated probability. Do not invent “certain” or “verified” status. Qualitative confidence labels require calibration before shipping. The waveform represents live input; it is not evidence that recordings are saved. The current album stores no audio.

When navigating away, offer a compact listening accessory above the system tab bar with elapsed time and a stop action. Mark it as proposed behavior. Do not promise pause/resume, automatic reconnection, voice start, or reliable display wake until those paths are verified.

### 3. Journal

Use date sections and readable rows, with a **Sightings / Species** switch. Sightings tells the story over time; Species offers the distinct birds the person has added. A restrained total is enough; avoid turning a notebook into a performance dashboard.

A sighting detail should contain species, date, approximate place, identification source, an optional personal note, and the user's glasses snapshot when available. Label **Your glasses snapshot** separately from **Reference photo**. The snapshot may show the surroundings rather than the bird. Never present a pack photo as proof of what the person photographed.

Support editing notes, correcting/removing a mistaken entry, and sharing. Searching, user-authored notes, a species index, and saved outing summaries require additional product work. Grouping saved entries by date does not itself require inventing a persistent session history.

### 4. Field Guide and bird profile

The guide entry page contains search by common/scientific name, **Available offline**, an installed-species collection, and **Bird packs**. A species profile opens with an unaltered, large reference photo, common name, scientific name, and visible photo credit/source access.

Organize detail in reading order: a short introduction; diagnostic field marks; size and habitat; behavior; similar birds; then further learning and sources. Additional sections such as range, seasonality, diet, conservation, and sound examples should appear only when sourced content exists. Show section-level sources and update dates where useful. Avoid empty headings and invented filler facts.

Use a photo gallery to show useful identification differences, including age or sex when verified. Preserve diagnostic markings in crops. Comparison should place field marks side by side. Any future range map requires a real sourced dataset; any future song example requires licensed reference audio, distinct from a user's listening session.

The sample Black Phoebe description is an original short paraphrase based on Cornell's identification information. Research access does not grant republication rights to Cornell photographs or text. Production editorial content needs a deliberate sourcing and permissions workflow.

### 5. Share a sighting

Start with a preview of a small journal postcard: bird, date, optional general area, optional personal note, image credit, and Bird Journal signature. Clearly label a reference image. A personal snapshot is a separate image choice when one exists.

Let the user toggle date, general area, and note before opening the native iOS share sheet. Hide precise location by default and review exported metadata as well as visible text. Keep attribution attached to the exported image and accompanying text/link. A generated concept illustration must not receive a real photographer's credit.

A compact sharing flow satisfies the request without requiring accounts or a public feed. Multi-entry outing cards are a useful next design iteration. Cloud links require a hosting/sharing system and should not be implied by a static export.

### 6. Bird packs

Present packs as portable field guides: a habitat photograph, region, number of covered species, download size, and offline status. Explain that they add photos and learning material; birds outside installed packs can still be identified by name.

Provide clear states: **Included**, **Download · 84 MB**, **Downloading**, **Installing**, **Ready offline**, **Update available**, and **Try again**. Keep Cancel available during transfer. Distinguish bytes transferred from a successfully installed pack. A details page previews covered birds, content types, source credits, version, and required storage before download.

Show useful remedies for no connection, insufficient storage, interrupted transfers, and failed installation. Preserve the previous working version if an update fails. Removing a downloaded pack removes offline reference material, not journal entries or personal snapshots. The bundled pack can remain marked Included without a misleading Remove control.

Pacific Northwest and Desert Southwest, their species counts, and their download sizes in the board are illustrative future offerings. The repository's inspected bundle is Los Angeles, with 10 species.

## Reusable visual language

| Element | Light | Dark |
| --- | --- | --- |
| Main content | Paper `#F8F5ED` | Forest charcoal `#171E1A` |
| Raised content | Sage paper `#E7EDDF` | Soft charcoal `#242E27` |
| Primary text | Ink `#263329` | Warm ivory `#F2EEE4` |
| Secondary text | Suggested `#5D675E` | Suggested `#BEC7BD` |
| Primary action | Moss `#355B46` with ivory text | Sage `#BCD2AC` with deep green `#17261C` text |

These are starting design tokens, not measured compliance results. Validate all foreground/background combinations, imagery overlays, disabled states, and increased-contrast variants in the actual interface.

- **Typography:** New York/system serif for page and editorial headings; SF Pro/system sans serif for body, controls, and metadata. Start with large-title 34 pt, section-title 22 pt, body 17 pt, supporting text 15 pt, and attribution 13 pt. Use semantic text styles and Dynamic Type, not fixed pixel layouts. Keep scientific names italic; avoid handwriting for functional text. Generated boards approximate these fonts.
- **Icons:** SF Symbols for waveform, book, bird, glasses, share, download, checkmark, and location. Match symbol weight to adjacent text; verify symbol availability in the target SDK. Pair unfamiliar icons with text. A custom bird illustration belongs in a quiet welcome/empty state, not every control.
- **Spacing:** Begin with 20–24 pt content margins, 12–16 pt row gaps, and 24–32 pt section separation. Let text size and native controls drive the final geometry. Use 44 pt or larger comfortable touch targets, with 52–56 pt primary actions where appropriate.
- **Surfaces:** Prefer readable lists, subtle dividers, and a small number of meaningful cards. Keep paper warmth in the content. Use native material treatments for navigation, sheets, and controls; do not coat the whole field guide in glass.
- **Photography:** Natural color, useful species detail, consistent thumbnail crops. Keep text off diagnostic markings. Use an opaque caption region when an image cannot support adequate text contrast.
- **Motion:** Gentle updates and a restrained waveform, no pulsing page or constant celebratory animation. Honor Reduce Motion. Use text plus optional haptics for important state changes; sound alerts remain optional.

Reusable components: audio-source row; listening status strip; candidate row; saved-sighting row; attributed bird photo; learning disclosure; pack download row; share postcard; recoverable error notice.

## Dark appearance and accessibility

Follow the system appearance preference and preserve hierarchy between base and raised surfaces. Use softer warm text and sage actions; keep bird photography in natural color. Do not invert images. The three dark concepts intentionally repeat the main light screens for direct comparison.

Plan for Dynamic Type through accessibility sizes, VoiceOver, Bold Text, Increase Contrast, Reduce Transparency, and Reduce Motion. Let bird names and attribution wrap. Stack rows at large text sizes and keep the stop control reachable without covering results. Announce meaningful listening changes without reading every score update. Use text and icons with color for Added, Listening, Offline, and Error states.

Apple HIG alignment is a design target here, not an audited property of raster mockups. System navigation, tabs, modal sharing, and familiar controls should be resolved using the target OS's native components. Test actual layouts at narrow widths, large text sizes, bright outdoor light, and dark appearance before approval.

## Credits as part of the product

Use compact attribution beside each real source image, expanding to photographer/observer, exact license/version and link, original source, and crop/modification disclosure where relevant. Derive this from the pack metadata. Put text sources near their sections and provide a full Sources & credits screen with **Powered by BirdNET**, model licenses, photo credits, and other acknowledgments.

Sharing must preserve the relevant attribution and use each asset according to its actual license. The repository includes differing photo license categories, so distribution and export rules need to be resolved per asset; a single generic credit does not replace that work. Do not style generated concept art as if it came from iNaturalist.

## Companion glasses experience

Carry over names, photos, and the meaning of Added. Do not carry the paper UI onto the additive lens. The inspected repository documents a 600 × 600 canvas, dark-background photo crops, short screenfuls, app-driven paging, and a stable species list. Preserve the photo/details split and a clear Add action.

The repo also documents that the real glasses' system back gesture can end the display session and that automatic restart after removing/replacing glasses remains unresolved. Phone copy should say **Listening stopped** with **Start again** or offer **Use iPhone microphone**; it should not display a false paused state. Hardware reconnection and display wake behavior require validation before promising continuity.

## Feedback to guide the next round

1. Is the paper warmth and serif typography right, or should it be cleaner and more photographic?
2. Should the journal emphasize individual birds or named outings?
3. Does sharing mean a beautiful exported card initially, or is a future community space central?

The next visual pass should deepen the chosen direction with a candidate-review/Add state, sighting detail, pack detail, full credit sheet, connection recovery, and large-text examples. Those are specified above but not all pictured in this first board set.

## References

- [Reviewed repository](https://github.com/lightsailvr/BirdJournal/tree/d518342b4dd4617b424241a8594dde4b8fbfd011)
- [Current phone hub](https://github.com/lightsailvr/BirdJournal/blob/d518342b4dd4617b424241a8594dde4b8fbfd011/BirdJournal/BirdJournal/ContentView.swift)
- [Repository design and hardware decisions](https://github.com/lightsailvr/BirdJournal/blob/d518342b4dd4617b424241a8594dde4b8fbfd011/DECISIONS.md)
- [Apple: Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
- [Apple: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- [Apple: Tab bars](https://developer.apple.com/design/human-interface-guidelines/tab-bars)
- [Apple: Dark Mode](https://developer.apple.com/design/human-interface-guidelines/dark-mode)
- [Apple: Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- [Cornell Lab: Black Phoebe identification](https://www.allaboutbirds.org/guide/Black_Phoebe/id)

Boards were generated with the built-in image-generation tool. Exact prompts accompany these deliverables in `design-prompts.md`.
