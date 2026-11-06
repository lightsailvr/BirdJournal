# UX cohesion slice 3: feel (issue #150)

Every picture is the running app on an iPhone 17 Pro simulator at half size, taken by `capture.sh`, at the default text size (`large`), or the largest where the name ends in `-ax5`. `sheets/` holds the contact sheets the PR shows, with the reference first where there is one. Most of this slice is motion, so the audit's motion table is the target, and the tests and a phone say more than these do.

| Pick | The fix | Shots | Proved by |
|---|---|---|---|
| R1 | A patch grows out of its tile and shrinks back to the one opened, with a long-press peek | `lift-1` to `lift-6`, `peek-dark` | `FeelUITests`: the tile opens on each surface, goes back where it left after a swipe, Reduce Motion, and each peek action |
| R2 | A spring press on the shared styles, or a dim under Reduce Motion | none: it lasts as long as a finger | `FeelTests.press`, and on a phone |
| R3 | One list of haptics | none | `FeelTests.haptics` for the table; `FeelUITests` for which moments ask (`-hapticLog`), and on a phone |
| R6 | The blank fades into the patch; the board decodes ahead | none: 0.18 s | `FeelTests` for decoding ahead, its stop and a visible patch first; the sweep below |
| F9 | The set's name is the menu, pinned with the modes, its thread and count under it, the total in the menu | `board-dark`, `menu-dark`, `board-scrolled-dark`, `board-light`, `board-ax5`, `board-contrast` | `FeelUITests`, `testTheSetMenuIsInReachFromAScrolledBoard`, `ScreenAccessibilityTests` |
| F10 | The surface cross-fades, and each mode keeps its place | `mode-fade-dark`, part way through a surface's fade slowed to 6 s, with `board-dark`, `sightings-dark` either side | `testChangingModeCrossFadesTheSurfaceToTheRightMode` measures the surface between the two; `testEachModeKeepsItsScrollPositionThroughChanges`, `testTheOldModeHasGoneBeforeTheScrollMoves`, `testTheFootOfABoardComesBackWhereItWas` |
| F15 | The splash on first launch only | `splash-dark` | `testTheSplashPlaysOnTheFirstLaunchOnly` |
| F20 | The reveal: one primary, Share, Undo in its window, the patch as the way to the collection, "Shared with" | `reveal-dark`, `reveal-shared-dark`, `reveal-undo-dark`, `sewing-dark`, `reveal-light`, `reveal-ax5` | `FeelUITests`, `SewingCeremonyAccessibilityTests`, `FeelTests.sharedLine` |

`2-listening-run.png` is the reference for the quiet outlined button: `reference-outlined` sets it beside `listening-dark` and `reveal-undo-dark`. Stop is the mock's compact centred pill, across the page only at accessibility sizes (`testStopIsACompactCentredPill`). The stroke is the moss token until slice 6's tint, and the run's rows are slice 5's.

## Measured

Sweeping the light over a board of 30 (`-seedBoard YES -patchLightSweep YES`) logged 3 lines in 8 s: its own frame times (median 16.7 ms, the simulator's 60 Hz cap) and no decodes. So the fade and decoding ahead left thumbnails as plain bitmaps under the moving shader.

`lift-1` to `lift-6` are frames of one recording, at 20 frames a second: the Black Phoebe's page growing out of its tile, a swipe to the House Finch, and back onto the Black Phoebe's tile, where it was opened.

## Not proven here

A simulator has no Taptic Engine and runs at 60 Hz, so these are for a phone: the feel of the zoom and of dragging a page back, the spring, whether the haptics feel right, and haptics during a phone-mic run (see `DECISIONS.md`).
