# UX cohesion slice 6: the place (issue #150)

Every picture is the running app on an iPhone 17 Pro simulator (iOS 27.2) at half size, taken by `capture.sh`, at the default text size (`large`), or the largest where the name ends in `-ax5`. `-contrast` is with Increase Contrast on. `sheets/` holds the contact sheets the PR shows.

| Pick | What | Shots |
|---|---|---|
| V5 | The painting follows the place: Griffith Park, Joshua Tree, San Diego, Oakland and Orlando, with none of those packs on the phone, and Kansas, outside every set, on your last set | `listen-<place>-dark`, `listen-<place>-light`, `sheets/places-*` |
| V5 | A fresh install with the index out of reach, in the desert: the desert's painting, tint and name, and the set's tile and page in the Atlas | `offline-desert-*`, `offline-atlas-dark`, `offline-set-dark`, `sheets/offline.jpg` |
| V5 | Location denied, no prompt, the fallback | `listen-denied-*`, `PlaceUITests.testNoPermissionPromptAtLaunch` |
| V5 | "Your local set" names the set the painting shows | the same shots |
| V4 | The accent follows the place, and a set's or patch's page has its own edition | `listen-*`, `set-*-dark`, `patch-dark` (a Citrus patch while in the desert) |
| V4 | Thread in place of every bar, each set in its own thread, lavender for goals, downloads too | `set-*-dark`, `atlas-dark`, `species-list-dark`, `goals-dark`, `download-dark`, `sheets/download-sewing.jpg` |
| Both | Increase Contrast and the largest text | `sheets/large-and-contrast.jpg` |

`sheets/reference-listen.jpg` and `sheets/reference-thread.jpg` put the mocks beside the screens.

## The hero against slice 2's build

The Listen hero is meant to change only where the painting does, so it was measured: full-size screenshots of a build at 123e5da, whose painting is the pack's AVIF, and this branch's bundled JPEG of the same cover, on one simulator at `large`, in Los Angeles, with a change counted above 12 levels of grey.

| Region (y in pt) | Dark, changed pixels | Light, changed pixels | |
|---|---|---|---|
| Status bar (0–62) | 0 of 224,316 | 0 | |
| Wordmark and tagline, left of the gear (62–160) | 107 of 291,060 | 109 | The painting behind the words: nothing moved |
| The gear's corner (62–160) | 28 of 63,504 | 1,569 | The gear is the accent, so it's Citrus now |
| The painting (160–322) | 2,551 of 586,116 | 2,574 | 0.4%, one encoder against another |
| The source row (322–401) | 448 of 285,822 | 448 | The ready dot is the accent |
| From 401 down | changed | changed | Start's colour, and the new section |

## Size

The covers and sets add 2.5 MB to the app (`BirdJournalKit_Pack.bundle/Covers`: five JPEGs at 1536 × 864, quality 90, and five `set.json` files, 89 KB).

## By hand on a phone

- The cross-fade when a place changes, and the switch without one under Reduce Motion.
- The thread sewing forward, when the Listen tab comes back after a run. `ThreadProgressTests.sewsOnReturn` holds its start and end on pixels; the middle needs eyes.
- A real last known position moving the painting: the simulator's fixes are `-autoLocation`'s.
- What the read shows: no blue pill, and on the simulator iOS's location arrow in the status bar, gone by 30 s. See what a phone does, and whether the arrow bothers anyone at every launch.
