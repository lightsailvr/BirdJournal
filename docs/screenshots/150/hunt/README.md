# UX cohesion slice 5: patch means yours, and the hunt (issue #150)

Every picture is the running app on an iPhone 17 Pro simulator (iOS 27.2) at half size, taken by `capture.sh`, at the default text size (`large`), or the largest where the name ends in `-ax5`. `sheets/` holds the contact sheets the PR shows, with the reference first where there is one. The run's rows are `-fakeRunBirds`, the mock's three birds, over the seeded album in Griffith Park: real rows, real patches, a list that holds still.

| Pick | The change | Shots |
|---|---|---|
| L1 | The summary leads with new patches waiting; three looks on a run's rows; quiet Stop | `sheets/run-against-reference`, `run-dark`, `run-light`, `run-ax5`, `run-row-ax5`, `sheets/contrast` |
| L2 | Sew it and Add on rows, with the review's reveal and Undo; a tap on the row opens the review; a bird no pack describes keeps Review | `sheets/rows-after-add`: `run-added-dark`, `run-toast-dark`, `run-no-pack-dark`, `run-after-stop-dark`, `review-dark`; `review-light`; `HuntUITests` for the taps |
| V2 | Your patch on rows: species, sightings without a photo, sets, the Atlas, a run | `sheets/grammar-dark`, `sheets/grammar-light`, `species-*`, `sightings-*`, `set-*`, `atlas-search-dark` |
| A2 | A found bird's profile leads with your patch and its story on card stock | `sheets/profile`: `profile-dark`, `profile-light`, `profile-gallery-dark` (two patches, one with no painting on this phone), `profile-none-dark` (no sighting, as before); `profile-ax5` |

## Where it differs from the reference

`sheets/run-against-reference` puts `2-listening-run.png` next to the run.

- The hoop and its stitched waveform are rejected (L3, L4): today's timer and waveform stay.
- The dashed ring is the transfer pen, and "new here" the tint. The mock uses the accent for both; the issue decides.
- The tint is today's aqua until slice 6 sets the edition's. The mock's is Citrus.
- Calling now stays as it was, per the issue: the raised row, the level glyph and an outline on a patch, which the mock doesn't draw.
- Stop is pinned in the `safeAreaBar`, per the issue, so "Possible matches" is above it rather than below.
- Stop stays at the 44 pt minimum, against the mock's 41 at scale. Add and Sew it are drawn at the mock's 36 and answer to 44.

## Decodes under a moving light

`decode-counts.txt`, from `capture.sh`: each surface with the light sweeping (`-patchLightSweep YES`), counting two 8 s windows of the app's log, then the patch decodes in the last minute. A thumbnail that had stayed a lazy provider would log AV1 lines at about the frame rate for every patch on screen, as #134 found. `count-*.jpg` shows what was on screen during each count.

```
A real run over the clip, its birds sewn (`count-run-clip`): first window: 89 lines, 2 patch decodes, 18 AV1 or ImageIO lines. 20 s later: 33 lines, 0 patch decodes, 0 AV1 or ImageIO lines. Patch decodes in the last minute: 4.
A run holding still, three rows (`count-run-still`): first window: 8 lines, 0 patch decodes, 0 AV1 or ImageIO lines. 20 s later: 28 lines, 0 patch decodes, 0 AV1 or ImageIO lines. Patch decodes in the last minute: 4.
Species rows (`count-species`): first window: 3 lines, 0 patch decodes, 0 AV1 or ImageIO lines. 20 s later: 23 lines, 0 patch decodes, 0 AV1 or ImageIO lines. Patch decodes in the last minute: 12.
Set rows (`count-set`): first window: 3 lines, 0 patch decodes, 0 AV1 or ImageIO lines. 20 s later: 23 lines, 0 patch decodes, 0 AV1 or ImageIO lines. Patch decodes in the last minute: 2.
```

Each patch is two decodes, its colour and its layers: 2 patches on the real run's rows, 2 on the still one, 6 on Species and 1 on Set, each decoded once. The real run's first window caught a bird arriving, 2 patch decodes and their 18 decoder lines, which also shows the count can see a decode. Everything after is 0, at the sweep's rate of about 60 frames a second, where a re-decoding thumbnail would log hundreds. The second window's extra 20 lines are the system's network log closing the pack index's connection, nothing to do with patches.

## The first count was wrong

An earlier version of this table said "A run over the clip, with 30 patches sewn". `-seedBoard` seeded the pack's bare label then, and the first 30 birds are not the clip's, so those rows had no patches on them and the zero proved nothing. The seeds now write the label an add writes, and the real run uses `-seedLarge`, so nearly every bird it hears has a patch.

## Not proven here

A simulator can't show these, so they're for a phone: 120 Hz with patches on rows while a run refreshes them, the tilt on those rows, and a tap on a real run's list as it re-sorts.
