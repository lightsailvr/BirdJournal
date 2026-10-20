# BirdJournal collectible cards style guide

Version 0.2 · October 13, 2026 · Design and development handoff

BirdJournal turns each confirmed bird encounter into a collectible memory. Preserve the existing field-journal identity: warm paper, moss green, serif headings and quiet native controls. Let painterly bird art provide the richness. This guide defines the approved product direction, proposed interaction defaults and the remaining decisions for implementation.

The accompanying PDF is the visual reference. `interactive-prototype.html` demonstrates the revised encounter gallery and real two-sided card flip. Prototype bird records, rarity values and social activity are examples. Photo transformation and sharing are simulated. The prototype navigation above the phone is a review tool, not app navigation.

## Confirmed product direction

- Every confirmed encounter earns a new dated card, including repeat encounters with the same species.
- The user's first encounter with each species earns a Legendary card. Later encounters remain distinct cards and may use local art variations.
- Local editions express the place of the encounter. Reseda House Finch can feel like a warm garden; San Diego House Finch can have coastal light. Both are the same species.
- Rarity represents how unusual the species is in that place and season. It is independent of personal-first Legendary status.
- Both Heard and Seen encounters qualify. State the encounter method explicitly.
- Users can attach their own photograph and have AI embellish it into card artwork. Preserve the original as a separate source image.
- Social features center on small friend circles and shared goals.
- Replace one-tab-per-encounter navigation with a scalable gallery. The card must visibly flip to its reverse.

## Product vocabulary

| Term | Meaning | Presentation |
| --- | --- | --- |
| Species | A taxonomic identity shared by many encounters | House Finch |
| Encounter | One confirmed observation at a time and place | October 13 at 4:31 PM |
| Card | The collectible representation of one encounter | Artwork, title, date, method and reverse |
| Local edition | A place-inspired art treatment | Reseda House Finch or San Diego House Finch |
| Legendary | The owner's first discovery of that species | Gold frame and “Legendary · Your first” |
| Rarity | Regional and seasonal encounter scarcity | Proposed 0–100 score with explanatory label |
| Evidence | Original photo or confirmed encounter method | Kept separately from generated artwork |

Art regeneration updates the artwork for an existing card; it does not create another encounter. Completing a circle goal counts distinct species, rather than rewarding repeated saves of one bird. These are proposed implementation defaults.

## Visual foundations

Use the existing semantic colors from `BirdJournal/BirdJournal/Assets.xcassets`. Reuse their Increase Contrast variants. The current asset catalog, not sampled pixels from a screenshot, is the source of truth.

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| JournalPaper | #F8F5ED | #171E1A | Main page |
| JournalRaised | #E7EDDF | #242E27 | Grouped content and card backs |
| JournalInk | #263329 | #F2EEE4 | Primary text |
| JournalInkSecondary | #5D675E | #BEC7BD | Supporting text |
| JournalMoss | #355B46 | #BCD2AC | Actions and selected navigation |
| JournalMossText | #F2EEE4 | #17261C | Text on primary actions |
| JournalRule | #D9DDD1 | #33403A | Fine separators |

New proposed collectible tokens: GoldInk #886424 in light appearance and #E8CA84 in dark; GoldWash #F0E6CB and #3D3828. CardFace is a fixed illustrated-art surface, evergreen #152D26 with warm ivory #FFF3CE. The Legendary frame blends #EDD497, #887342, #E2CF92 and #AA8C45; local-edition frames use muted sage. Gold signals a first discovery, not rarity. Treat decorative foil as optional. Never use color alone to communicate status.

The application follows system appearance. Art does not get recolored when the app enters dark mode. Do not place essential text directly over a busy bird image. Keep the eye, bill, wing tips and key field marks clear of badges and crops.

## Typography and spacing

Continue `JournalFont` and `JournalLayout` in `BirdJournal/BirdJournal/Design/Theme.swift`.

| Role | Native baseline | Use |
| --- | --- | --- |
| Page title | System serif largeTitle, about 34 pt | Journal and Circle |
| Species title | System serif title, about 28 pt | House Finch |
| Section title | System serif title2, about 22 pt | All encounters |
| Card heading | System serif title3, about 20 pt | Species name |
| Compact row title | System serif body, about 17 pt | Encounter rows |
| UI and body | System sans body, about 17 pt | Controls and explanatory text |
| Supporting | System sans subheadline, about 15 pt | Date and location |
| Attribution | System sans footnote, about 13 pt | Art source and evidence labels |
| Scientific name | System serif subheadline italic | Haemorhous mexicanus |

These are Dynamic Type baselines, not fixed sizes. The HTML uses Georgia and system sans as concept approximations. Its miniature labels are not production typography specifications. Keep production supporting text at least 11 pt at the default size, with no shrink-to-fit for essential content.

Page margins are 22 pt; row gaps 14 pt; section gaps 28 pt. Standard surface radius is 14 pt, thumbnails 10 pt and proposed collectible radius 18 pt. Primary actions are 54 pt high. Other tappable targets are at least 44 by 44 pt. Use two card columns when readable and one at accessibility text sizes. Card height may grow; do not clip the species name or encounter date to preserve an aspect ratio.

Use SF Symbols in the app with visible labels for major actions. The companion uses Lucide as a visual approximation. Decorative sparkles accompany a first-discovery label; they do not carry meaning alone.

## Card anatomy

The front contains, in order: edition or Legendary label, large painterly bird art, place name, species name, scientific name, a short colorful description, rarity with regional and seasonal context, and the encounter date and method. Keep the place and species readable together as “Reseda House Finch.” Prefer one sentence of evocative copy over invented biological claims.

The reverse contains the encounter's date and local time, place, Heard or Seen status, personal note, original-photo entry if present, art provenance, and rarity explanation. The AI image is artwork, not evidence. A photo attachment does not automatically establish species identity; ask the user to review a mismatch before assigning the art.

Only the first personal card for a species receives the Legendary label and gold treatment. A common House Finch may be Legendary to its owner while displaying a low rarity score. Later House Finch cards can be Garden or Coastal editions. A location is an edition attribute, not another taxonomic species.

## Art direction

Paint real birds with natural-history detail, soft gouache texture, believable anatomy and subtle fantasy atmosphere. Use warm or cool light, quiet gold flecks, botanical framing and a recognizable regional color story. Put the bird before scenery. Avoid human features, costumes, battle statistics, exaggerated anatomy or invented plumage.

Reseda reference: citrus leaves, warm garden light, terracotta and valley greens. San Diego reference: seafoam, pale sand, coastal flowers and salt-air light. These are thematic illustration directions, not a claim that a particular landmark, plant or shoreline was present in the observation. Do not invent encounter facts from the art.

For photo-based artwork, preserve the bird's pose, sex or age cues where visible, species markings and distinguishing features. Embellish atmosphere and treatment without painting over identifying evidence. Show the original and proposed art together for approval. Offer Keep original and Try again. Never overwrite the original or mark the art as a camera photograph.

Suggested prompt structure: “Painterly natural-history illustration of [species] from [region], with [place palette]. Preserve the bird's visible anatomy and markings [and pose when using a photo]. Add subtle atmospheric light and botanical framing. No typography, borders or logos.” Compose the card frame and labels in the app, outside image generation.

Concept illustrations were generated with the built-in image-generation tool. They are visual references, not field-identification authorities or completed production assets. Review anatomy and art provenance before shipping.

## Navigation and scalable encounter browsing

Retain Listen, Journal and Field Guide. Add Circle as a fourth top-level destination. Journal contains the stable modes Cards, Sightings and Species. Stable content modes may use segmented controls; encounter instances must not become tabs.

Cards is the newest-first encounter collection. Sightings is the chronological journal view. Species groups all encounter cards by species. Tapping a species opens its encounter gallery; tapping a card opens that particular encounter. The Field Guide can link to the same gallery.

A species gallery shows its species name, total cards, place count and first-discovery date. Use a two-column grid with a place picker and a sort menu. Each tile includes the place, date, time, Heard or Seen label and edition. Show the total and the filtered count. Two sightings on the same day remain separate tiles.

At 10–15 cards, retain the same layout. The prototype starts with six tiles and reveals more; a production lazy grid may load further encounters as the user scrolls. Do not append controls for every new card. At larger counts, use paginated data and thumbnail loading without changing the navigation model. Add further filters only when needed.

The card detail has one All encounters control and a position indicator such as “3 of 15.” Optional previous and next controls navigate the current filtered and sorted result. At a boundary, disable the unavailable direction. Opening a different encounter returns to its front. Back to the gallery preserves the filter, sort, selected card and scroll position. An external card link opens that exact card and provides a route to all encounters.

If a filter returns no cards, show “No encounters here yet” with Clear filters. If the species has no cards, show the guide entry and a route to Listen. A missing location uses “Place not recorded”; it does not guess a local edition.

## Card flip interaction

Tap the artwork or the labeled Flip to encounter story control to rotate the same card around its vertical center. Keep both faces mounted and the card's footprint stable. Proposed timing is 480 ms with a smooth ease-in-out curve; perspective is subtle. Hide each face's back surface so text never appears mirrored. The screen chrome and background remain still.

The reverse becomes accessible when it becomes the readable face. Expose one face at a time to VoiceOver; keep focus on the flip control and announce “Back, encounter story” or “Front, collectible art.” The control label changes to Flip to artwork on the reverse. A visible control provides the same function without relying on a gesture. Child actions such as View original photo must not also trigger a flip.

With Reduce Motion, switch faces immediately or with a brief crossfade and no 3D rotation. Do not trigger flips on hover, tilt or page load. Repeated taps should resolve to a coherent final face rather than mounting duplicate views or restarting the animation unpredictably. A proposed light haptic can mark completion; it is not required to understand the action.

The companion demonstrates rotation and reduced-motion switching. Production still needs testing for VoiceOver timing, Dynamic Type, native gestures and rapid repeated input.

## Identification and first discovery flow

Listen or observe → review the suggested species → choose Heard or Seen → confirm and save the encounter → create a card. A model suggestion alone does not earn a card. A manual save creates the encounter even if illustration generation or network access is unavailable.

For a first personal species, show a single Legendary reveal after saving, with the card central and the copy “Your first Anna's Hummingbird.” Offer Share this discovery and Back to my collection. The saved state is already complete; dismissal or sharing failure must not lose it. For repeat encounters, use a quieter “A new card for your collection” acknowledgment.

Generate artwork independently of saving. Show a reference image or existing species art, clearly labeled, while new art is preparing. Failure offers Retry art and Keep current art. Do not repeat the first-discovery celebration when the same card is reopened.

## Photo to art flow

Open the encounter → choose a photo → preserve the original → review the bird and encounter match → choose the art treatment → generate preview → compare original and art → approve artwork on this card.

A Heard encounter may have no photo. Adding one does not silently switch it to Seen; ask the owner to confirm the method. Do not infer that generated illustration is photographic proof. Display Photo attached only when an original exists. Use AI-embellished from your photo for transformed art and AI illustration for species-and-place art.

Canceling, rejecting an image or retrying generation never deletes the sighting. Generation should survive navigating away. Show Preparing artwork while pending, provide a retry on failure and preserve the last approved artwork until a replacement is approved. The original may be removed through a deliberate action; its evidence badge must then update.

## Circles and sharing

Use invite-only circles as the proposed default. Show friends' recent finds, small reactions and shared progress. A goal such as “Discover 12 different species together” rewards exploration; each species counts once toward that goal even when many friends or encounters contribute. A circle-first label is distinct from a person's Legendary first.

The comparison view shows You and a selected friend, with Heard, Seen or an empty state for each species. Explain counts clearly: cards measure encounters, species measure distinct species and goal progress measures qualifying distinct species in its defined period. Show shared species and gentle ideas for another walk. Avoid a global rarity leaderboard in this first release.

Sharing starts with a preview of the selected card, the owner's chosen caption and audience. Show the circle destination explicitly. Offer city-level location or no location; omit exact coordinates from both the image and export metadata. Proposed default is city-only with an obvious opt-out. Sensitive-location policy remains a product decision. The original photo is not attached to a shared illustrated card by default.

Posting requires the user's explicit Share action. In the prototype, no message is actually sent. Native sharing should offer an image suitable for Messages and other destinations; preserve attribution where required by an art source.

## Copy and tone

Write with warmth, curiosity and precise observation. Use short sentences and familiar language. The artwork carries most of the fantasy. Keep operational copy literal.

- First discovery: “Your first Anna's Hummingbird.”
- Repeat encounter: “A new card for your collection.”
- Evidence: “Heard,” “Seen,” “Photo attached” and “Original photo.”
- Rarity fallback: “Rarity unavailable for this place and season.”
- Art pending: “Your encounter is saved. Artwork is on its way.”
- Circle progress: “3 more species to discover together.”

Avoid claiming that an AI suggestion is a verified sighting, that every card is biologically rare or that collecting a local edition creates a new species. Avoid competitive urgency and daily-loss mechanics in the initial experience.

## Implementation boundaries and open decisions

The existing Sighting model already creates a record on every confirmed add. Build the card layer around that stable encounter ID. Store the species ID, time and timezone, place with accuracy, encounter method, original asset reference, generated art and provenance, Legendary status and rarity context separately. An art job or shared post references the encounter; it never creates another sighting by retrying.

Proposed rarity presentation is 0–100, higher meaning less frequently encountered locally and seasonally. The data source, region size, season window, calibration, labels and minimum evidence requirements remain unresolved. The prototype numbers must not become production constants. Show unavailable when the supporting data is missing. A recommended default is to retain the rarity snapshot and calculation version from the encounter date.

Settle before implementation: backdated imports and deletion of the first card; whether the earliest encounter or first confirmed save owns Legendary status; circle membership and invitation rules; art-generation cost, delay and review expectations; location handling for sensitive species; correction, deletion and moderation effects on shared goals. These do not block the visual identity, but they affect state behavior.

## Acceptance checklist

- Fifteen encounters of one species remain easy to scan with no encounter tabs. Filters, sort, paging and back navigation preserve context.
- Every confirmed repeat save makes one distinct card. A generation retry creates no duplicate encounter.
- First personal species cards receive Legendary treatment regardless of biological rarity; later cards retain their own place, date and method.
- The card visibly rotates, both faces remain aligned, reverse text is not mirrored and Reduce Motion removes the rotation.
- VoiceOver reads one face at a time; the flip control remains reachable, labeled and focused.
- Large text, long species names, dark mode and Increase Contrast remain readable. Essential touch targets reach 44 pt.
- Original photo, generated art and encounter method remain separate; failure or cancellation preserves the saved encounter.
- Shared-goal counts use distinct species and a defined period. Sharing previews the correct selected card and respects the location choice.
- Missing location, unknown rarity, empty galleries, offline saving, loading art and failed art generation have clear fallback states.

## Reference and package notes

Existing UI reference: `docs/screenshots/2026-09-27/` and `docs/screenshots/2026-10-02/`. Existing design code: `BirdJournal/BirdJournal/Design/Theme.swift` and `BirdJournal/BirdJournal/RootView.swift`. Journal behavior: `BirdJournal/BirdJournal/Journal/JournalView.swift`; repeat-add decision: “Every add is a sighting” in `DECISIONS.md`, October 10, 2026.

The original app uses Listen, Journal and Field Guide; Circle is a proposed addition. The latest handoff supersedes the first mockup's per-edition segmented control and content-swap flip. App code has not been changed by this design work.
