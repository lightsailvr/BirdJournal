# Featherguild

Bird identification on Meta Ray-Ban Display glasses, a field journal on the phone, and a collection of embroidered patches earned from real sightings (one per bird per place) and shared with small circles of friends.

## Names

**Featherguild**:
The product's name, everywhere a person reads it: the home screen, the launch splash, Settings, permission prompts, the lens, share captions, pushes, invites and the site. Since 2026-11-02.
_Avoid_: Bird Journal, My Bird Journal, BirdJournal (in copy), Bird Quest (the design guide's dropped working name)

**BirdJournal**:
The internal name, which stays: the repository, the bundle ID `com.matthewcelia.mybirdjournal`, the targets and schemes, `BirdJournalKit` and its modules, Keychain items, the `birdjournal_api` backend package, the `BirdJournal` stack and its `project=birdjournal` tags, the `birdjournal://` scheme, and asset names such as `MyBirdJournal-*`.
_Avoid_: using it in anything a person reads

The user-facing words for three places differ from the internal ones, which code, models, endpoints and routes keep:

| User-facing | Internal | Where |
|---|---|---|
| **Collection** | Journal | the tab with a birder's patches, sightings and species (`Journal/`); "Collection" below is already the domain word for all of one birder's patches |
| **Atlas**, "Field guide & sets" | Field Guide | the tab with every species, the sets and the field-guide downloads (`Guide/`, `Packs/`) |
| **Guild** | Circle | the invite-only group (`Circles/`, `Circle*` models, `/v1/circles` routes) |

### Words a birder reads

One word for each thing, in every string, VoiceOver label and error (#150). The words below the headings of this file are the domain's and may be what the code says; this table is what a person reads. Internal identifiers keep their names.

| Word in copy | Means | Retired from copy |
|---|---|---|
| **Set** | A place's collection of birds | board, region |
| **Edition** | How a set's patches look | |
| **Place** | Plain English for where you are | |
| **Field-guide download** | What a pack is, to a birder ("the download" or "the field guide" once it's clear; the page's title is "Downloads") | pack |
| **Patch**, **paper card** | The collectible and its reverse | card, on its own |
| **Sewn** | What a bird in a set is once you have its patch: "3 of 160 sewn" | species collected |
| **Still out there** | A bird in a set you haven't found: "157 still out there", once on a page | not yet found here |
| **Plate** | A set's painted cover printed on card stock in the Atlas, with its margin, keyline and credit | cover, on a page of the Atlas |

Kept word for word: "Wonder is nearby.", "Your first patch is a bird away.", "Fourteen birds, together.", "First for the Guild", "Jealous!", "Possible matches. Add the birds you recognize.", and since #185 "Capture a sighting", "Name this bird" and "Seen this run".

## Listening

**Run**:
One listening session, from Start to Stop, on the glasses or the phone microphone.
_Avoid_: session (the toolkit's word for the device connection), outing

**Candidate**:
A species BirdNET has heard convincingly during a run and that the birder can review.
_Avoid_: detection, match, suggestion

**Add**:
The birder's explicit confirmation of a bird: of a candidate, from the lens or the phone, or of a bird they saw, by naming their photo of it (#185). Every add writes a new sighting.
_Avoid_: save, log, confirm

**Sighting**:
One add of one species at a time and place, owned by the birder who added it. The unit everything in the collection hangs off.
_Avoid_: encounter (UI copy only), observation, entry, record

**Method**:
How the birder met the bird on a sighting: Heard or Seen. An add of a candidate is Heard unless the birder says otherwise; a sighting named by the birder is Seen.
_Avoid_: evidence, detection type

**Named by the birder**:
What a sighting is when the birder named its bird themselves, from their photo of it, and BirdNET heard nothing to match (#186). It is always Seen and has no match score, and nothing shows one for it: not the run, its page, its paper card or a share. In every other way it is a sighting like any other: it sews its patch or adds to its count, counts toward its set, and is published as a find that says "saw". The sighting carries the mark (`namedByBirder`).
_Avoid_: manual sighting, unverified sighting, self-reported

**Likely here**:
What a bird is at a place and week when the geomodel's occurrence for it there is at or above the floor identification admits a bird at. "Name this bird" lists the likeliest of the field guides' birds under "Likely here now", after "Heard this run" (the run's candidates), and orders a search by the same two (#189). Not rarity, which is a label saved on a sighting.
_Avoid_: probable, expected, common here (Common is a rarity label), suggestion (in copy)

**Original photo**:
The unaltered picture kept with a sighting: the glasses' photo from the add, or one of the birder's own, which is the photo a seen bird was named from (taken with the capture camera on the phone, #186) or one attached from the library. Evidence, never art.
_Avoid_: snapshot (as a synonym for art), frame (the stream frame is only a fallback for it)

## Packs

**Pack**:
A downloadable bundle for one set's place: species, photos, reference sounds, descriptions, stats, lore and patches. In copy, a field-guide download.
_Avoid_: region pack, bundle, dataset

**Reference sound**:
A recorded song or call of a species shipped in a pack, for the birder to compare with what they hear.
_Avoid_: clip (in domain language), sample

**Fact sheet**:
The sourced facts a pack holds for a species. Lore and captions may state nothing that is not on it.
_Avoid_: species data, facts table

**Stats**:
The real natural-history numbers and traits printed on a card: wingspan, weight, diet, habitat, migration, nest, clutch, lifestyle.
_Avoid_: abilities, power, attributes

**Type line**:
A card's family line in a trading-card style, such as "Songbird — Finch".
_Avoid_: category, class

## Collection

**Patch**:
The collectible: one per species per placement (a set, or Uncharted), derived from the sightings and never stored. The first surviving sighting of a species in a set sews its patch there; every later sighting there adds to its count; the same species in another set has that set's patch. Deleting the last sighting of a species in a set unpicks the patch. Since 2026-11-03 (#131, design guide 2.0).
_Avoid_: badge, card (for the collectible), sticker, achievement

**Pattern**:
A patch before it is stitched: bare twill, out to the edge since the cord comes last, and the patch's own stitch lines in blue transfer pen, drawn by the app. Only where a patch is being sewn (#135): a bird you haven't found has no patch, and no pattern, on any board.
_Avoid_: locked patch, silhouette, ghost

**Stitch-in**:
The ceremony of an add that sews a patch: about 4.2 s from its pattern, one thread colour at a time along the pack's stitch order, the cord last. The sighting is saved before it starts. It plays once, on the phone: at the add, or for an add on the lens, when the run is over and the app is next in front; reopening a patch never shows it. Reduce Motion and VoiceOver go straight to the finished patch. A repeat sighting has none: its count ticks in the acknowledgment, with nothing to tap.
_Avoid_: animation, unlock

**Board**:
Your patches in one place in Collection, on felt across the whole sheet, in collector-number order; Uncharted has one too. A bird you haven't found isn't on it. The internal word: in copy it's the set.
_Avoid_: grid, shelf

**Blank**:
An edition's shape and cord drawn by the app when the phone has no painting of a bird you did find there: its name on a paper tag, or "Being sewn" while its pack downloads. Uncharted's is the plain canvas round. Never an error patch, and never shown for a bird you haven't found (#138).

**Not yet found**:
A bird in a set with no patch of yours there. It has no patch or pattern anywhere: only a silhouette row on the set's page in the Atlas, with its number and name, and its own no-sightings page. Not a state of any board. In copy, "still out there".

**Count**:
How many surviving sightings a patch has: "Seen 8 times in Los Angeles".
_Avoid_: duplicates, copies, level

**Sewn**:
What the sighting that created a patch did; a patch's sewn date is its earliest surviving sighting's.
_Avoid_: unlocked, earned (for a patch)

**Card**:
In copy always the paper card (#150). The paper card a patch turns over to (#134): its story, the species' biology and your history with the bird there. One per patch, never stored. The share image draws its front, on linen beneath the patch (#136). Art, captions and retries never make another.
_Avoid_: trading card, edition (for the card itself), the collectible (that is the patch)

**Collection**:
All of one birder's patches, and the sightings behind them.
_Avoid_: deck, album, life list

**Legendary** (retired 2026-11-03, #131):
Was the status of a birder's earliest surviving card of a species, with a gold frame. Retired with the gold: every patch is the one patch for its bird and place. A find says `new_patch` since #136; the old name lives on only in the compatibility seam for the server deployed before it, and in the art job until #137.
_Avoid_: in copy

**Rarity**:
How unusual a species is at a sighting's place and week, saved at the add as a label: Common, Uncommon, Rare or Exceptional.
_Avoid_: score, frequency, abundance

**Set**:
A place's collection of birds: the species of one pack, in taxonomic order, which a birder collects toward. Its progress counts the patches sewn in it. Sightings outside every set belong to the Uncharted set.
_Avoid_: region, board (in copy), collection (for a set), checklist

**Collector number**:
A species' position in its set, shown as "021/160" on its own, and "No. 021" beside a name on a board or a paper card, as design guide 2.0 sets it.
_Avoid_: card number

**Edition**:
How a set's patches look, named on them and on their paper cards, such as "Coastal edition"; since #131 also their shape, cord, twill and stitched motif.
_Avoid_: variant, version

**Lore**:
A species' short myth-voiced text built from its fact sheet, written once per pack and reviewed, shown on the paper card.
_Avoid_: flavor text, description (the Wikipedia summary), story

**Story title**:
Two to five words heading a species' lore on the paper card, an epithet from what the bird does ("The Waterside Mason"), written and reviewed with the lore; it never names the species.
_Avoid_: name, heading, tagline

**Caption**:
One line written for a sighting on the phone, from the fact sheet and the moment, shown on the sighting's page.
_Avoid_: flavor text, tagline (the lore's one-line fallback)

## Art

The patch is the only painting (decided 2026-11-03, built in #137). Original photos stay as evidence: the glasses photo from the add, the photo a seen bird was named from (#186), or one the birder attaches from the library.

**Pack art**:
Was a watercolour of a species shipped with its pack and shown on its card. The app no longer shows it; a pack not yet rebuilt with patches (#58) still carries it, unused, and shows the edition's blank patch.

**Scene art**:
Was the species painted into the original photo from the glasses at the add. Retired; nothing paints it. A stored sighting keeps its art state, unread.

**Photo art**:
Was the birder's own photo of the bird embellished by AI for its card. Retired with scene art.

**Art job**:
Was one request to paint scene art or photo art. Retired, with the server's allowance and auto-paint rule.

**Art worker**:
Was the program on the home GPU box that took art jobs from the queue. Retired. Patches are painted on the same box, by the pack builder.

## Circles

**Account**:
A birder's optional sign-in identity, through Apple or Google, needed only for circles.
_Avoid_: user, profile, login

**Circle**:
An invite-only group of up to 20 accounts that see each other's finds and share goals. The only social unit.
_Avoid_: group, club, friends list

**Friend**:
Anyone who shares at least one circle with you.
_Avoid_: follower, contact, connection

**Find**:
What a circle sees of a member's sighting: species, method, place label, time, whether it sewed a new patch and in which edition, and art. Sent automatically unless the member is private.
_Avoid_: post, activity, share

**Shared card**:
A card a member sends to a circle by hand, which may add the note and the original photo.
_Avoid_: post, share (as a noun)

**Private**:
A member's setting that stops automatic finds; only shared cards reach their circles.
_Avoid_: incognito, hidden mode

**Place label**:
The place a find shows: a city, or "a secret spot" for a threatened species. Never a coordinate.
_Avoid_: location (the coordinate on the phone), area

**Circle first**:
The earliest surviving find of a species in a circle, shown as "First for the Guild". Separate from any member's new patch.
_Avoid_: circle legendary, first find

**Goal**:
A number of distinct species a circle aims to find within a period: the automatic monthly goal or a custom one a member sets.
_Avoid_: challenge, quest, target (as the noun)

**Reaction**:
One of a fixed set of responses a friend can leave on a find: "Lovely find", "Jealous!" or "Let's go together". Never on one's own find, never with words.
_Avoid_: like, comment

**Compare birds**:
You and a friend side by side, each species Heard, Seen or not yet: the friend's side from their finds in circles you share, yours from the collection on your phone.
_Avoid_: leaderboard, ranking, life list comparison

**Notable find**:
A find that sends its own push: a new patch, a circle first, Rare or Exceptional rarity, or one that completes a goal.
_Avoid_: highlight, alert

**Digest**:
One push bundling a friend's other finds, at most one per friend every two hours.
_Avoid_: summary, batch

**Mute**:
A member's choice to get no pushes about one circle's or one friend's finds. The feed still shows them.
_Avoid_: block (which also hides content), silence

**Friend banner**:
A notable find shown on the lens while the birder is on a run.
_Avoid_: lens notification

**Tip**:
A voluntary in-app payment that unlocks nothing and helps keep the server running.
_Avoid_: donation, purchase, subscription
