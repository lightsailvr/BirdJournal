# Patches: every board and state, against design guide 2.0 (issue #138)

Every picture is the running app on an iOS 27.2 simulator, taken by `capture.sh`, at half size. The guide is `docs/design/featherguild-2/` (PR #139). Written rules beat boards, and `DECISIONS.md` beats the guide. `sheets/` holds the contact sheets the PR shows.

Names end in `-dark` or `-light`. The boards are at the default text size.

`board-12-share-*`, `board-13-guild-*` and `state-no-location-rarity-*` were taken again on top of #136 and #137, whose changes they show. The rest are from before those two merged. Looking over the sheets, none of them shows anything those two changed.

## The journey (guide pages 4–8)

| Board | Guide | App | Remaining difference |
|---|---|---|---|
| 01 Ready | page 4 | `board-01-ready-*` | The guide shows the local set as blank patches. The app shows your own patches, or a sentence: **no patch until you've found the bird**. It also shows the source row and "Your local set" where the board has a smaller card. |
| 02 A call | page 4 | `board-02-call-*` | A new bird's row shows its reference photo and "new here", not its pattern, by the same decision. |
| 03 Review and add | page 4 | `board-03-review-*` | Matches. The action reads "Add and sew patch" or "Add sighting". |
| 04 Stitching | page 5 | `board-04-stitching-*` | Matches. The caption also names the thread (as page 14 asks); the board's says only "Thread 5 of 10". |
| 05 Your patch | page 5 | `board-05-your-patch-*` | "See it in my collection" and "Your sighting is already saved." are additions #135 kept. With no run going, the first button reads Done rather than Keep listening. |
| 06 Seen again | page 5 | not captured | The maintainer decided on 2026-11-04 that a repeat add has no page: the number ticks up and the sighting is recorded. #135 removed that page; `docs/screenshots/135/seen-again-toast.jpg` shows the toast that took its place. |
| 07 The patch board | page 6 | `board-07-patches-*` | No patterns after your patches (the decision above). Otherwise matches: three columns, collector order, number and count. |
| 08 The patch | page 6 | `board-08-patch-*` | Matches. |
| 09 The paper card | page 6 | `board-09-paper-card-*` | Matches. |
| 10 Two editions | page 7 | `board-10-two-editions-*` | No "Still to find" row (the decision above). San Diego's patch is the tagged blank here, since only Los Angeles has paintings; the guide's shield is Orlando's. |
| 11 Atlas | page 7 | `board-11-atlas-*` | Each set shows its cover, not the patch family the board shows beside its progress. A difference to decide, not in this slice's issue. |
| 12 Share | page 8 | `board-12-share-*` | The patch on linen with its paper card (#136). The sheet keeps its title "A story to share", the Your note and City switches and Share card image, where the board has Cancel, Share, Next and rows for the note, place and credits. |
| 13 Guild | page 8 | `board-13-guild-*` | A new patch is led by the member's patch and a repeat is a quiet line (#136). A repeat has no "8 times now", since the count isn't on the wire, and keeps its labels and reactions. The shot is scrolled to the finds, so the Guild's heading and goal are above it. |

## The states (guide page 15)

| State | App | Remaining difference |
|---|---|---|
| Not yet found | `state-not-found-row-*`, `state-not-found-page-*` | The silhouette, name, number and profile, with **no pattern**, though page 15 asks for one: the maintainer confirmed the silhouette on 2026-11-04. |
| Being sewn | `state-being-sewn-board-*`, `state-being-sewn-page-*` | Matches. |
| Art failed or missing | `state-art-missing-board-*`, `-page-*`, `-reveal-*` | Matches. |
| Uncharted | `state-uncharted-board-*`, `-page-*`, `-card-*` | No bird on the patch: packs paint per edition, so there's no painting of it. Its name is on the tag instead. |
| Empty collection | `state-empty-*` | **No patterns**, by the same decision. The felt, the words, Start listening and the path to the Atlas. |
| Offline | `state-offline-atlas-*`, `state-offline-guilds-*` | As 1.0. |
| No location | `state-no-location-listen-*`, `state-no-location-rarity-*` | As 1.0. |
| Denied permissions | `state-denied-microphone-*`, `state-denied-notifications-*` | As 1.0. Denied location is `state-no-location-listen-*`. |
| Glasses disconnected | `state-glasses-not-connected-*`, `-none-linked-*`, `-unregistered-*` | As 1.0. These use `-fakeGlasses`, since a simulator has no glasses. |

## Accessibility (guide page 14)

- `type-*-xxl`, `type-*-ax3`, `type-*-ax5`: the board (two columns, then one), the patch, the paper card (a reading view at accessibility sizes), a blank's tag, Being sewn, the empty state and not yet found, in light.
- `contrast-*-dark`, `contrast-*-light`: Increase Contrast, with the board's labels on a solid surface and the felt darkened.

To capture them again, on a debug build: `docs/screenshots/138/capture.sh <simulator UDID>`.
