# BirdJournal v2 — Collection and circles

Status: ready-for-agent · issue #48 · 2026-10-13 · Synthesized from the collectible-cards style guide v0.2 and four grill rounds. Vocabulary follows `CONTEXT.md`; decisions that are hard to reverse are ADR-0001 to ADR-0006 in `docs/adr/`; `DECISIONS.md` wins where they disagree with this spec.

## Problem Statement

The journal is a tidy list of sightings, and it is tired. Adding a bird ends in a row of text and a snapshot, and nothing makes me want to go out and find the next one, or find the same bird again somewhere new. Birding with friends is half the fun, but the app is solitary: my friends never learn what I heard this morning, and I only hear about their finds if they text me. I also want the app to stay free, because it is built on open data and open models and I don't want to sell other people's photos and recordings, but painting art and running a server cost money.

## Solution

Every add earns a collectible card. A card is the face of one sighting: the place, the species, a short mythic caption written for that moment, real natural-history stats, a rarity label for that place and week, and art. Art arrives in three ways. Pack art shows the moment the card exists. Scene art is painted into the photo my glasses took. Photo art is my own photo of the bird, embellished and approved by me. My earliest card of each species is Legendary, with a gold frame and a reveal on the lens and the phone. Cards belong to the set of the pack region where I found the bird, with collector numbers and set progress, so a region becomes something to complete. The card flips to show the encounter story, the lore and the evidence.

With an optional account (Apple or Google), I join small invite-only circles. My sightings reach my circles automatically as finds unless I go private. My friends react, compare birds and chase shared monthly and custom goals. A push tells me about the finds that matter, the rest come bundled, and a friend's notable find appears on my lens while I'm out. Everything is free; a tip jar helps cover the server and the home GPU that paints the art.

## User Stories

### Cards and the collection
1. As a birder, I want every add to earn a card, so that each moment with a bird becomes something I keep.
2. As a birder, I want a repeat add of the same species to earn its own dated card, so that a House Finch in Reseda and one in San Diego are both in my collection.
3. As a birder, I want my earliest card of each species marked Legendary with a gold frame and "Your first", so that firsts feel special even for common birds.
4. As a birder, I want a short Legendary reveal right after an add that is my first of a species, so that the moment is celebrated while I'm still in the field.
5. As a birder, I want a quieter "A new card for your collection" for repeat cards, so that the celebration stays meaningful.
6. As a birder, I want the reveal never to replay when I reopen a card, so that it stays a one-time moment.
7. As a birder, I want dismissing the reveal or a failed share never to lose the sighting, so that saving is never at risk.
8. As a birder, I want all my existing sightings to become cards when the update arrives, with my earliest of each species Legendary, so that my history is my starting collection.
9. As a birder, I want one "your collection so far" moment instead of a reveal for every imported species, so that the update doesn't bury me in celebrations.
10. As a birder, I want Legendary to pass quietly to my next-earliest card when I delete my first one, so that corrections keep "your first" honest.
11. As a birder, I want a species to leave my collection when I delete its last card, so that a mistaken ID doesn't linger.
12. As a birder, I want the Journal tab to offer Cards, Sightings and Species, so that I can browse my collection, my chronological journal or one bird's cards.
13. As a birder, I want the Cards view newest first in a two-column grid that becomes one column at accessibility text sizes, so that it reads well at any size.
14. As a birder, I want a species gallery that shows "House Finch · 15 cards · 2 places" with a place picker and a sort menu, so that a bird I see often stays easy to browse.
15. As a birder, I want each gallery tile to name its place, date, time, method and edition, so that two cards from the same day stay distinct.
16. As a birder, I want a card detail with "3 of 15", Previous and Next within my current filter, and one All encounters control, so that I keep my place while browsing.
17. As a birder, I want Back from a card to restore the gallery's filter, sort and scroll position, so that browsing never resets.
18. As a birder, I want to tap the art or a labelled Flip control to rotate the card to its back, so that the card feels like a real object.
19. As a birder using VoiceOver, I want only the readable face exposed and the flip announced as "Front" or "Back", so that the card is accessible.
20. As a birder with Reduce Motion on, I want the card to switch faces without rotating, so that the flip doesn't make me uncomfortable.
21. As a birder, I want rapid taps on Flip to land on one coherent face, so that the card never shows duplicates or stale content.
22. As a birder, I want the card front to show the edition or Legendary label, the art, the place, the species and scientific name, the caption, the type line, the stats, the rarity, and the date and method, so that a card reads like a collectible.
23. As a birder, I want the card back to show the time and place, Heard or Seen, my note, the original photo if there is one, the art's provenance, the lore, the rarity explanation and the sources, so that the story and the evidence live together.
24. As a birder, I want my cards to belong to the set of the pack region where I made the sighting, with a collector number like "021/160", so that I can work toward completing a region.
25. As a birder, I want sightings outside every set to land in an Uncharted set, so that nothing I find is left out.
26. As a birder, I want set progress like "Los Angeles · 87 of 160" in the Species view, so that I can see how close I am.
27. As a birder, I want the Field Guide to show species I haven't collected as silhouettes, so that I know what's still out there.
28. As a birder, I want a sighting that a newly published pack covers to move into that pack's set, so that early finds count once my region gets a pack.
29. As a birder, I want each card to show a type line such as "Songbird — Finch", so that cards have a bit of game feel without invented mechanics.
30. As a birder, I want empty galleries, filters with no matches, a missing place, unknown rarity and missing art to say so plainly, so that nothing looks broken.
31. As a birder, I want to mark a card Heard or Seen on the phone, with Heard as the default, so that adding in the field stays one tap.
32. As a birder, I want attaching a photo to a Heard card to ask whether I saw the bird, so that the method never changes silently.

### Rarity, stats and lore
33. As a birder, I want each card to show how unusual the bird is at that place and week as Common, Uncommon, Rare or Exceptional, so that unusual finds stand out.
34. As a birder, I want the rarity saved at the moment of the add, so that a card's rarity never changes later.
35. As a birder, I want "Rarity unavailable for this place and season" when there was no location, so that the app never guesses.
36. As a birder, I want the card back to explain where rarity comes from, so that I can trust it.
37. As a birder, I want real wingspan and weight on the card front with a diet icon, so that cards carry real numbers like a game card.
38. As a birder, I want estimated wingspans marked "≈", so that I know which numbers were measured.
39. As a birder, I want habitat, migration, nest, clutch size and lifestyle on the back, so that I learn about the bird.
40. As a birder, I want a stat the datasets lack left off rather than guessed, so that every number is real.
41. As a birder, I want each species to carry short lore in a mythic voice built from true facts, so that collecting feels like discovering a legend.
42. As a birder, I want each card's front to carry a one-line caption written for that moment (season, time of day, place, Heard or Seen), so that every card feels like mine.
43. As a birder, I want captions to state only facts from the species' fact sheet, so that the mythic voice never invents biology.
44. As a birder whose phone can't run Apple's on-device model, I want the lore's one-line tagline in place of a caption, so that the card still reads well.
45. As a birder, I want stats and lore credited to their sources on the card back and in Credits, so that the people behind the data are recognized.

### Art
46. As a birder, I want every card to show its pack art the moment it exists, so that a new card never looks unfinished.
47. As a birder, I want pack art painted in the region's edition theme (citrus and valley light in Los Angeles, the coast in San Diego), so that the same bird feels different in different places.
48. As a birder with an account, I want the bird painted into the photo my glasses took at the add, so that my card shows where I actually was.
49. As a birder, I want scene art to replace the pack art automatically when it's ready, so that I don't have to approve every card from a long walk.
50. As a birder, I want "Try again" and "Use pack art" on every card with scene art, so that I can fix a bad painting.
51. As a birder, I want "Your encounter is saved. Artwork is on its way." while art is pending, even for days while the painting machine is off, so that I know nothing is lost.
52. As a birder, I want a failed art job to offer Retry art and Keep current art, so that failures never cost me the card.
53. As a birder, I want to turn my own photo of the bird into card art through a preview, a comparison and an approval, so that art made from my evidence is my call.
54. As a birder, I want to choose that photo from my glasses photo or my photo library, so that shots from a real camera can become art too.
55. As a birder, I want the original photo kept separately and never overwritten, so that the evidence survives.
56. As a birder, I want art labelled "AI illustration" or "AI-embellished from your photo", and "Photo attached" only when an original exists, so that art is never mistaken for evidence.
57. As a birder, I want the bird's anatomy and field marks accurate in every painting, with fantasy only in light and atmosphere, so that birders take the cards seriously.
58. As a birder, I want scene and photo art for a Legendary card painted with more dramatic light, so that firsts look the part.
59. As a birder, I want faces in my photos blurred on the phone before any photo leaves it, so that strangers aren't painted into cards.
60. As a birder, I want art retries never to create another card or sighting, so that my collection stays true.

### The glasses
61. As a birder on the glasses, I want the lens to show "Your first House Finch" after an add that is my first of a species, and "New card · 021/160" otherwise, so that the payoff lands in the field.
62. As a birder on the glasses, I want adding to stay one tap with no Heard or Seen question, so that I can keep my eyes on the bird.
63. As a birder on the glasses, I want the photo from the viewfinder to become my card's scene art, so that my glasses compose my card.
64. As a birder on a run, I want a friend's notable find to show on the lens as a friend banner, so that I know a friend found something while we're both out.
65. As a birder reviewing a species or taking a photo, I want friend banners held back, so that nothing interrupts the add.

### Accounts
66. As a birder, I want listening, the journal, cards, pack art and captions to work without an account, so that I'm never asked to sign up to identify a bird.
67. As a birder, I want to sign in with Apple or Google when I want circles or painted art, so that I can use an account I already have.
68. As a birder, I want to stay signed in across launches, so that circles just work.
69. As a birder, I want to delete my account and everything the server holds about me from inside the app, so that leaving is easy.
70. As a birder, I want to sign out without losing my journal or cards, so that the account stays optional.

### Circles and finds
71. As a birder, I want to create and name a circle, so that my birding friends have a home.
72. As a member, I want to invite friends with a link or QR code that expires after seven days, so that only people I choose can join.
73. As an invited friend, I want to join a circle by opening the link and signing in if needed, so that joining takes seconds.
74. As a birder, I want to be in several circles, so that my family and my Sunday group stay separate.
75. As a member, I want my sightings to reach my circles automatically as finds, with species, Heard or Seen, city, time and card art, so that my friends see what I find without extra steps.
76. As a member, I want a setting that makes me private, so that only cards I share by hand reach my circles.
77. As a member, I want to share a card by hand with a preview of exactly what will be sent, optionally adding my note and my original photo, so that I control anything personal.
78. As a member, I want my notes and original photos never sent automatically, so that private things stay private.
79. As a member, I want deleting a sighting to remove its find from my circles, so that corrections reach my friends.
80. As a member, I want a circle feed of recent finds with each friend's card art, so that I can enjoy what my friends found.
81. As a member, I want "First for the circle" on the earliest find of a species in a circle, separate from anyone's Legendary, so that shared discoveries get their own celebration.
82. As a member, I want to react to a find with a few fixed reactions such as "Lovely find", so that I can cheer friends on.
83. As a member, I want to compare my birds with a friend's (Heard, Seen or not yet found for each species), so that we can plan the next walk.
84. As a member, I want an automatic monthly goal sized from our circle's history, so that the circle always has something to chase.
85. As a member, I want to create custom goals with a title, a target, a start and an end, so that we can plan a trip or a Big Day.
86. As a member, I want goals to count distinct species, not repeat cards, so that progress means exploring.
87. As a circle creator, I want to remove a member, so that the circle stays friendly.
88. As a member, I want to leave a circle with my past finds staying in its history, so that goals already reached still count.
89. As a member, I want circles capped at 20 people, so that a circle stays a small group of friends.

### Notifications
90. As a member, I want a push when a friend finds a Legendary, a circle first or a Rare or Exceptional bird, or completes a goal, so that I hear about the finds that matter.
91. As a member, I want a friend's other finds bundled into one digest at most every two hours ("Maya found 6 birds in Pasadena"), so that a busy walk doesn't flood my phone.
92. As a member, I want a push when someone reacts to my find, so that I know my friends noticed.
93. As a member, I want to mute a circle or a friend, so that I control the noise.
94. As a birder, I want to be asked for notification permission, with an explanation, when I create or join my first circle, so that the prompt makes sense.

### Privacy and safety
95. As a member, I want finds to show a city and never a coordinate, with image metadata stripped, so that my exact spots stay mine.
96. As a member, I want threatened species (IUCN Vulnerable or worse, plus a short hand-kept list) to show "a secret spot" instead of a city, so that sensitive birds are protected.
97. As a member, I want to report a find or a member and to block an account, so that I can deal with abuse.
98. As a member, I want photos and art checked for objectionable content before a circle sees them, so that circles stay safe.

### Support
99. As a birder, I want a "Support Bird Journal" screen with a few one-time tips that unlock nothing, so that I can help cover the server and the painting machine if I want to.
100. As a birder, I want every feature free, so that the app never nags me to pay.

### Packs and licensing (maintainer)
101. As a maintainer, I want the pack builder to accept only open-license photos (CC0, CC BY, CC BY-SA) and search far enough back to find them, so that the packs carry no NonCommercial photos.
102. As a maintainer, I want reference sounds to keep their current license rules, so that most species keep both a song and a call.
103. As a maintainer, I want each pack to carry stats from AVONET, BIRDBASE and the avian wingspan database, joined through Avibase IDs with a committed list of manual name fixes, so that the stats are reproducible.
104. As a maintainer, I want lore generated from the fact sheet, reviewed and pinned in a committed lock with the facts it used, so that a rebuild never changes reviewed text silently.
105. As a maintainer, I want pack art painted on the GPU box from the pack's open-license photos in the pack's edition theme, reviewed on contact sheets and pinned in a lock, so that pack art is reproducible and reviewed.
106. As a maintainer, I want each pack and its index entry to carry the set definition (region boundary, species in taxonomic order, edition), so that sets work before a pack is downloaded.
107. As a maintainer, I want threatened status in the pack from BIRDBASE's IUCN field plus an override list, so that the secret-spot rule needs no network.
108. As a maintainer, I want a bake-off of the art model on about ten hard species before app work depends on it, so that the art plan is proven early.

### Backend and operations (maintainer)
109. As a maintainer, I want the backend defined in CDK beside the app and deployable with one command, with every resource tagged and a budget alarm, so that costs stay visible.
110. As a maintainer, I want the art worker to pull jobs over outbound connections only, so that nothing reaches into my home network.
111. As a maintainer, I want art jobs to wait while the GPU box is off and resume when it's back, so that downtime costs nothing but time.
112. As a maintainer, I want the auto-paint rules and the painting allowance in server configuration, so that I can move from the friends phase to a public launch without code changes.
113. As a maintainer, I want uploaded photos deleted within a day of their art job, so that the server never accumulates private pictures.

### Testing and development
114. As a developer, I want the collection rules tested as a pure function of sightings and set definitions, so that Legendary, sets and galleries are covered without a UI.
115. As a developer, I want what leaves the phone decided by a pure find policy with its own tests, so that the privacy rules are proven.
116. As a developer, I want the whole backend tested through its HTTP API in-process against local DynamoDB with fake APNs and a fake queue, so that the server rules are proven at one seam.
117. As a developer, I want screenshot launch flags for the new screens (cards, a gallery, a card back, the Legendary reveal, Circle, a feed, the tip jar), so that the simulator can show every state.
118. As a developer, I want a fake circle server for the app's tests and simulator runs, so that circle screens work without AWS.

## Implementation Decisions

### Posture and licenses (ADR-0001)
- The app stays free and non-commercial. Every feature is available to everyone. Tips are StoreKit consumables that unlock nothing.
- Pack photos move to open licenses only: CC0, CC BY and CC BY-SA. The pack builder's allowed license set becomes configurable per asset kind; the photo query asks the API for open licenses only, so the shortlist reaches back in time, and the cache keys include the license set. All five packs are rebuilt with version bumps and reviewed on contact sheets as before. Measured coverage: every pack keeps open-license photos for nearly every species (Los Angeles: 157 of 160 species have eight or more open observations); six species across the Deserts and Orlando packs have none and get pack art painted without a photo reference, reviewed, or a typographic card face if review fails.
- Reference sounds keep their rules: open licenses ranked ahead of NonCommercial, no-derivatives refused.
- Nothing on a card (art, stats, lore) may derive from a NonCommercial asset or a non-commercially licensed model. eBird and Birds of the World data are excluded.
- The share policy's shareable licenses and the credits wording gain CC BY-SA.

### The sighting and its card (Album schema 3)
- The sighting gains a stable identifier (a UUID; existing sightings get one in a custom migration stage), the method (Heard or Seen; every existing sighting migrates as Heard), the rarity snapshot (occurrence probability or none, label, calibration version, week of the year), the caption (text and generator version, or none), the art state (pack art preferred or not; scene art file and state; photo art file and state; the current art job's identifier, kind, state and attempts) and attached original photos beside the existing glasses photo. Migration from schema 2 is tested both ways, as schema 2's was.
- A card is not stored separately. It is the sighting plus what the collection derives (Legendary, set, collector number, edition) plus pack data (stats, type line, lore). Art retries and caption regeneration change the sighting's art and caption fields and never write another sighting.
- Card art precedence: approved photo art, then ready scene art unless "Use pack art" is set, then pack art, then the species' reference photo (labelled as now), then a typographic face.
- Method changes on the phone. Attaching a photo to a Heard card asks "Did you see it?" before switching to Seen.

### Collection (pure, in the Album module)
- Input: value snapshots of the sightings and the set definitions known to the phone (from the pack index and installed packs). Output: every card's Legendary flag, set, collector number and edition; per-set progress; the species gallery with its place filter and sort; counts for the Cards, Sightings and Species views.
- Legendary: the earliest surviving sighting of a species by confirmation time, ties broken by identifier. Deleting it passes Legendary to the next-earliest; deleting the last removes the species from the collection. No reveal is replayed.
- The Legendary reveal is an event of the add, not of the card: an add reveals only when no other surviving sighting of its species exists at that moment.
- Set membership: among the sets whose region boundary contains the sighting's coordinate and whose species list includes the species, the one with the smallest region wins (the Deserts set's Anza-Borrego sits inside San Diego County). Otherwise the sighting is Uncharted, as is any sighting with no location ("Place not recorded"). Membership is computed, so a newly published pack pulls older sightings into its set.
- Collector number: the species' 1-based position in its set's taxonomic order over the set's size ("021/160"). Uncharted cards show "Uncharted" and no number.
- Edition: non-Legendary cards show their set's edition name ("Coastal edition"); Legendary cards show "Legendary · Your first".
- The one-time "your collection so far" moment shows when the collection first computes with at least one sighting and its flag is unset.

### Recording an add
- The run's add path (shared by the lens and the phone) writes the sighting with its stable identifier, Heard, and the rarity snapshot taken from the geomodel at the sighting's coordinate and week, and returns whether the add made a Legendary and the card's collector number, for the lens and phone reveals.
- After the write, and never blocking it: the caption is generated, an art job is requested when the birder is signed in, a glasses photo exists and the auto-paint rule allows, and a find is queued in the outbox when the birder is signed in and not private.

### Rarity (Identification, ADR-0006)
- The geomodel's occurrence probability for the species at the coordinate and week, mapped to Common, Uncommon, Rare or Exceptional by versioned thresholds. Identification drops species below 0.03 when a location is known, so the thresholds are calibrated above that floor: computed once over the five packs' species, regions and all weeks, then committed with a calibration version. "Rare or rarer" means Rare or Exceptional.
- No location: no snapshot, and the card reads "Rarity unavailable for this place and season". Snapshots are never recomputed.

### Pack schema 4
- New data per species: stats; the fact sheet (short sourced facts); lore with its one-line tagline and sources; pack art (one image per species per pack, 3:4 portrait); the threatened flag; family and type line. New data per pack: the set definition (simplified region boundary from public-domain sources, such as US Census county and NPS park boundaries, or a hand-drawn polygon committed with the pack definition where a region is not a union of those; species in taxonomic order; edition name and art theme).
- The pack index carries each pack's set definition and schema version 4, so sets work before a pack is installed. The pack publish step also uploads small pack-art thumbnails to the art CDN, so a friend's phone can show any find's pack art without that pack.
- The reader opens schemas 2 to 4. A card whose species has no schema-4 data shows no stats, no lore and the reference photo, and the card says so.

### Stats and type line
- Sources, all CC BY 4.0 and credited on the card back and in Credits:
  - **AVONET**: mass, habitat, migration (resident, partial migrant, migrant), trophic niche (the diet icon) and primary lifestyle.
  - **BIRDBASE**: clutch range, nest type and IUCN status.
  - **Avian wingspan database (2026)**: the measured wingspan where present, else the predicted midpoint shown with "≈". Flightless species show none.
- The join goes from the BirdNET label's scientific name to an Avibase ID through AVONET's eBird/Clements sheet, then to the other datasets, with a committed list of manual fixes for splits and lumps. A pack build fails on an unmapped species unless the species is listed as a known gap.
- Lifespan and body length are not on cards: there is no open global source.
- Front: wingspan, weight and the diet icon. Back: habitat, migration, nest, clutch and lifestyle. Units follow the phone's measurement system.
- Type line: a group word from the taxonomic order ("Songbird", "Raptor", "Owl", "Waterfowl", "Shorebird", …) and a family word ("Finch", "Hawk"), both from committed hand-written mappings covering the families in the packs.

### Lore and captions
- **Fact sheet**: the species' stats plus up to about eight short facts drawn from its English Wikipedia article (CC BY-SA 4.0, already the description source, revision pinned) and the datasets, each with its source.
- **Lore**: 50–80 words in a mythic, legend-like voice, plus a tagline of 12 words or fewer, in which every claim traces to a fact sheet entry. It is generated at pack build by a Claude model through the Anthropic API (key in the developer's shell profile, never the repository). It is reviewed by hand and pinned in a committed lore lock with the facts it used; a rebuild regenerates only on request. It is licensed CC BY-SA 4.0 with the Wikipedia credits.
- **Caption**: one line of 18 words or fewer, generated on the phone with Apple's Foundation Models (guided generation) after the add. Its inputs are the fact sheet, the species, the season (from the date and hemisphere), the local time of day, the method and the place label (omitted for threatened species). It is stored on the sighting with the generator version. When the model is unavailable, the card shows the lore's tagline. Automatic finds don't carry the caption; shared cards do, as part of the card face.

### Art
- **Pack art**: painted on the GPU box at pack build, one image per species per pack in the pack's edition theme, with the pack's open-license photos as references and the style guide's prompt structure. It is reviewed on contact sheets, pinned in a pack-art lock with source photo IDs and the workflow version, and adds about 20–30 MB per pack. Legendary drama on pack art comes from the frame only.
- **Scene art**: the original glasses photo from the add, with faces blurred on the phone (Vision face detection) and metadata stripped. The species is painted in at a believable size and pose, with the pack's open-license photos of the species as references for anatomy; Legendary cards use a more dramatic-light prompt. It applies automatically when ready.
- **Photo art**: the birder chooses a glasses photo or a library photo and confirms the bird in it is the card's species (no automatic ID check in v2). The flow is generate, then compare the original and the art, then approve, Keep original or Try again, as in the style guide. Faces are blurred and metadata stripped before upload.
- **Art jobs**:
  - The phone creates a job (sighting identifier, kind, edition theme, Legendary flag) and uploads the input through a presigned PUT to a private bucket with a one-day lifecycle.
  - The job goes on an SQS queue with a dead-letter queue. The art worker claims it, paints it, uploads the output to the art bucket behind CloudFront (unguessable keys) and reports ready or failed with its worker token.
  - The phone learns through a silent push or by polling open jobs on launch, downloads the art and stores it with the sighting.
  - A job still queued after 7 days fails with Retry art. A retry is a new job for the same sighting, and the last ready art stays until the new one is ready.
- **Painted art retention (ADR-0004)**: kept on the server only while a find or shared card shows it, otherwise deleted once the phone has downloaded it.
- **Auto-paint rules** (server configuration):
  - Friends phase: every add with a glasses photo.
  - Public launch: Legendary and Rare-or-rarer adds automatically; other scene art and all photo art on request, within a daily allowance of 5 per account.
  - There is no paid fallback (ADR-0003).
- **Model and worker**:
  - The model is Qwen-Image-Edit-2511 (Apache 2.0), fp8 or Q8 with the 4-step Lightning LoRA (about 30–40 s per image on the RTX 3090 Ti), confirmed by a bake-off on about ten species: hard field marks (Black Phoebe), tiny birds (Anna's Hummingbird), raptors, and real glasses photos. A style LoRA trained on 30–50 approved images follows if prompting alone drifts. FLUX-family non-commercial models are excluded.
  - The art worker is a Python service on the box that long-polls the queue with an IAM user limited to that queue and the buckets' prefixes. It drives ComfyUI on the same box. ComfyUI is rebound from all interfaces to the box's tailnet address only, because pack art is painted from the maintainer's Mac over the tailnet at pack build.
  - The ComfyUI workflow and prompt templates are committed and versioned, and the version is stamped into each image's provenance.
  - Frames and text are composed in the app, never in the image.

### Accounts and the app client
- Accounts are optional (they unlock circles and art jobs). The Cognito user pool has Google and Sign in with Apple, the hosted UI, a public client and the authorization code grant with PKCE, redirecting to the app's existing URL scheme on its own path.
- The phone signs in with ASWebAuthenticationSession, keeps tokens in the Keychain and refreshes through the token endpoint. There is no Amplify dependency.
- Display name comes from the identity provider and is editable; avatars are initials only.
- Account deletion is in Settings. It deletes the account, memberships, invites, finds and their feed items, reactions, devices, art jobs and painted art. A circle the account created passes to its longest-standing remaining member, or is deleted when empty. The Cognito user is deleted and Apple tokens are revoked.
- Signing out stops publishing and keeps the journal and cards.

### Backend (ADR-0002, ADR-0004)
- **Stack**: one CDK (Python) stack in us-west-2, in this repository beside the app and the pack builder, with one environment until the public launch. It reuses ivan-parallax's constructs for the Cognito pool, private buckets behind CloudFront with OAC, queues with dead-letter queues, EventBridge Scheduler calling internal endpoints with a shared secret, the access-token verifier and the Google OAuth setup wizard. FastAPI runs on Lambda behind an API Gateway HTTP API, with DynamoDB on demand and Secrets Manager. Every resource is tagged, and there's a budget alarm.
- **Data**: one DynamoDB table serving these access patterns:
  - account by ID
  - circles by member, and members by circle (with joined and left times)
  - invite by token (expires after 7 days)
  - finds by owner
  - feed items by circle, newest first
  - reactions by find
  - goals by circle
  - devices by account (APNs token and environment)
  - mutes and blocks by account
  - digest buffer by recipient and friend
  - art jobs by ID and by owner
  - reports
- **API contract** (v1, JSON, bearer access token):
  - account: get, update and delete the signed-in account; register a device
  - circles: create, list, read, leave, remove a member (creator only), mute or unmute a circle or a friend
  - invites: create (returns a link and QR payload); accept
  - finds: put (idempotent, keyed by sighting ID); delete
  - circle reads: feed (paged), compare with a friend, goals (list and create custom; delete by the goal's or the circle's creator)
  - reactions: put and delete a fixed reaction kind on a find
  - art: request an upload URL; create, read and list open art jobs
  - safety: report a find or an account; block or unblock an account
  - internal: art job ready or failed (worker token); scheduled goal rollover and digest flush (shared secret)
- **Finds**:
  - The payload is decided on the phone by the find policy.
  - A find fans out a feed item to each circle the owner belongs to when it is written. Leaving keeps past items, and joining does not backfill.
  - A repeated put (method changed, art ready) updates the find and its feed items and sends no new push.
  - Delete removes the find, its feed items and its reactions.
  - Only sightings added while signed in and sharing are published automatically; older ones can be shared by hand.
- **Circle first**: computed at read time from the earliest surviving feed item of a species in a circle. The push decision uses "no earlier surviving item" at write time.
- **Goals**:
  - The automatic monthly goal is created by a scheduled job at the start of each month in the circle's time zone, which is set from the creator's device at creation. Its target is the larger of 5 and 115% of the distinct species found in the circle last month, rounded, and 10 in a circle's first month.
  - Custom goals have a title, a target, a start and an end.
  - Progress is distinct species among the circle's feed items inside the period. Completion is a notable find, pushed once.
- **Compare**: the friend's species with their best method (Seen beats Heard) from feed items in circles shared with the requester; the phone merges in its own collection.
- **Push**:
  - APNs over HTTP/2 with a token key from Secrets Manager.
  - Notable finds (Legendary, circle first, Rare or Exceptional, goal completed) push at once with an alert plus content-available, carrying a find summary for the friend banner.
  - Other finds go to a digest buffer per recipient and friend. A scheduled job flushes it every 15 minutes, but only when two hours have passed since that recipient's last push about that friend. The digest reads "Maya found 6 birds in Pasadena", using the most common place label.
  - Reactions push to the find's owner, collapsed per find within 10 minutes.
  - Mutes (per circle, per friend) and blocks suppress pushes and hide content. The owner is never pushed about their own finds.
- **Safety**: reports are stored and emailed to the maintainer through SES. Rekognition moderation runs on art-job inputs and outputs and on shared original photos, switched on by configuration for the public launch; a flagged image fails its job or is withheld from the circle.
- **Invite links**: `https://birdquest.matthewcelia.com/i/<token>`, served by CloudFront with an ACM certificate (us-east-1). The domain also serves the `apple-app-site-association` file, so the app's associated-domains entitlement opens the link in the app, and a static fallback page explains how to get the app. The QR code encodes the same URL. The domain's DNS is at SiteGround, not Route 53, so the CNAME and certificate-validation records are a manual step, and the privacy policy page lives on the same domain.
- **Costs**: idle cost of a few dollars a month, plus the art bucket and request charges. Push through APNs is free.

### The app's circle side
- **Find policy** (pure, beside the share policy):
  - Inputs: the sighting, its derived card facts, the sharing setting, the species' threatened flag and the place name.
  - Output: the find payload, or nothing.
  - Private means nothing unless the card is shared by hand.
  - The place label is a city or "a secret spot", never a coordinate.
  - The note and original photo are included only in a hand-shared card where chosen.
  - The payload always carries the species, method, time to the minute, Legendary and rarity flags, and the art reference (a pack-art thumbnail or the painted art's key).
- **Outbox**: pending find puts and deletes are persisted on the phone and retried with backoff while signed in and online. Deleting a sighting queues the delete; Legendary passing to another card publishes nothing.
- **Shared card**: the style guide's "A story to share" preview sheet: choose circles, include the note, include the original photo (off by default), include the city (on by default; off gives no place). The existing system share renders the card face instead of the postcard, under the same share policy rules.
- **Circle tab**:
  - signed-out invitation to sign in
  - circle list
  - circle page with the goal card, Recent finds or Compare birds, invite (link and QR through the share sheet), members, and settings (mute, leave, remove a member if creator, report, block)
  - a fake circle client behind the same protocol for tests and the simulator
- **Notifications**: permission is asked, with an explanation, when the birder creates or joins their first circle. Silent pushes refresh the feed and art jobs. A notable find arriving during a glasses run, foreground or background, becomes a friend banner on the lens. Whether a remote notification reaches a backgrounded run is checked on hardware.
- **Settings**: Account (sign in, sign out, delete account), "Share my finds automatically" (on by default; off is private), Support Bird Journal (three StoreKit 2 consumable tips and a thank-you, no server receipt, works signed out), and Credits (adds the stats datasets, lore sources and art provenance).
- **Screenshot flags**: launch flags seed cards, a Legendary reveal, a gallery of 15 cards, a card back, a circle with a feed and a goal, and the tip jar.

### Lens (LensSession)
- After an add, the details page's saved line reads "Your first House Finch" with a sparkle icon when the add made a Legendary, else "New card · 021/160" (or "New card · Uncharted"). It adds no page and no gesture, within the word budget.
- **Friend banner**:
  - A state machine event shows an overlay page like the problem page: the friend's name, the method, the species and the place label ("Maya heard a Black Phoebe · Pasadena").
  - It shows only over the species list or a photo page. It is held while the viewfinder, a details page or a playing sounds page is open, and shown when the wearer returns.
  - One at a time: a newer banner replaces an older one, and a banner held for more than 5 minutes is dropped.
  - A tap or swipe right dismisses it.

### Phasing
1. **Local cards (no backend)**: schema 3 and the method; the collection; rarity; pack schema 4 with stats, lore, sets and pack art; the open-license photo rebuild; the card UI with the flip, the gallery and the reveals; captions; the lens reveal.
2. **Accounts, circles and push**: the stack, sign-in, the find policy and outbox, the feed, reactions, goals, compare, push rules and the friend banner.
3. **Painted art**: the art worker, face blur, scene art and photo art, art jobs and moderation.
4. **Public launch requirements**: tips, account deletion, report and block, the painting allowance, the privacy policy, and Rekognition switched on.

The model bake-off runs in parallel with phase 1, before any app work depends on its output.

## Testing Decisions

- A good test drives a seam from outside with real inputs and asserts on observable outputs: what a person or the next system would see. No test asserts on private state, toolkit calls or DynamoDB key shapes.
- **Collection** (new, pure, Album): table-driven tests over sightings and set definitions:
  - Legendary by earliest surviving sighting, and passing on deletion
  - imports, with the one-time intro
  - two sightings of a species on the same day
  - the smallest region winning in an overlap
  - Uncharted, including no location
  - collector numbers and set progress
  - the gallery's filter and sort, and "3 of 15" within a filter
  
  Prior art: the `Journal` grouping and search tests.
- **Recording an add** (existing seam, run sightings and listening coordinator tests): an add writes a stable identifier, Heard and a rarity snapshot from the scripted location; it reports a Legendary only when no other surviving sighting of the species exists; and it queues a find only when signed in and sharing. Prior art: "an add records the latest fix".
- **Album migration** (existing): schema 2 to 3 assigns identifiers and Heard and keeps notes and frames, tested both ways as schema 2's was.
- **Rarity** (Identification): labels from the real geomodel at fixed coordinates and weeks against the committed calibration, including below-floor and missing-location cases. Prior art: the species filter tests.
- **Packs** (existing PackTests over the bundled pack, plus pytest in the pack builder):
  - PackTests: every species has stats or is a listed gap, has lore and a tagline, has pack art, and has a set position; no photo carries a NonCommercial license; schemas 2 to 4 open.
  - pytest: the license switch and its cache key; the dataset join with manual fixes and the failing unmapped species; the lore and pack-art locks surviving a rebuild unchanged; the set definition in the index.
- **Find policy** (new, pure): auto versus private versus hand-shared; city versus "a secret spot" for threatened species; never a coordinate; the note and original photo only when chosen; the Legendary and rarity flags. Prior art: the share policy tests.
- **Lens state machine** (existing): the saved line after an add (Legendary, numbered, Uncharted); the friend banner shown, held on the viewfinder, details and playing sounds pages, replaced, expired and dismissed. The Mock Device Kit smoke tests cover the adapter sending both. Prior art: the problem page and lens sound tests.
- **Backend HTTP API** (new, the one server seam): in-process FastAPI tests against local DynamoDB, with tokens signed by a test key, a fake APNs that records what it was asked to send, and a fake queue. They cover:
  - circles, invites, the cap, leaving and removal
  - finds fanning out, repeated puts, deletes, and no backfill on join
  - circle first, goals (automatic rollover and custom) and compare
  - which pushes go out (notable, digest timing, reactions, mutes, blocks, never to the owner)
  - the art job lifecycle (create, claim, ready, failed, expiry, retry), the allowance, and moderation switched on and off
  - account deletion leaving nothing behind
  
  Prior art: ivan-parallax's backend tests (in-process FastAPI over a containerized database).
- **Art worker**: one test of the job loop against a stub ComfyUI (submit the workflow with the inputs, upload the output, report ready; report failed on a ComfyUI error). Art quality is judged by the bake-off rubric (anatomy, field marks, style, scene plausibility), not by tests.
- **Caption writer**: behind a protocol with a fake. Tests check the fallback to the tagline and that the prompt carries only the fact sheet and the moment, with no place for a threatened species.
- **UI tests** (existing XCUITest target): real taps on the card flip, the gallery's Previous and Next with Back restoring the filter, the Legendary reveal after an add, and sign-in-free use of the Journal. Prior art: the journal UI tests.
- **On hardware** (DAT-SETUP-CHECKLIST.md): the lens saved line and friend banner on the glasses; whether a backgrounded glasses run receives a remote notification in time for the banner; whether the glasses mirror an ordinary iOS notification (post a local one); scene art from real glasses photos.

## Out of Scope

- Paywalls, subscriptions and any feature that requires paying (ADR-0001).
- Comments and free-text messages in circles; global leaderboards; public profiles, user search and follows.
- Trading or gifting cards, booster packs or random rewards, a play mode or duels: cards come only from real sightings.
- Syncing or backing up a private journal to the server; iPad, web and multi-device access (ADR-0004).
- A paid hosted art fallback; FLUX-family and other non-commercially licensed models.
- Automatic species verification of photos attached for photo art.
- Lifespan and body length on cards; eBird and Birds of the World data; GBIF occurrence tables.
- Wikimedia Commons as a photo source.
- Posting notifications to the glasses through the toolkit (there is no API for it).
- Android.
- Printing physical cards.

## Further Notes

- **Facts behind the decisions (2026-10-13)**:
  - **Pack photos**: about 97% of shipped photos are CC BY-NC. LA ships 19 open-license photos out of 794, yet open photos exist for nearly every species.
  - **Reference sounds**: about two-thirds are CC BY-NC-SA, and only 20–30 species per pack have both an open song and an open call.
  - **BirdNET+ V3.0 preview**: CC BY-SA 4.0, which permits commercial use, but its terms also say "Provided solely for research and evaluation". An email to the BirdNET team before any public release is still worthwhile. The geomodel is Apache-2.0.
  - **Image models**: Qwen-Image-Edit-2511 is Apache 2.0. FLUX.2 [klein] 9B and FLUX.1 Kontext [dev] are non-commercial in a way that excludes end-user-facing use.
  - **The GPU box**: `comfybox`, RTX 3090 Ti 24 GB, ComfyUI 0.34. No edit model is installed yet, and the API is open on all interfaces with no authentication.
  - **Glasses notifications**: the toolkit cannot post notifications; Meta lists mirrored notifications as coming soon, and whether ordinary iOS notifications reach the display today is unverified.
  - **Hosting**: ivan-parallax's App Runner and RDS shape idles at about $53 a month.
- **Changes from the style guide v0.2**:
  - The running "No. 021" becomes a collector number and a type line.
  - Heard or Seen moves out of the confirm flow and onto the phone afterwards.
  - Scene art applies automatically; only photo art needs the birder's approval.
  - Sharing goes from manual-only to automatic by default, with a private setting.
  - Rarity labels replace the 0–100 score on the card.
  - Lore and the caption replace the "colorful description".
- **The wingspan database**: its measured columns include values transcribed from Birds of the World and HANZAB. They are used as facts with the dataset's CC BY 4.0 credit; revisit if ADR-0001 is ever reopened.
- **Foundation Models** need Apple Intelligence on the device. The tagline fallback makes captions an enhancement, never a dependency.
