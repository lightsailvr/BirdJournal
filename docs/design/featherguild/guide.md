# Featherguild design guide 1.0: page text

The text of every page of *Design Guide 1.0* (November 1, 2026), extracted from the PDF. The guide was drawn up under the working name "Bird Quest"; read it as **Featherguild**. The boards themselves are in [pages/](pages/).


## Page 1

APPROVED DIRECTION / NOVEMBER 2026
Bird Quest
01
A field guide
to wonder.
A refined collecting adventure,
built around real birds and the
stories we find together.
Story-first cards. Intimate Guilds.
Light and dark appearances.
A quieter kind of magic.
DESIGN & IMPLEMENTATION HANDOFF
Version 1.0
Concepts reviewed in this workshop.
No app code changed.


## Page 2

READ THIS FIRST
What to carry forward
02
The endorsed direction
Modern, warm and quietly mythical. The current watercolor art stays
central. Deep teal gives it presence; warm ivory gives the stories room
to breathe.
The latest card is the reference
Use the story-first card fronts on pages 5-6. Each has a tangible
perimeter, a species name, a memorable story title, and a small italic
lore passage on the front.
The typography correction matters
The description should feel like a passage from a storybook: smaller
true italic serif, generous leading, and readable dark ink. Keep bird
names and story headings upright.
HOW TO USE THIS GUIDE
03-06
Visual direction & latest cards
07-09
Card anatomy, type & color
10-14
Navigation and product flows
15-16
Discovery, motion & accessibility
17-20
Content, handoff, prompts & credits
Earlier screen boards remain useful for the app shell, Guilds and
interaction ideas. Their simpler card fronts are superseded by pages
5-6. The latest written rules take priority over incidental raster details.
Review baseline
Inspected dev commit 788c06a, completed card/art/set work, and the
Circles screenshots in PR #92. Guilds is the requested product name;
current code still uses Circles. Feeds, reactions and goals are shown as
proposed experiences and were open work at review time.


## Page 3

VISUAL REFERENCE
A little more wonder
03
Listen, collection and a future Guild home. Use this app shell with the latest story-first card design on pages 5-6.


## Page 4

VISUAL REFERENCE
Out in the daylight
04
Light appearance: active listening, Atlas and Guilds. Sample progress and social activity; the regional packs exist.


## Page 5

LATEST CARD DIRECTION
Every card has a story
05
Latest endorsed card direction: consistent frames, upright titles, and smaller italic lore passages. Story titles are proposed editorial additions.


## Page 6

LATEST CARD DIRECTION
From collection to story
06
Simplify at thumbnail size; reveal the readable story on opening. The opened card uses the endorsed smaller italic lore.


## Page 7

CARD ANATOMY
Make it feel like a card
07
01  A recognizable object
Use a consistent portrait shape, modest corner radius, visible outer edge and a fine
inner keyline. A classic 5:7 ratio is a starting target; readability takes priority. The
generated references are not dimensioned templates.
02  A set identity
Edition label, subtle regional botanical motif and collector number connect the objects.
Keep the same anatomy across species. Reserve the gold edge for Legendary
personal firsts.
03  The bird, then the tale
The common name stays obvious. The painting remains generous. A distinct story title
leads into roughly 25-40 words of lore on the front. Keep species identity and
imaginative framing separate.
04  A quiet personal imprint
Place, date and Heard/Seen anchor the card to a real sighting. Keep this footer quieter
than the story. Art generation or retries never create another card.
05  A deeper reverse
The back holds full lore, your note, original photo, real biology stats, rarity explanation
and sources. Moving stats off the front is the proposed story-first change.


## Page 8

TYPOGRAPHY
A little tale, not a data block
08
STORY SPECIMEN
Black Phoebe
The Waterside Mason
Wherever the black phoebe keeps house, water is
close by. To build, it needs mud, cementing an open
cup beneath a cliff or bridge.
The specimen uses Georgia italic as a PDF approximation. In the app,
prefer the system serif / New York with native text styles and a true italic
trait.
PRODUCTION STARTING POINTS
Page title
~32-34 pt
System serif largeTitle
Bird name
~24-28 pt
System serif, upright
Story title
~19-22 pt
System serif, upright
Lore excerpt
~15-16 pt
True italic serif
Functional UI
~17 pt
System sans serif
Supporting detail
~13-15 pt
System sans serif
Scale with the reader. Use Dynamic Type and wrap. At accessibility sizes,
grow the card or switch to a comfortable reading layout. Do not preserve a
miniature card ratio by shrinking the lore.
Thumbnail rule: show the bird and story title. Omit the paragraph rather
than shrinking it into decorative microtext. All app controls stay in the
system sans serif even if a generated board approximates them
differently.


## Page 9

VISUAL SYSTEM
Color with a purpose
09
DARK APPEARANCE
LIGHT APPEARANCE
Page
#10292D
Page
#F4F2E9
Raised surface
#193A3D
Raised surface
#DFEAE5
Primary text
#F5F1E7
Primary text
#15363A
Primary action
#BCE3D9
Primary action
#15363A
Shared-goal accent
#B9BEDD
Shared-goal accent
#E8E6F0
Legendary detail
#D3B475
Legendary detail
#886424
Gold has one job: personal-first Legendary status. Use aqua or a
muted local color for Guild emblems, and a quiet lavender accent for
shared goals. Rarity is explained in words; it does not inherit the
Legendary frame.
Production validation: these are starting tokens, not measured
compliance results. Check contrast, Increase Contrast and
transparent surfaces in the native app. Keep bird art in its natural
colors across appearances.


## Page 10

INFORMATION ARCHITECTURE
Four places, one adventure
10
01
Listen
Start and stop a run.
Review birds and add cards.
02
Collection
Your cards, sightings
and species galleries.
03
Atlas
Field guide, regional sets
and offline bird packs.
04
Guilds
Invite-only groups,
shared finds and goals.
Collection replaces the Journal label
The journal is still here as the Sightings mode. Cards is the collecting
view; Species gathers repeated sightings of one bird. Keep the three
modes stable and preserve filters, sorting and scroll position when
returning.
Atlas needs a plain-language subtitle
Use "Field guide & regional sets" so the more evocative name stays
understandable. Keep searching and learning available for birds not
yet collected; a silhouette is not a locked paywall.
Use native navigation
Keep four labeled tabs at the root and ordinary back navigation. Hide
the global tab bar when inspecting an individual card if it would cover
the card or reading area. A visible Flip action complements the art
tap.
Treat naming as a deliberate migration
Guilds is the requested product language. Update user-facing copy
consistently when adopted. Internal Circle models and endpoints can
retain their existing names until a separate migration is justified.


## Page 11

LISTEN
Listening should leave room for the world
11
Ready
One obvious Start listening action, the chosen microphones, connection state and a relevant
local-set invitation. The atmospheric cover belongs chiefly to this calm ready state.
Active
Reduce decoration as results arrive. Prioritize source, time, Calling now, candidates and an
always-reachable Stop action. The landscape in the concept can collapse to make room for
long lists.
Review and add
A candidate is not a saved card. Open its bird information, then use the explicit Add action.
Heard is the default; Seen is changed deliberately. Keep reference art separate from original
evidence.
After adding
First personal species: a short Legendary reveal. Repeat sighting: a quieter acknowledgment.
A card is already persisted before art, celebration or sharing begins.
Away from this tab
Keep a compact listening accessory available while browsing Collection, Atlas or Guilds.
Truthful connection and interruption states take priority over decoration.


## Page 12

COLLECTION RULES
Collect moments, complete sets
12
Every add is one card
Repeat sightings remain distinct dated cards. Changing art or
retrying an art job changes that card, never the sighting count.
Legendary is personal
The earliest surviving card of a species is Legendary. It can still be
Common locally. Deleting it passes Legendary to the next-earliest
card according to the existing collection rules.
A regional set is a collection goal
Progress counts distinct species in that set, not repeat cards. The
collector number is a species position, not a minted serial or claim of
artificial scarcity.
Browse at two scales
Use a readable two-column collection grid, falling back to one at
large text sizes. Keep the front-frame identity and story title in the
grid. Open a card to read its full excerpt.
Retain the encounter gallery
For a frequently found species, preserve place filters, sort order,
count and previous/next navigation. Fifteen House Finch cards
should feel like fifteen memories, not fifteen tabs.
Give unknowns honest form
Uncollected birds can have accurate silhouettes plus names and a
path to the guide. Missing art, no recorded place and unknown rarity
get a designed text fallback; they never prevent a card being saved.
Avoid rarity ladders, paid booster packs, streak-loss penalties, randomized reveals, or repeated confetti. The collectibility comes from real discovery, distinct memories,
regional art and stories.


## Page 13

GUILDS
A Guild is a place to discover together
13
Lead with belonging
A simple nature-derived emblem, habitat cover, member presence and an invitation action
give each small group an identity. Emblems are a proposed visual layer, not ranks or
purchased upgrades.
Make progress shared
A monthly or custom goal counts distinct species in its defined period. Show "23 of 30 species"
and "7 still to discover". Use calm progress, not urgency, countdown pressure or a global
leaderboard.
Put finds in the foreground
Lead the feed with artwork, the member, bird, method, time and city-level place label. Keep
member administration and settings secondary. "First for the Guild" stays separate from a
personal Legendary.
Use the planned social mechanics
Fixed reactions and Compare birds are the existing roadmap direction. No chat box or
freeform comments are implied. A comparison helps plan a walk rather than ranking members.
Keep sharing visible
Expose the automatic-sharing/private setting and preview manual shares. Notes and original
photos stay private unless explicitly included. Threatened species use the established
secret-spot policy.


## Page 14

ATLAS & FIELD GUIDE
An atlas you can take outside
14
Regional covers carry the atmosphere
Give each set a recognizable landscape and color story: Citrus, Coastal, Fog, Desert or
Wetland. The covers are illustrative; they are not maps or evidence of the sighting location.
Separate collecting from downloading
Species collected is personal progress. Ready offline is installed content status. A download
adds reference material, not birds to the collection. Label size and transfer progress plainly.
Keep learning generous
Profiles combine sourced descriptions, diagnostic field marks, reference photos, sounds, stats
and lore where the pack provides them. The poetic card is an invitation into trustworthy natural
history.
Credit where the work appears
Use a compact Source / Art & sources entry beside art, then full photographer, license,
source, modification and model information on the detailed credits screen. Do not present
generated art as an original photo.
Plan for the field
Offline, missing content, interrupted transfer, failed installation and low storage all need useful
recovery. Removing a pack must not remove personal sightings, notes or original
photographs.


## Page 15

INTERACTION REFERENCE / FRONT SUPERSEDED
A small ceremony, once
15
Interaction study: preserve the calm reveal and reverse structure, but apply the latest story-first front and italic lore from pages 5-8.


## Page 16

MOTION, ACCESSIBILITY & STATES
Delight that stays usable
16
The flip
Rotate the same card around its vertical axis, with both faces aligned
and a stable footprint. The current ~480 ms behavior is a useful
baseline. Expose only the readable face to VoiceOver. Reduce
Motion switches faces without rotation.
The first-discovery moment
One quiet reveal after a successful Add: the card, "Your first", a
restrained orbit motif and a light optional haptic. Keep listening is the
primary return. Reopening the card does not replay the celebration.
Living artwork, restrained interface
Use only brief, purposeful movement. Do not add perpetual glints,
tilting cards, parallax bird motion or flashing rarity effects. Keep
meaningful card information available without animation.
Readable at real size
Use Dynamic Type, comfortable touch targets, visible labels and
strong contrast. Fine printed details are decorative; small metadata in
raster mockups is not a production size specification.
A front that can grow
If the italic passage or bird name needs more room, grow the layout,
shorten the approved excerpt or open a reading view. Do not clip the
tale or shrink it to preserve a fixed card silhouette.
Complete state coverage
Design no cards yet, no Guilds yet, signed out, offline, no location,
unknown rarity, art pending/failed, empty filters, denied permissions
and disconnected glasses. Art failure cannot lose the saved sighting.


## Page 17

LORE, ART & PROVENANCE
The magic lives in the telling
17
A STORY BUILT ON REAL FACTS
The Waterside Mason
Wherever the black phoebe keeps house, water is close
by. To build, it needs mud, cementing an open cup
beneath a cliff or bridge.
A new editorial title, followed by an excerpt from the existing approved pack
lore. The framing is imaginative; the bird's biology must remain sourced.
Suggested content structure
Story title: 2-5 words.
Front excerpt: about 25-40 words.
Full lore: the current reviewed 50-80 word text.
Personal note: written by the birder.
Sources: retained with the underlying text.
Preserve the current art investment
The Los Angeles v8 pack contains 160 approved paintings and lore
entries. These concepts adapt its watercolor/gouache art. Generated
mockups can alter details; production should render the approved
source asset directly.
Keep three kinds of truth separate
Species lore describes the bird. The dated card describes one sighting.
An original photo is evidence; pack art or embellished art is labeled as
illustration. None substitutes for the others.
Editorial titles are proposed data
"The Waterside Mason", "The Orchard Singer" and "The White
Architect" are design proposals, not existing species names or claims of
new behavior. Store and review them as editorial content if adopted.
Keep full attribution reachable
The front can carry a compact AI illustration / Source label; the reverse
expands it. Preserve source licenses, original-photo provenance and
lore revision links in both the app and shared exports.


## Page 18

IMPLEMENTATION HANDOFF
Build the approved experience
18
Agent brief
Evolve Bird Quest's existing SwiftUI app using this guide and the current dev branch. Preserve identification, listening, persistence and
glasses behavior. Implement the latest story-first collectible front with smaller italic lore, a readable reverse, deep-teal and daylight
appearances, and the Collection / Atlas / Guilds navigation proposal. Reuse existing packs, art provenance and collection semantics.
Integrate social roadmap features as they become available; do not simulate them as shipped behavior. Validate on real native layouts
and capture screenshots for review.
DELIVERY ORDER
1  Design tokens and card typography
Make the story-first card and accessible compact/full layouts the first
implementation slice.
2  Collection and app shell
Carry the visual language through listening, sets and navigation while
retaining stable data behavior.
3  Guilds and Atlas
Use real social services and pack metadata. Add identity and habitat
covers without inventing mechanics.
4  States and evidence
Finish both appearances, accessibility and edge states. Review
running-app captures against the latest boards.
VERIFY BEFORE MERGING
Existing cards and original photos survive migration.
Every Add creates one card; art retries create none.
Legendary and rarity remain distinct.
The front excerpt is readable at normal and large text sizes.
Guild progress counts distinct species; privacy controls are explicit.
Share exports preserve credits and location policy.
No normal-flow page exposes developer diagnostics.


## Page 19

DESIGN PROMPTS
Keep the direction reproducible
19
App-screen prompt
Design a refined native iOS Bird Quest screen for [flow]. Use deep
petrol or warm porcelain surfaces, restrained serif headings and
system sans-serif controls. Preserve the app's approved
natural-history watercolor art. Let habitat imagery, meaningful
collecting progress and small Guild identity details provide wonder.
Keep operational copy literal, navigation familiar and art attribution
accessible.
Story-card prompt
Create a cohesive collectible card front for [species] using the
approved pack artwork. Include the species name, edition or
personal-first Legendary label, collector number, a proposed short
story title and a reviewed lore excerpt. Use a fine perimeter, a
restrained regional motif and a quiet dated footer. Keep biology
measurements and full sources on the reverse.
Typography refinement prompt
Change only the lore paragraph. Make it visibly smaller, in a true
literary italic serif, with open leading, generous side margins and dark
readable ink. Preserve the words, paintings, borders, species names
and upright story titles. Aim for approximately 15-16 pt at full card
scale, with Dynamic Type adaptation in production.
Avoid list
No casino cues, purchased scarcity, XP, currencies, loot boxes,
medieval armor, ornate filigree, neon glows or oversized reward
effects. Do not invent bird anatomy, field marks, behaviors or sighting
facts. Do not shrink long paragraphs into illegible thumbnail text.
Exact archive included. The complete generation and revision prompts are embedded in this PDF as bird-quest-design-prompts.md. They are also saved beside the
guide. The smaller-italic revisions are the latest instructions. All visual concepts were made with the built-in image-generation tool.


## Page 20

REFERENCE RECORD
Sources and acknowledgments
20
REPOSITORY & SCREEN EVIDENCE
Review baseline: dev commit 788c06a
PR #91: pack art and card screenshots
PR #92: Circles and membership screens
PR #77: sets, numbers and silhouettes
PR #87: lore and captions
Roadmap #48; feed #62; reactions #64; goals #65
Los Angeles v8 pack and source LICENSE
The screenshots were inspected from the completed work, rather than inferred
from ticket titles. Current code still calls Guilds Circles; release account/social
access was gated pending account deletion (#71/#88). The social mockups
depict the intended future experience.
Apple HIG: Typography
Apple HIG: Accessibility
ART & LORE CREDITS
Existing pack paintings were generated with FLUX.3 Image Klein from credited
reference photographs. These design boards adapt those paintings with the
built-in image-generation tool. Photographic reference credits recorded in the
pack:
Black Phoebe - Stephen Matthews / CC0
House Finch - Lachlan Copeland / CC BY-SA
Anna's Hummingbird - Trey Philips / CC BY
Great Egret - Cameron / CC BY
License labels above reproduce pack metadata; follow each source for its exact
terms. Preserve attribution and applicable ShareAlike terms for adapted source
artwork. No claim is made that a generated mockup is an original photograph.
Lore excerpts come from the reviewed Los Angeles v8 pack: AI-written and
hand-reviewed adaptations of Wikipedia contributors' text, credited CC BY-SA
4.0. The displayed story titles are new design proposals.
House Finch - pinned Wikipedia revision
Black Phoebe - pinned Wikipedia revision
Great Egret - pinned Wikipedia revision
Guide date: November 1, 2026. Sample members, progress, dates and rarity are illustrative. All boards are raster design concepts, not running-app screenshots or audited production
layouts.
