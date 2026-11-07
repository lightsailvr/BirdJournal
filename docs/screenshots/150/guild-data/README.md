# UX cohesion slice 8, the app half: Guild data (issue #150)

Every picture is the running app on an iPhone 17 Pro simulator at half size, taken by `capture.sh` over the debug fakes (`-fakeCircles reference -seedReferenceBirds YES`). The text size is the default (`large`), or the largest where the name ends in `-ax5`. `sheets/` holds the side-by-sides, each with its reference first.

| Pick | What it is | Shots | Sheet |
|---|---|---|---|
| G5 | Compare as boards: theirs you don't have yet, what you both have, only yours | `compare-*`, `compare-both-dark` | `against-5-compare` |
| G5 | A species with no painting or no edition: the blank with its tag | `compare-blanks-dark` | `the-rest` |
| G6 | The goal: lavender thread beside this period's patches, with "+N" | `goal-*` | `against-1-guild-page` |
| G6 | What "+N" opens: every patch of the goal | `goal-board-dark` | `the-rest` |
| G7 | The goal on Listen, under the local set | `listen-*` | `against-3-listen` |
| A4 | Friends' faces on a set's rows, on birds you haven't found | `set-*` | `against-4-set-page` |
| A4 | The paper card names the friends who have the bird | `card-*` | `the-rest` |
| All | The largest text size | `*-ax5` | `ax5` |
| All | Increase Contrast, both appearances | `*-contrast-*` | `contrast` |

`decode-counts.txt` is each surface under a moving light: patches decode once, as they come on screen, and not again.

## Where it knowingly differs from the references

- `5-compare.png`: no "Let's go together" (out of scope in the issue). The tally is a line above the boards and Heard or Seen sits under every patch, because the issue keeps both. The fixture's birds are heard from the phone, so "Only you" says so. Boards sort by name, so the Egret comes before the Bluebird.
- `1-guild-page.png`: six patches and "+6" where the mock draws seven, since the issue asks for "+N" past what fits and the goal stands at 12. Today's `GuildEmblem`, not the crest.
- `3-listen-rejected-hoop.png`: only its lower half is the target. Listen keeps the painting, the wordmark and "Wonder is nearby.", and today's `GuildEmblem`.
- `4-set-page.png`: the faces are Jo's and Sam's on the first rows, not Maya's on a heron, because the fixture keeps Maya's birds to the three the Compare mock gives her.

## Not proven here

A simulator can't show these, so they're for a phone: the press and the grow from a tile, and the goal row's small targets one-handed.
