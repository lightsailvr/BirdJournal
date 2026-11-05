# Patches slice 3: the screenshot review (#134)

From an iPhone 17 Pro simulator (iOS 27.2) on Los Angeles v11, half size, seeded with #28's six sightings
(`-inMemoryAlbum YES -seedJournal YES`); the species view uses `-seedGallery YES`. Compare them with design guide 2.0's
boards (`docs/design/featherguild-2/pages/`): page 6 (the board, the patch, the paper card), page 7 (the species view),
pages 10 and 13 (the card's anatomy, the light) and page 16 (materials). The simulator has no motion, so
`patch-dark-tilted` sets the light by hand to where a real 10° tilt puts it (`-patchLight "l0.15,u0.62"`). These were retaken after the maintainer's first look on a phone (see the DECISIONS entry): the material covers the whole sheet, and there are no patterns.

| Shot | Against |
| --- | --- |
| `board-dark`, `board-light` | Page 6, 07 The patch board; page 16, light appearance |
| `patch-dark`, `patch-dark-tilted`, `patch-light` | Page 6, 08 The patch; page 13 |
| `card-dark`, `card-light`, `card-ax` | Page 6, 09 The paper card; page 10 |
| `species-dark` | Page 7, 10 Two editions |
| `patch-sideways` | Not on the boards: the maintainer's request, patch left and card right |
| `atlas-dark` | Page 7, 11 Atlas, with its search in view |

## Differences from the boards

- **No patterns or "still to find"**: the maintainer's call. Boards show only sewn patches.
- **A patch sewn where its pack has no painting** shows the blank in that edition's shape (`species-dark`'s San Diego): you did find that bird, and only Los Angeles has paintings so far (#58).
- **The paper card** holds more than the mock at default text size, because the excerpts run 25–50 words. The history's
  rows are a short scroll down inside the card; its count and footer stay in view.
- **On the light board** the card's edge is quiet against the linen. Page 16 fixes the paper and asks for oatmeal linen;
  #138 can decide whether it wants more shadow there.
- **Uncharted patches** are the plain canvas blank with a paper tag on their page, with no bird in thread: there is no
  Uncharted painting. #138 owns that state.

## Not checked here

How the light feels on a real phone, and the frame rate at 120 Hz. The simulator has no motion and
its display is capped at 60 Hz, where `-patchLightSweep YES` logs a flat 16.7 ms.
