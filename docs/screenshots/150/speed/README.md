# UX cohesion slice 4: speed (issue #150)

R4, R5, R7, R8. Nothing should look different except the redacted placeholder, so most of this is numbers.

## How the numbers were taken

`measure.sh` launches the app on an iPhone 17 Pro simulator (iOS 27.2, Debug) over an album on disk, with `-seedLarge <n>`, and lets `-speedTour YES` walk the screens, printing a line per step. The raw lines are `before-<n>.txt` and `after-<n>.txt`, the second launch over each album (the `-first` files are the launch that seeded it). `before` is slice 1 plus only the seed and the tour (859e611), so the tour is the same in both.

- **Builds** is how many times `CardCollection` was built in the step, and **build ms** the main-thread time for that (after: reading the album and comparing, too).
- **CPU ms** is the whole process, user and system.
- **Worst frame** is the longest gap between display frames. A step whose stall outlasted its window reports a low number here, since the frame after the stall is counted in the next step, so trust CPU ms there. Those cells say "past the window".

The Mac was under heavy, varying load from other agents (load average 38 to 500), which moves frames more than CPU time. All of it's a Debug build on a simulator, whose Swift packages aren't optimized. **Compare these with each other, not with a phone or a release. They don't settle anything about a phone**: see "On a phone".

## The numbers

### Thirty seconds on the listening screen (R4)

The screen refreshes every second and on the waveform, and built the collection in its body. The clip plays through the same engine in both.

| Sightings | Builds | Build ms | CPU ms | Time over budget |
|---|---|---|---|---|
| 1,000 | 301 → **0** | 5,205 → **0** | 12,559 → **9,499** | 1,213 → **0** ms |
| 5,000 | 232 → **0** | 20,965 → **0** | 28,989 → **7,760** | 21,463 → **29** ms |
| 20,000 | 57 → **0** | 21,569 → **0** | 29,297 → **9,790** | 23,670 → **36** ms |

Before, at 5,000 sightings, the main thread spent 21 s of 30 s building the collection. The count falls at 20,000 only because each build takes so long that few fit.

### Opening a screen, at 5,000 and 20,000 sightings

| Step | Builds (5k) | CPU ms (5k) | Worst frame (5k) | CPU ms (20k) | Worst frame (20k) |
|---|---|---|---|---|---|
| Collection tab | 2 → 0 | 1,305 → 1,172 | 738 → 569 ms | 3,416 → 2,312 | past the window → 1,708 ms |
| A patch's page | 2 → 0 | 8,245 → 1,111 | past the window → 683 ms | 39,510 → 1,855 | past the window → 1,388 ms |
| Adding a sighting, on the Collection tab | 8 → 1 | 1,950 → 1,047 | 1,435 → 480 ms | 29,176 → 3,543 | past the window → 1,550 ms |
| Atlas tab | 3 → 0 | 1,411 → 485 | 831 → 287 ms | 6,758 → 979 | past the window → 777 ms |
| A set's page (R5) | 1 → 0 | 1,044 → 179 | 472 → 69 ms | 2,441 → 246 | 15,431 → 87 ms |

At 20,000 before, the 29 s beside "Adding a sighting" is mostly the patch page still paying off from the step ahead of it. A set's 15 s frame is the same kind of leftover.

A set's page made all 160 rows at open and now makes what's on screen: `testASetsPageMakesItsRowsAsTheyScrollIn` counts under 40.

### The engine (R7)

| | Before | After |
|---|---|---|
| First Start to listening, 5,000 sightings | 230 ms | **63 ms** |
| When the models load | on Start | on Listen, before Start |

The load itself takes about 220 ms on this simulator, against a fixed location fix and a Mac's disk. The audit's "Starting: finding your location and loading the models" may be mostly the location on a phone, and only a phone can say.

### Guilds (R8)

The fake server was slowed to 1 s a read (`-fakeCircleLatency 1`; in the before run its feed and goals waited twice, since corrected, which is part of that 3 s). Time from opening a screen to its content:

| | Before | After, second launch |
|---|---|---|
| The Guilds list | 1,049 ms, spinner | **0 ms** |
| A Guild's page | 3,056 ms, spinner | **under 1 ms** |
| Known at launch | 0 Guilds, 0 feeds | 2 Guilds, 1 feed |

## What the launch pays

The collection is built once at launch, in the app's init instead of Listen's first body, and both come before the first frame. The `launch-build-ms` figures are 40, 167 and 619 ms at 1,000, 5,000 and 20,000 sightings, against 27, 114 and 595 before, **but they don't measure the same work**: before, the album had already been fetched by Listen's `@Query`, outside the timer, and now the store's fetch is inside it.

The first version of this slice did fetch the album twice at launch, once for the store and once for Listen's `@Query`. Listen now reads the kept collection, so a launch fetches it once, as it did before. A launch before and after therefore does the same fetch and the same build, and this slice has no like-for-like launch number. That's the phone's check, below.

## Still slow, not in this slice

- **The Collection tab** at 20,000 sightings still holds a frame for about 1.7 s, with no builds left in it. `JournalView`'s `@Query` of the album, its search filter and `Journal.days` run over every sighting. The same goes for an add, which redraws it.
- **A save** reads the whole album to compare (the 31, 149 and 604 ms under "Adding a sighting"). A note or a caption pays that too, though no screen draws again. Fetching only the four columns it reads didn't help (627 to 608 ms at 20,000, within the noise), so the code does not.

## Screenshots

From the running app, half size, by `capture.sh`, dark and light and at the largest text.

| Pick | The state | Shots |
|---|---|---|
| R8 | Nothing known yet: the Guilds list, and Compare | `placeholder-list-*`, `placeholder-compare-*` |
| R8 | The next launch with no connection: drawn from the cache | `cached-list-*`, `cached-page-*` |

`sheets/placeholder.jpg` has them side by side. The page and goal placeholders exist too, but the Guilds list reads details and goals first, so they show only when a Guild opens straight from a push or an invite.

## On a phone

For the maintainer: a simulator can't settle these. In Xcode, edit the scheme's arguments to `-albumFile speed-5000 -seedLarge 5000 -speedTour YES -collectionIntroShown YES`, run on the iPhone 17 Pro in Debug, and read the `SPEED` lines in the console. Add `-autoPhoneListening <path to a wav on the phone> -autoLocation griffith` for the listening steps, or see the two below.

1. **Time to listening**, cold launch, tapping Start as soon as you can and again after a few seconds, with the real microphone and a real location fix. This says whether the warm-up is worth its memory, and how much of "Starting" is the location. A first fix may well dominate, and this slice doesn't touch it.
2. **What the warm-up costs**: in Instruments (Allocations, Time Profiler), launch to Listen and don't tap Start. See the resident memory with the 70 MB model loaded, whether scrolling Listen hitches during the load at utility priority, and that Xcode's "Simulate Memory Warning" lets the memory go.
3. **The launch's collection build** at 5,000 sightings: time to first frame against `dev`, since it moved into the app's init. Debug overstates it; use Instruments' Time Profiler on a Release build if it looks long.
4. **Thirty seconds of a real run** at 5,000 sightings: the frame rate of the waveform and the phone's warmth against `dev`.
5. **A real Guild** on a slow connection: the cached page on a second launch, then the refresh landing in place without the list jumping, and the file gone after signing out (Settings → Account).
