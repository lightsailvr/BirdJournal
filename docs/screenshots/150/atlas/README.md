# UX cohesion slice 9: the Atlas as a book, the app half (issue #150)

Every picture is the running app on an iPhone 17 Pro simulator at half size, taken by `capture.sh`, at the default text size (`large`), or the largest where the name ends in `-ax5`. `sheets/` holds the contact sheets the PR shows, with the reference first where there is one.

| Pick | The change | Shots |
|---|---|---|
| A1 | Covers as plates on card stock, with a margin, a keyline and the credit: set tiles, set pages, pack pages | `sheets/set-against-reference`, `sheets/plates`: `set-*`, `atlas-*`, `pack-dark`, `packs-dark` |
| A3 | True silhouettes, tinted at draw time; one heading with the count; the glyph with no pack | `sheets/silhouettes`: `set-rows-dark`, `set-mixed-dark`, `set-no-pack-dark` |
| A5 | Flat patches on the map in the edition's shape, clustered; pins in the place's tint | `sheets/map`: `map-*`, `map-cluster-dark`, `map-editions-dark`; `record-patch-*` for the card's marker |
| A6 | The record: patch or photo first, when, where and how on paper, rarity and identification in disclosures | `sheets/record`: `record-patch-*`, `record-photo-dark`, `record-disclosures-dark` |
| F12 | A first photo's slot is the photo's shape, so the whole bird shows | `sheets/first-photos`: `photo-*` |
| | The largest text size and Increase Contrast | `sheets/ax5`, `sheets/contrast` |

## Where it differs from the reference

- The "AI illustration" credit under the picture, about 14 pt more plate: the issue asks for it and the mock leaves it out.
- The margins are the app's 22 pt against the mock's 24 at scale.
- `MO`, a friend's face, belongs to slice 8. The space after a row's name is free for it, and no face is faked.
- The reference's third bird is No. 061 and the page here is in collector order with whatever's seeded: the same rows, different birds.
- Its page has no search; here it's there when you pull down.

## Decodes under a moving light

`decode-counts.txt`, from `capture.sh`, as in `../hunt/README.md`: each surface with the light sweeping, counting two 8 s windows of the log, then the patch decodes in the last minute. `count-*.jpg` shows what was on screen.

```
A set's rows, silhouettes and patches (`count-set`): first window: 5 lines, 0 patch decodes, 0 AV1 or ImageIO lines. 20 s later: 22 lines, 0 patch decodes, 0 AV1 or ImageIO lines. Patch decodes in the last minute: 4.
The map's markers (`count-map`): first window: 9 lines, 0 patch decodes, 0 AV1 or ImageIO lines. 20 s later: 1 lines, 0 patch decodes, 0 AV1 or ImageIO lines. Patch decodes in the last minute: 6.
A record's patch (`count-record`): first window: 3 lines, 0 patch decodes, 0 AV1 or ImageIO lines. 20 s later: 22 lines, 0 patch decodes, 0 AV1 or ImageIO lines. Patch decodes in the last minute: 2.
```

Each patch is two decodes, its colour and its layers, once each: 2 patches on the set's rows, 3 on the map and 1 on the record. Both windows show 0 decodes and 0 AV1 or ImageIO lines, where a thumbnail re-decoding under a moving shader would log about the frame rate. A silhouette and a map marker aren't under a shader at all.

## Not proven here

By hand on a phone, as the issue lists them: panning and pinching the map with hundreds of sightings, the map's clusters as they form and part, and the feel of scrolling a set's rows at 120 Hz.
