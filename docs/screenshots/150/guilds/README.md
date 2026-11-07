# UX cohesion slice 7: Guilds (issue #150)

Every picture is the running app on an iPhone 17 Pro simulator (iOS 27.2) at half size, taken by `capture.sh`, at the default text size (`large`), or the largest where the name ends in `-ax5`. `sheets/` holds the contact sheets the PR shows. `-fakeCircles reference` seeds Sunday Group as the reference picture draws it, `shared` puts a find in two Guilds and gives Lee a line of repeats, `one` is a single Guild.

| Pick | The change | Shots |
|---|---|---|
| G2, G1 | A scrolling page on felt: emblem, name, faces, Invite, compact goal, "All goals", the sharing line, the picker, then finds. No landscape | `sheets/against-reference`, `guild-reference-*`, `guild-ax5`, `sheets/contrast` |
| G2 | The Info button and the sharing line open a sheet, a native list | `sheets/info`, `info-*` |
| G4 | A led find's patch at 104 pt on felt; repeats gather into a line that opens in place; marked finds stand alone | `feed-dark`, `tab-two-*`, `tab-open-dark` |
| G3 | The tab opens on what's new across Guilds under a row of emblems, naming each row's Guilds; one Guild opens that Guild; none is today's states | `sheets/the-tab`, `tab-*`, `empty-dark` |
| F1 | A find's page: the patch in its edition, who, how, where, when, marks, reactions, the card behind it, Atlas and your patch, Report and Block | `sheets/a-find`: `find-*`; `find-nopack-dark` has no card, `find-otheredition-dark` is San Diego's blank though the phone has Los Angeles's painting, `find-secret-dark` stays a secret spot |
| G8 | Sign-in and join show the emblem and felt sample patches, labelled as samples; "Find wonder together." moves there | `sheets/invitations`: `signedout-*`, `join-*`, `empty-dark` |
| G9 | Three equal 44 pt pills with their full names; the given one takes the tint | `sheets/against-reference`, `guild-reference-*` |

## Where it differs from the reference

`sheets/against-reference` puts `1-guild-page.png` next to the page.

- **The emblem** is today's `GuildEmblem`, its disc at the patches' 102 pt. The mock's leaf crest is rejected.
- **Invite** is the mock's small outlined pill, about 28 pt tall against its 25.5, and answers to 44 pt.
- **The goal has thread alone.** The row of patches is slice 8's, and takes the room the mock gives it, under the thread.
- **"All goals" and the sharing line** aren't in the mock. The issue asks for both, so they share a line under the goal.
- **Reaction names are the issue's full ones:** "Lovely find", "Jealous!", "Let's go together", which wraps at default text, in three equal pills as drawn. They're 44 pt tall against the mock's 39.
- **A find has its menu** at the row's corner, as slice 1 and the issue have it.
- **Jo's hummingbird says "4 days ago".** The mock sets "3 days ago" above "yesterday", which a feed sorted by time can't do.

## Decodes under a moving light

`decode-counts.txt`, from `capture.sh`: each surface with the light sweeping (`-patchLightSweep YES`), counting two 8 s windows of the app's log, then the patch decodes in the last minute.

```
A Guild's page: first window: 0 patch decodes, 0 AV1 or ImageIO lines. 20 s later: 0 patch decodes, 0 AV1 or ImageIO lines. Patch decodes in the last minute: 6.
The Guilds tab: first window: 0 patch decodes, 0 AV1 or ImageIO lines. 20 s later: 0 patch decodes, 0 AV1 or ImageIO lines. Patch decodes in the last minute: 2.
A find's page: first window: 0 patch decodes, 0 AV1 or ImageIO lines. 20 s later: 0 patch decodes, 0 AV1 or ImageIO lines. Patch decodes in the last minute: 4.
Sign-in, with its samples: first window: 0 patch decodes, 0 AV1 or ImageIO lines. 20 s later: 0 patch decodes, 0 AV1 or ImageIO lines. Patch decodes in the last minute: 6.
```

Each patch decodes twice (colour and layers) as it comes on screen, and nothing after that. The last-minute counts run into the launch before them.

## By hand on a phone

The reaction's pop and haptic, the zoom from a row's patch and back, a find's turn over, the row's patches at 120 Hz and tilt.
