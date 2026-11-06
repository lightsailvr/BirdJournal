# UX cohesion slice 5: patch means yours, and the hunt (issue #150)

Every picture is the running app on an iPhone 17 Pro simulator (iOS 27.2) at half size, taken by `capture.sh`, at the default text size (`large`), or the largest where the name ends in `-ax5`. `sheets/` holds the contact sheets the PR shows, with the reference first where there is one. The run's rows are `-fakeRunBirds`, the mock's three birds, over the seeded album in Griffith Park: real rows, real patches, a list that holds still.

| Pick | The change | Shots |
|---|---|---|
| L1 | The summary leads with new patches waiting; three looks on a run's rows; quiet Stop | `sheets/run-against-reference`, `run-dark`, `run-light`, `run-ax5` |
| L2 | Sew it and Add on rows, with the review's reveal and Undo; a tap on the row opens the review | `run-dark`, `run-added-dark`, `run-after-stop-dark`, `review-dark`, `review-light`, and `HuntUITests` for the taps |
| V2 | Your patch on rows: species, sightings without a photo, sets, the Atlas, a run | `sheets/grammar-dark`, `sheets/grammar-light`, `species-*`, `sightings-*`, `set-*` |
| A2 | A found bird's profile leads with your patch and its story on card stock | `sheets/profile`, `profile-dark`, `profile-light`, `profile-gallery-dark`, `profile-ax5` |

## Where it differs from the reference

`sheets/run-against-reference` puts `2-listening-run.png` next to the run.

- The hoop and its stitched waveform are rejected (L3, L4): today's timer and waveform stay.
- The dashed ring is the transfer pen, and "new here" the tint. The mock uses the accent for both; the issue decides.
- The tint is today's aqua until slice 6 sets the edition's. The mock's is Citrus.
- Calling now stays as it was, per the issue: the raised row and the level glyph, which the mock doesn't draw.
- Stop is pinned in the `safeAreaBar`, per the issue, so "Possible matches" is above it rather than below.
- Stop stays at the 44 pt minimum, against the mock's 41 at scale. Add and Sew it are drawn at the mock's 36 and answer to 44.

## Decodes under a moving light

`decode-counts.txt`, from `capture.sh`: each surface after 12 s, with the light sweeping (`-patchLightSweep YES`), counting the last 8 s of the app's log. A thumbnail that had stayed a lazy provider would log AV1 lines at about the frame rate per patch, as #134 found.

DECODE_COUNTS

## Not proven here

A simulator can't show these, so they're for a phone: 120 Hz with patches on rows while a run refreshes them, the tilt on those rows, and a tap on a real run's list as it re-sorts.
