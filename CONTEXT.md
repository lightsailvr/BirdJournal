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
| **Collection** | Journal | the tab with a birder's cards, sightings and species (`Journal/`); "Collection" below is already the domain word for all of one birder's cards |
| **Atlas**, "Field guide & regional sets" | Field Guide | the tab with every species, the sets and the packs (`Guide/`, `Packs/`) |
| **Guild** | Circle | the invite-only group (`Circles/`, `Circle*` models, `/v1/circles` routes) |

The tabs still read Journal, Field Guide and Circles until #117 renames them; Circle is Guild in every user-facing string since #118 (pages, invites, pushes, the invite site).

## Listening

**Run**:
One listening session, from Start to Stop, on the glasses or the phone microphone.
_Avoid_: session (the toolkit's word for the device connection), outing

**Candidate**:
A species BirdNET has heard convincingly during a run and that the birder can review.
_Avoid_: detection, match, suggestion

**Add**:
The birder's explicit confirmation of a candidate, from the lens or the phone. Every add writes a new sighting.
_Avoid_: save, log, confirm

**Sighting**:
One add of one species at a time and place, owned by the birder who added it. The unit everything in the collection hangs off.
_Avoid_: encounter (UI copy only), observation, entry, record

**Method**:
How the birder met the bird on a sighting: Heard or Seen. Heard unless the birder says otherwise.
_Avoid_: evidence, detection type

**Original photo**:
The unaltered picture kept with a sighting: the glasses' photo from the add, or one the birder attached. Evidence, never art.
_Avoid_: snapshot (as a synonym for art), frame (the stream frame is only a fallback for it)

## Packs

**Pack**:
A downloadable bundle for one region: species, photos, reference sounds, descriptions, stats, lore and pack art.
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
A patch before it is stitched: the cord, bare twill and the patch's own stitch lines in blue transfer pen, drawn by the app. Only where a patch is being sewn (#135): a bird you haven't found has no patch, and no pattern, on any board.
_Avoid_: locked patch, silhouette, ghost

**Board**:
Your patches in one place in Collection, on felt across the whole sheet, in collector-number order; Uncharted has one too. A bird you haven't found isn't on it.
_Avoid_: grid, shelf

**Blank**:
An edition's shape and cord drawn by the app when the phone has no painting of the bird there. It may carry a paper tag with the bird's name. Never an error patch.

**Count**:
How many surviving sightings a patch has: "Seen 8 times in Los Angeles".
_Avoid_: duplicates, copies, level

**Sewn**:
What the sighting that created a patch did; a patch's sewn date is its earliest surviving sighting's.
_Avoid_: unlocked, earned (for a patch)

**Card**:
The paper card a patch turns over to (#134): its story, the species' biology and your history with the bird there. One per patch, never stored. The share image still draws one sighting's card face until #136. Art, captions and retries never make another.
_Avoid_: trading card, edition (for the card itself), the collectible (that is the patch)

**Collection**:
All of one birder's patches, and the sightings behind them.
_Avoid_: deck, album, life list

**Legendary** (retired 2026-11-03, #131):
Was the status of a birder's earliest surviving card of a species, with a gold frame. Retired with the gold: every patch is the one patch for its bird and place. The finds' `legendary` flag carries "sewed a patch" until #136 renames it.
_Avoid_: in copy

**Rarity**:
How unusual a species is at a sighting's place and week, saved at the add as a label: Common, Uncommon, Rare or Exceptional.
_Avoid_: score, frequency, abundance

**Set**:
The species of one pack's region, in taxonomic order, which a birder collects toward: its progress counts the patches sewn in it. Sightings outside every set belong to the Uncharted set.
_Avoid_: region, collection (for a set), checklist

**Collector number**:
A species' position in its set, shown as "021/160" on its own, and "No. 021" beside a name on a board or a paper card, as design guide 2.0 sets it.
_Avoid_: card number

**Edition**:
The regional look of a set, named on its patches and cards, such as "Coastal edition"; since #131 also its patches' shape, cord, twill and stitched motif.
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

**Card art**:
The picture on a card's front: pack art, scene art or photo art.
_Avoid_: image, illustration (in domain language)

**Pack art**:
A painted image of a species in its set's edition theme, shipped with the pack and shown the moment a card exists.
_Avoid_: stock art, default art, placeholder

**Scene art**:
The species painted into the original photo from the glasses at the add. Applied automatically when ready.
_Avoid_: local edition, composite

**Photo art**:
The birder's own photo of the bird embellished into card art, applied only after the birder approves a preview.
_Avoid_: filter, enhanced photo

**Art job**:
One request to paint scene art or photo art for an existing card. A retry is a new art job for the same card.
_Avoid_: render, generation, task

**Art worker**:
The program on the home GPU box that takes art jobs from the queue and paints them.
_Avoid_: comfybox (the host's name), painter, renderer

## Circles

**Account**:
A birder's optional sign-in identity, through Apple or Google, needed only for circles and art jobs.
_Avoid_: user, profile, login

**Circle**:
An invite-only group of up to 20 accounts that see each other's finds and share goals. The only social unit.
_Avoid_: group, club, friends list

**Friend**:
Anyone who shares at least one circle with you.
_Avoid_: follower, contact, connection

**Find**:
What a circle sees of a member's sighting: species, method, place label, time and card art. Sent automatically unless the member is private.
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
The earliest surviving find of a species in a circle, shown as "First for the Guild". Separate from any member's Legendary.
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
A find that sends its own push: a Legendary, a circle first, Rare or Exceptional rarity, or one that completes a goal.
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
A voluntary in-app payment that unlocks nothing and helps cover hosting and painting.
_Avoid_: donation, purchase, subscription
