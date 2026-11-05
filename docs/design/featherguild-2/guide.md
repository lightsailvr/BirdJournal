# Featherguild design guide 2.0 (patches): page text

The text of every page of *Design Guide 2.0* (November 3, 2026), extracted from its source. The boards themselves are in [pages/](pages/).

## Page 1

Approved direction / November 2026 · supersedes 1.0
Featherguild
Sewn from
real encounters.
A collecting adventure you can almost hold. The first time you find a bird somewhere, you sew its embroidered patch for that place. Every patch turns over to a paper card with the bird's story and your history with it.
Patches, not cards. One for every bird, in every place you find it.
Editions you can see at a glance. Light that comes from the room.
DESIGN & IMPLEMENTATION HANDOFF · VERSION 2.0 · PATCHES
Concepts and a clickable prototype. No app code changed.
FEATHERGUILD / DESIGN GUIDE 2.0
NOVEMBER 3, 2026
01

## Page 2

Read this first
What changes, and what stays
The new direction
01
Patches replace cards
The thing you collect is an embroidered patch: twill, satin-stitched bird, the edition's motif, a merrowed cord. It is the object on every collection surface.
02
It turns over to a paper card
Tap a patch and it flips to a collectible paper card: story title, lore, the encounter, real biology, your note and the sources.
03
The app does the lighting
Patches are lit by the device's tilt, with real relief and a moving shadow. The painting is only colour.
04
Editions have their own patch
Shape, cord colour, twill and motif belong to the set. A House Finch from Los Angeles is a round olive-corded patch; from Orlando, a teal-corded shield.
05
One patch, then the count
Your first sighting of a bird in an edition sews its patch. Later sightings there add to its count. Legendary and the gold border are retired: every patch is the one patch.
06
Skeuomorphic, on purpose
Guide 1.0 asked for "tactile without skeuomorphism". The maintainer reversed that on November 3, 2026. Material is now welcome, for the objects you collect.
Carried forward from 1.0
The four places: Listen, Collection, Atlas, Guilds, with native navigation and controls.
Every Add is one sighting, saved before any stitching or art. A patch is created only by the first sighting of a species in an edition; art retries create nothing.
Rarity stays words, never a frame. (Legendary is retired, page 12.)
Sets count distinct species; collector numbers are positions, not serials.
Lore, art and evidence stay separate truths. Original photos are evidence; patches are illustration, labelled.
Guild rules, privacy, and the share and location policy.
Dynamic Type, VoiceOver, Reduce Motion, complete states.
Where they differ, this guide wins. Pages 5 to 8 and 15 of 1.0 (the story-first card fronts) are superseded by the patch and its paper card. The app shell, tokens and flows of 1.0 remain the reference for everything this guide doesn't redraw.

## Page 3

The journey
From a call to a patch in your hand
01Ready
02A call
03Review and add
04Stitching
05Your patch
06Seen again
07The patch board
08The patch
09The paper card
10Two editions
11Atlas
12Share
13Guild

## Page 4

The journey · 01–03
Finding a bird
01 Ready to listenThe set's cover, one action, the glasses' state. The local set shows as its blank patches: what this place collects, before you have found anything.
02 A callA bird new to this edition shows its pattern, the transfer-pen outline on bare twill. A bird you already have here shows your patch and its count.
03 Review and addThe credited reference photo, field marks, Heard by default. For a new bird the action reads Add and sew patch; the sighting is saved at once.
On the glassesThe lens shows the candidate, "new here" or "seen 7 times", and one action.

## Page 5

The journey · 04–06
One patch, then the count
04 StitchingThe first time you find a bird in an edition, its patch sews itself in about four seconds: one thread colour at a time, the cord last. A haptic tick at each thread.
05 Your patchThe finished patch on felt, lit by the room: "Your first Acorn Woodpecker in Los Angeles." No tier, no gold. Getting the patch is the reward.
06 Seen againA bird you already have sews nothing new. Its patch lifts, the count ticks from 7 to 8, and the sighting joins its history. The review button reads Add sighting.
On the glasses"Seen again · 8 times in Los Angeles", or "New patch · sewn" after a first.

## Page 6

The journey · 07–09
Your patches, and the story behind each
07 The patch boardCollection opens on the set you're in: one patch per bird you've found there, in collector-number order, each with its count, and the patterns of the ones still to find.
08 The patchOpened, a patch gets the screen, lit by the tilt. Name, edition and your count are set in type below it, never stitched. Tap the patch, or Turn over.
09 The paper cardTurned over: the story title and lore from the pack, biology, and your history with the bird here: sewn Sep 14, seen 8 times, the latest sightings.

## Page 7

The journey · 10–11
A different place, a different patch
10 Two editionsThe same House Finch, two patches: a round Citrus patch from Los Angeles (seen 8 times) and a Wetland shield from Orlando (seen twice). The other editions show as patterns.
11 AtlasEach set shows its patch family beside its progress and download state. Downloading adds the field guide, never patches.
A new environment is a new patch
On a card, an edition was a label. On a patch it's the silhouette: you can tell a Wetland patch from a Citrus one across a board before you can read a word. Travelling for birds becomes visible, and a bird you know well is worth finding again somewhere new.
Rules
One patch per species per edition, sewn by your first sighting of it there.
Later sightings in that edition add to that patch's count, never a new patch.
A sighting outside every set adds to the bird's Uncharted patch, a plain natural-canvas round (page 15).

## Page 8

The journey · 12–13
Sharing what you've sewn
12 ShareA composed object: the patch on linen with its paper card tucked beneath, lit from a fixed upper-left light. Notes stay off by default, the place is city-level, credits travel with it.
13 GuildA new patch is a find, led by the member's patch. A repeat sighting is a quieter "seen again" line. "First for the Guild" is a small aqua label.
Carried forward
Guild progress counts distinct species in the period. Reactions and Compare birds are the roadmap; no chat is implied. Threatened species follow the secret-spot policy, on the patch as everywhere else.
The share image
Rendered on device, never a screenshot: the patch at 1080 px with the share light, its paper card's front (name, story title, edition, date, "AI illustration"), and the Featherguild wordmark small. Exports keep credits and the lore licence.

## Page 9

Patch anatomy
Make it feel like a patch
01
The ground
Cotton twill in the edition's colour, its diagonal rib visible between the stitches. Bare twill is what a not-yet-found patch shows.
02
The bird, in satin stitch
Long-and-short stitches follow each feather tract; the eye is a glossy black dot with one white highlight stitch. The bird comes from the species' reference photo and keeps its markings exactly. Thread may simplify a pattern; it may never change one.
03
The edition's motif
A few fill-stitched shapes behind the bird: citrus leaves and chaparral hills, kelp and sea cliffs, fog and redwoods, Joshua trees, cypress and palmetto. Quiet, flat and few.
04
The merrowed cord
A raised, overlocked border in the edition's colour. It catches the most light.
05
Nothing written in thread
No names, numbers or letters on the patch. Thread can't carry small type, and type has to stay readable and accessible: the name lives beside the patch and on its paper card.
06
One footprint per edition
Every patch in an edition has the same shape and size, so a board reads as a set.

## Page 10

The reverse
The paper card behind the patch
Anatomy, top to bottom
Edition line: the edition's name and the collector number (003 / 160).
Species name in serif, the scientific name in italic.
Story title from the pack's reviewed lore ("Carver of the Crowded Hollow"), upright serif.
Lore excerpt in true italic, 15–16 pt; the full lore opens below on scroll.
Biology: wingspan (≈ where estimated), weight, diet, nest, clutch, size, from the pack.
Your history here: the count ("8 sightings here"), when it was sewn, and the latest sightings (date, Heard or Seen, city-level place), each opening its record with your note and photo.
Footer: "All 8 sightings", "AI illustration", and Sources, which opens credits.
Material
Heavy warm ivory cotton stock (#F1EBDD under a fibre texture), deep-teal ink, a fine inner keyline and a slot punched at the top, like the backer a patch is sold on. It's printed matter: no embossing, foil or glows.
Behaviour
The flip rotates the whole object about its vertical axis in about 600 ms, keeping one footprint (330 × 470 pt at default text size).
Reduce Motion cross-fades; VoiceOver reads only the face showing.
At accessibility text sizes the card grows into a scrolling reading view. Lore is never shrunk to keep the shape.
Sightings, notes, photos, full lore and sources open from the card; the patch face never hosts controls.

## Page 11

Editions
Every place sews its own patch
EditionSetShapeCordTwillStitched motif (from the set's theme)
| Citrus | Los Angeles | Circle |
Olive green | Tan | Citrus leaves, chaparral hills, a warm golden sky
| Coastal | San Diego | Upright oval |
Deep sea-blue | Pale sky-blue | Sandstone sea cliffs, kelp, a soft hazy sky
| Fog | Bay Area | Hexagon, flat top and bottom |
Silver-grey | Cool pale grey | Fog over oak hills, a few redwoods
| Desert | California Desert | Arch: round top, flat bottom |
Terracotta-rose | Warm sand | A Joshua tree, a fan palm, a rose-gold dusk
| Wetland | Orlando | Shield, soft point below |
Deep teal | Pearl white | Cypress, saw palmetto, a misty lagoon
A new set chooses a shape not yet taken (a rounded square, a diamond, a scalloped round and a pennant remain) and a cord colour distinct from its neighbours'. The patch spec lives beside the set's edition theme in pack.json.

## Page 12

The collecting rule
One patch per bird, per place
01
The first sighting sews the patch
The first time you add a bird in an edition, its patch is sewn and is yours for good. That is the collectible, and the only one: no tiers, no Legendary, no duplicates, no gold.
02
Later sightings add to its count
Adding the same bird again in that edition records a sighting and ticks the patch's count: "seen 8 times in Los Angeles". Nothing new is sewn.
03
A new place is a new patch
The same bird in another edition sews that edition's patch, with its own count. The species view gathers a bird's patches across places.
04
Sightings remain the record
Every sighting is still a dated entry with its place, method, note and photo, in the Sightings journal and on the patch's paper card. A patch's "sewn" date is its earliest surviving sighting.
05
Deleting
Deleting a sighting lowers the count. Deleting the last sighting of a bird in an edition unpicks that patch, after a confirmation that says so.
06
Progress counts patches
A set's progress is the patches sewn in it: 6 of 160. Rarity, where shown, stays words on the paper card ("Common here this season"), never a frame.

## Page 13

Light and material
The app does the lighting
Tilted toward the light
Held flat
Tilted away
Colour: the painting, cut out on transparency
Height: thread relief plus the raised cord
Cord mask: where the strongest sheen goes
Stitch order: light first, dark last, cord at the end
How it's lit
Diffuse shading and a soft specular sheen from the height map, with the light's direction from the device's attitude (Core Motion), smoothed and clamped to ±35°.
A two-part shadow (contact and soft) that falls opposite the light.
Production: a SwiftUI layerEffect Metal shader sampling the colour, height and cord textures. The prototype does the same with SVG lighting filters.
The light moves only when you move. No idle glints. Reduce Motion fixes it upper-left.
Material belongs to collected objects: patches, the felt board, the paper card, the share image. Controls, lists and navigation stay native and matte.

## Page 14

Motion and accessibility
A small ceremony, sewn once
The stitch-in
About 4.2 s for a first: bare twill and its blue transfer pattern, then one thread colour at a time, largest fills first and fine dark details after, then the cord merrowed round from the top. Each new thread is named in the caption with a swatch, with a light haptic tick. Tap anywhere to finish. It happens once per bird per edition; a repeat sighting sews nothing and its count ticks up.
The flip and the reveal
The flip turns the object about its vertical axis in about 600 ms with one footprint. The new-patch reveal is the finished patch on felt, "New patch · Citrus edition", and "Your first Acorn Woodpecker in Los Angeles." A repeat sighting gets only the count ticking up. No confetti, rays or orbit sparkles; the moving light is the delight. It is never replayed.
Usable by everyone
Reduce Motion: no stitching, no flip rotation, fixed light.
VoiceOver: "House Finch, Citrus edition patch, seen 8 times, sewn September 14." Hints: "Turn over for its story."
Dynamic Type: names and story text grow; the board drops to two columns, then one.
Increase Contrast: board labels move onto a solid surface, the felt darkens.

## Page 15

States
Every state has a patch
Patterns: the Citrus patch before it's sewn, the bird traced in transfer pen. Northern Mockingbird, Lesser Goldfinch, Spotted Towhee, Oak Titmouse.
StateWhat shows
| Not yet found | The edition's blank with the bird's outline in transfer pen, its name and number. A path to the Atlas profile. It's an honest silhouette, not a lock.
| Candidate | A bird new to the edition shows its pattern until Add; a bird you already have there shows your patch and its count.
| Being sewn | The sighting is saved. If the patch art isn't on the device yet (a new edition's art downloading), the blank shows with "Being sewn" and fills in when it arrives.
| Art failed or missing | The edition's blank with the species name on a small paper tag tied through the slot. Never an error patch; the sighting and paper card are complete.
| Uncharted (no set) | A plain round natural-canvas patch with a brown cord and the bird; the card says "Uncharted · outside every set".
| Offline, no location, denied permissions, glasses disconnected | As 1.0: truthful, recoverable, in plain words. Never shown as stitched decoration.
| Empty collection | The felt board with the local set's first patterns and "Your first patch is a bird away."

## Page 16

Typography and colour
Native type, real materials
Typography (unchanged from 1.0)
| Page title | System serif (New York) largeTitle, ~34 pt
| Bird name | System serif, upright, ~24–28 pt
| Story title (paper card) | System serif, upright, ~19–22 pt
| Lore | True italic serif, ~15–16 pt, open leading
| Functional UI | SF Pro, ~17 pt; supporting 13–15 pt
No stitched or embossed type, no faux-letterpress fonts: the paper card's printed feel comes from its stock, keyline and layout. Type in the app is always live text.
App tokens (unchanged)
Page #10292D
Raised #193A3D
Ivory #F5F1E7
Aqua #BCE3D9
Shared goal #B9BEDD
Legendary #D3B475 · retired
Material tokens (new)
Board felt | Deep petrol wool felt, a texture under a 60% #081A1D veil, so the board sits in the page colour.
Card stock | Warm ivory cotton paper #F1EBDD with fibre texture; ink #15363A.
Share linen | Undyed linen, for share images only.
Shadow | Contact: 2 pt, 50% black. Soft: 9 pt offset by the light, 10 pt blur, 38%.
Light appearance: the board becomes oatmeal linen, the shadow lightens to 28%, patches and paper are unchanged. Bird thread keeps its true colours in both appearances.

## Page 17

Patch art
Painting a patch, and keeping the bird true
The pipeline (replaces pack art; ADR-0007's model)
FLUX.3 Image Klein on comfybox paints one patch per species per edition from the species' isolated reference bird, with the edition's shape, cord, twill and motif. It lies flat on white card under even light: the app adds the light. The prompt never names the species.
The patch is cut from the card. Every shape is convex, so a flood fill from the edge plus a convex hull is exact. (BiRefNet sometimes cut out the bird instead.)
The layers are made: colour, height, a cord mask 25 px deep at 720 px, and the stitch order.
The fidelity gate and the per-channel colour fit run on the bird inside the patch, as for pack art. The maintainer approves patches on contact sheets, and a lock pins them.
The watercolour pack art, scene art and photo art are retired (page 20), so the patch is the only painting in the app. Cost: about 14 s a patch. Each pack's own species in its own edition comes to roughly 800 patches for the five sets, about 3 hours of painting (791 species) plus review.
What the samples showed
Light, well-lit references hold their markings well in thread (woodpecker, quail, bluebird, egret, finch).
Dark and dim references fail. The black phoebe became a pale-faced, tan-and-black bird on three seeds; the cedar waxwing lost its yellow belly and mask and gained stripes. Thread lightens dark plumage and invents contrast.
Telling the model to keep black birds black overcorrected the House Finch: its blue-grey belly went black. So it's not in the prompt.
Black Phoebe: reference → patch (rejected)
Cedar Waxwing: reference → patch (rejected)
House Finch: reference → "black thread" prompt (rejected) → final

## Page 18

Implementation handoff
Build the patch experience
Agent brief
Evolve Featherguild's SwiftUI app from story-first cards to embroidered patches using this guide and the dev branch. Keep identification, listening, persistence and the glasses. The collectible becomes a patch: one per species per edition, created by the first sighting of that species in that edition; later sightings add to its count. Legendary is retired. A patch is drawn from its species-and-edition painting in the pack with app-side lighting (height map, tilt, shadow); tapping it flips to a paper card with the pack's lore, biology, and the bird's sighting history there. Extend the pack builder to paint, gate and lock patch art per edition. Validate on device, with screenshots and the UI tests.
Delivery order
1
Patch art in the pack builder
Edition patch specs in pack.json; paint, cut, layer, gate, review and lock. Start with Los Angeles; reject dark references until the gate passes them.
2
The lit patch view
A PatchView with a Metal layerEffect and the Core Motion light; Reduce Motion and Increase Contrast.
3
Board, patch and paper card
The Collection board, the patch detail with the flip, the paper card replacing the card front and back.
4
The ceremony and the rest
The stitch-in, the reveal, editions in the species view and Atlas, share images, Guild finds, all states.
Verify before merging
Every Add is one sighting; art and stitching never create or lose one.
Existing cards migrate to one patch per species per edition, every card becoming a sighting with its note and photo intact; Legendary flags are dropped.
Only the first sighting of a species in an edition creates a patch; later ones add to its count; deleting the last sighting unpicks it.
Each edition's patches share one shape and footprint; no text in thread.
The bird's markings pass the gate on every shipped patch; dark birds are checked by hand.
The light follows tilt and stops when the phone does; Reduce Motion fixes it.
VoiceOver reads one face; lore is readable at normal and large sizes.
Share exports keep credits, the AI-illustration label and the location policy.
Frame time stays at 120 Hz on the board with 30 lit patches (one light uniform, thumbnails pre-lit).

## Page 19

Design prompts
Keep the direction reproducible
Patch prompt (FLUX.3, a caption of the result)
A product photograph of an embroidered patch shaped like {shape}, photographed from directly above, lying flat in the middle of plain white card under soft, even, diffuse light, with only a faint shadow. The patch is {twill} finished with a thick raised merrowed border of overlocked {cord} thread all the way around its edge. On it is embroidered the bird from <ref_image_0>, exactly as it appears there: the same pose and angle, the same feather pattern, colours and markings, the same bill, eye, legs and proportions, and the same sex and age, nothing added and nothing taken away, rendered entirely in thread. Only the bird comes from <ref_image_0>. Its feathers are laid in dense long-and-short satin stitches whose direction follows each feather tract… It perches on a small embroidered branch. Behind it, inside the patch, a few simple fill-stitched shapes suggest {motif}. … No text, letters, numbers or logos anywhere. No other birds, animals or people.
Pattern (not-yet-found) prompt
The same patch, unfinished: nothing embroidered inside yet; on the bare twill the outline of the bird from <ref_image_0>, in its pose and proportions, traced in thin, faint blue transfer-pen lines.
App-screen prompt
Design a native iOS Featherguild screen for [flow]. Deep petrol or warm porcelain surfaces, restrained serif headings, SF controls. Collected birds appear as embroidered patches in their edition's shape and cord, lit from the upper left, resting on deep-petrol felt; their stories are on ivory paper cards. Controls and lists stay flat and native.
Avoid list
Casino cues, purchased scarcity, XP, currencies, loot boxes, booster packs, randomized reveals. Medieval armour, heraldry, ornate filigree, neon, oversized reward effects, confetti. Stitched or embossed text, fake stitching on buttons, felt behind lists, leather, wood grain or brushed metal on chrome. Idle glints or perpetual shimmer. Never invent anatomy, field marks, behaviour or sighting facts, and never name the species in an art prompt.

## Page 20

Decisions and record
Open questions, sources and credits
Decisions for the maintainer
1
What is a "place"?
This guide takes a place to be an edition, which is a regional set. Should a big set ever split (say, coast and mountains inside Los Angeles), or should sightings outside every set each sew an Uncharted patch per species, as proposed?
2
Decided: the patch is the only art
On November 3, 2026 the maintainer retired the watercolour pack art (the patch replaces it, which also frees the pack's size budget for patch art), and scene art and photo art. A sighting keeps its original photos as evidence.
3
The lens
Show a small patch image on the glasses after a new patch, and the count after a repeat, as mocked, or keep the lens text-only?
4
Words
Keep "Collection", or rename its first mode "Patches" (as mocked)? "Sew" or "Add" on the review button?
Sources
Featherguild Design Guide 1.0 (November 1, 2026; docs/design/featherguild/), which this guide supersedes where they differ. The Los Angeles pack (lore, story titles, biology, collector numbers, set covers); the editions' themes from each pack's pack.json. The patch exploration of November 3 (build/patch-explore/) chose the merit-badge style.
Art and lore credits
Patches were painted with FLUX.3 Image Klein on comfybox from credited reference photographs, isolated as for pack art: Acorn Woodpecker, Cristhian Mace (CC BY); House Finch, Lachlan Copeland (CC BY-SA); Anna's Hummingbird, Trey Philips (CC BY); California Quail, Cory Butterfield (CC BY); Western Bluebird, Guy Babineau (CC BY); Great Egret, Cameron (CC BY); the patterns from the pack's references for their species. The review photo is by Nathan Nguyen (CC BY). Felt, paper and linen textures were painted from text alone. Lore and story titles are the pack's reviewed text, adapted from Wikipedia contributors (CC BY-SA 4.0). Sample sightings, members and progress are illustrative.
Screens are a clickable HTML prototype (build/badge-guide/prototype/), captured in Chrome; the SVG lighting stands in for the production Metal shader. Board renders are concept images, not dimensioned templates.
