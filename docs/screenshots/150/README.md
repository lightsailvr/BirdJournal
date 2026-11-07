# UX cohesion slice 1: the fixes (issue #150)

Every picture is the running app on an iPhone 17 Pro simulator (iOS 27.2) at half size, taken by `capture.sh`. `before-*` is a build of `dev` at 4803280 and the rest are this branch. The text size is the default (`large`), or the largest where the name ends in `-ax5`. `sheets/` holds the contact sheets the PR shows.

| Pick | The fix | Shots |
|---|---|---|
| F2 | Reactions keep their pill and get a 44 pt hit area | `guild-feed-*` |
| F3 | Every list's rows on the raised surface | `settings-*`, `source-dark` |
| F4 | Heard or Seen is on the review sheet, and the wrong instruction is gone | `review-*` |
| F5 | The old words go: "Card", "Open in Field Guide", "A story to share" | `share-dark`, `species-dark` |
| F6 (app part) | The invite sheet stops printing the link, and gains Copy link | `invite-dark` |
| F7 | Stop, Add and Share on `safeAreaBar`, and Stop is outlined | `listening-dark`, `review-*`, `share-dark` |
| F8 | Listen's gear is a real toolbar item on Liquid Glass | `listen-*`, `listen-ax5` |
| F13 | A find's menu is in plain sight | `guild-feed-*` |
| F14 | One line and a "How this works" disclosure | `source-dark`, `settings-*`, `guild-sharing-dark` |
| F16 | Outlined labels become rounded rectangles once their words wrap | `guild-ax5`, `guild-feed-ax5` |
| F19 | "1 sighting", no count until the second, "Los Angeles, 2 of 5" | `board-dark`, `species-dark`, `patch-dark` |
| F22 | The source is named once, in its row | `listen-*` |

## Listen against the original

The maintainer wants this page unchanged apart from the gear, so it was measured rather than judged by eye: full-size screenshots of `dev` and this branch, on simulators at the same text size, with a change counted above 12 levels of grey.

| Region (y in pt) | Dark, changed pixels | Light, changed pixels | |
|---|---|---|---|
| Status bar (0–62) | 0 | 32 | The 32 are the top edge of the gear's glass |
| Wordmark and tagline, left of the gear (62–160) | 0 | 0 | No shift |
| The gear's corner (62–160) | 13,924 | 15,449 | The gear |
| The painting (160–322) | 0 | 0 | |
| The source row (322–401) | 0 | 0 | No shift |
| From 401 down | changed | changed | F22 |

So two things differ. One is the gear. The other is F22, which the issue asks for in the same slice: "Using the iPhone microphone" and the tip under Start are gone, so Start and what follows sit 26 pt higher. If "unchanged" should cover those two lines as well, they're the one thing to put back.

Measuring found two faults that are now fixed. A `.scrollEdgeEffectHidden` on the page had removed the system's soft edge behind the clock, which left the status bar on bright sky. And the page's `.navigationBarTitleDisplayMode(.inline)` passed down to what's pushed from it, so Settings and a set's page lost their large titles; those two now ask for theirs, and `testPagesPushedFromListenKeepTheirLargeTitles` holds it.

Compare only at the same text size. `docs/screenshots/138/capture.sh` leaves a simulator at `medium`, not the default, and at different sizes every word on the page looks moved.

## The find menu

Measured from a full-size screenshot of a Guild's feed: the `…` on all four rows on screen spans x 346.3–361.0 pt, and their 44 pt hit boxes all start at x 332, on rows with and without a patch.

## Blocking moves the page, on `dev` too

Blocking a member from the Members section reloads the feed, and the list jumps back up it. On `dev` the Members heading goes from y 272 to y 758, which leaves the member's row, and the "Blocked" mark, off the screen at the default text size. On this branch, with its taller rows, the row also falls out of the accessibility tree, which is why `testBlockingAMemberHidesTheirFindsAndUnblockingBringsThemBack` stopped finding the mark: it had been passing on an element no one could see. Blocking itself works on both. The test now scrolls to the mark and needs it hittable. The jump isn't fixed here.

## Not proven here

A simulator can't show these, so they're for a phone: the gear's glass over the painting in real light, and a thumb on the reactions and the menu, three to a row, one-handed.
