# UX cohesion slice 2: foundations (issue #150)

Every picture is the running app on an iPhone 17 Pro simulator (iOS 27.2) at half size, taken by `capture.sh`, at the default text size (`large`), or the largest where the name ends in `-ax5`. `sheets/` holds the contact sheets the PR shows, each with its reference first.

| Pick | The fix | Shots |
|---|---|---|
| V1 | The widened material rule, in the design guide | `docs/design/featherguild-2/README.md` |
| V3 | One word per thing, in `CONTEXT.md` and every string | `packs-dark`, `packs-xxxl`, `packs-ax5`, `pack-dark`, `atlas-dark`, `settings-light` |
| V6 | The copy table: "3 of 160 sewn", "157 still out there", "About this bird", the story title alone | `set-dark`, `atlas-dark`, `profile-dark` |
| V8 | Capitals and dots go from the patch page, the reveal and the goal card | `patch-dark`, `reveal-dark`, `goal-dark`, `sightings-dark`, `share-dark` |
| V9 | The light page is a pale sage-grey | `listen-light`, `atlas-light`, `set-light`, `settings-light`, `guild-light` |
| F11 | The paper card is lighter than the linen, with an edge | `card-light`, `board-light`, `patch-light`, with `card-dark` unchanged |
| F17 | Collection's tab icon is the stitched ring | any shot with the tab bar; `tab-bar-dark`, `tab-bar-light` at full size |
| F21 | One heading (`SectionTitle`), one avatar (`MemberFace`), one state (`StateNotice`) | `set-dark`, `sightings-dark`, `members-dark`, `guild-dark`, `empty-guilds-dark` |

`ThreadProgress` is slice 6, so the bars here are still the old ones.

## Measured

`ContrastTests` re-measures every pairing in all four appearance variants:

| | Before | Now |
|---|---|---|
| Light page | `#F4F2E9` | `#EEF1EC` (`#F3F5F1` under Increase Contrast) |
| Raised surface | `#DFEAE5` | `#E0E8E2` (`#D5E0D9`) |
| Card stock on linen, light | `#E1D9C3` on `#E8DBCD` | `#EEE7D7` on `#EADECF`, with its edge at `#91A198` |
| Card stock on linen, light with Increase Contrast | darker than the linen (`#F4EEE7` at a 72% veil) | `#EEE7D7` on `#EEE4D8` at a 55% veil, with its edge at `#8B9A91` |

The stock's values are the mean of its middle on the render, and the linen's the mean of a corner, both in `cardOnLinen`.

## A trap in the capture

An aborted capture once left the simulator at ax5, and `testSignedOutTheTabInvitesTheBirderToSignIn` then failed on a screen this slice didn't break: it passed alone once the text size was back at `large`. The script now restores the text size and appearance on any exit.

## Not proven here

A simulator can't show these, so they're for a phone: the page colour and the paper card's edge in real light.
