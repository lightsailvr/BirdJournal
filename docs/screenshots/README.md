# docs/screenshots/

Simulator screenshots of the phone screens, one folder per capture date, written by `scripts/screenshots.sh` at half
size (an iPhone 17 simulator, iOS 27). They are review evidence for the field-journal UX of issue #28, not design
references: `docs/design/` on the `docs/field-journal-design-2026-09-27` branch holds the boards.

File names are `<screen>-<appearance>.png` (`light`, `dark`), `<screen>-xxxl.png` (the largest non-accessibility
Dynamic Type size) and `<screen>-ax5.png` (the largest accessibility size); `journal-empty` and `listen-empty` are
the first-launch states. The journal screens run on `-seedJournal YES` sample sightings with generated frames (a green
field with a ring, standing in for a glasses camera frame); the listening screens are driven by the labeled clip from
`scripts/download-clips.sh` through the phone-microphone path. Hardware states (a glasses run, pause, reconnect) are
not pictured: DAT-SETUP-CHECKLIST.md step 9 verifies them on the glasses.

`2026-10-02/` is the evidence for issue #42 (calling-now order): the mock lens list with the newest caller marked
(`lens-list-calling`), the same list after the one-shot re-send cleared the lapsed marker (`lens-list-lapsed`), a
details page naming the bird calling now (`lens-details-now`), and the Listen tab with two rows calling and the same
rows twenty seconds later, aged and reordered (`listening-calling-dark`, `listening-aged-dark`); the lens shots are
the Developer hub's mock preview, full size.

The same folder holds the evidence for issue #44 (a fresh location, the spot on a map), full size from an iPhone 18 Pro
simulator with a simulated Griffith Park fix: the sighting detail with the map card under the Where row
(`sighting-map-card-dark`), the full map sheet with the opened sighting's pin selected, two smaller pins and the callout
(`sighting-map-dark`), and the Listen tab with the place line under the summary (`listening-place-dark`).

`2026-11-01-pack-art/` is the evidence for issue #57 (pack art), half size from an iPhone 17 simulator with
`-inMemoryAlbum YES -seedJournal YES -autoScreen card`: a Legendary card, the Black Phoebe, the seeded journal's only one
(`legendary-card`), an edition card, the newer of the two House Finches, labelled "Citrus edition" (`edition-card`),
and its back with the Art section naming FLUX.3 Image Klein and the reference photo's photographer (`edition-card-back`).
Both fronts show the Los Angeles v7 pack art labelled "AI illustration".

`116/` is the evidence for issue #116 (Featherguild slice 1: the tokens and the story-first card), half size from an
iPhone 17 Pro simulator (iOS 27.2) on Los Angeles v10 (with the story titles) with `-inMemoryAlbum YES -seedJournal YES`, reduced to 256 colours. Each screen is
in `dark`, `light` and `ax3` (light at accessibility extra large), numbered top to bottom where the screen scrolls:
- `front-legendary`: the Black Phoebe, the seeded journal's Legendary card with the caption, from `-autoScreen card
  -autoCardSpecies "Sayornis nigricans"`
- `front`: the newer of the two House Finches, a Citrus edition card
- `back`: its back, scrolling inside the card's footprint
- `grid`: the Cards view
- `share`: "A story to share" with the rendered card
- `reveal`: the Legendary reveal

Compare them with page 5 of `docs/design/featherguild/`.

`117/` is the evidence for issue #117 (Featherguild slice 2: Collection, Listen and the app shell), half size from an
iPhone 17 Pro simulator (iOS 27.2) on Los Angeles v10 (with its cover) with `-inMemoryAlbum YES -seedJournal YES`. Each
screen is in `dark`, `light` and `ax3` (light at accessibility extra large):
- `listen-ready`: the ready state under the Los Angeles cover, with the local set (`-autoScreen listen`)
- `listen-active`: a phone run over the example soundscape, location denied (`-autoScreen listening`)
- `reveal`: the Legendary reveal of the Black Phoebe over that run (`-autoScreen reveal -autoCardSpecies "Sayornis
  nigricans" -autoPhoneListening <wav>`)
- `cards`, `sightings`, `species`: Collection's three modes
- `card`: a card's page, the tab bar hidden (`-autoScreen card`)

Compare them with pages 3, 4, 6 and 15 of `docs/design/featherguild/`.
