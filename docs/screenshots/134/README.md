# Patches slice 3: the screenshot review (#134)

From an iPhone 17 Pro simulator (iOS 27.2) on a local build of Los Angeles v11, half size, seeded with #28's six sightings
(`-inMemoryAlbum YES -seedJournal YES`); the species view uses `-seedGallery YES`. Compare them with design guide 2.0's
boards (`docs/design/featherguild-2/pages/`): page 6 (the board, the patch, the paper card), page 7 (the species view),
pages 10 and 13 (the card's anatomy, the light) and page 16 (materials). The simulator has no motion, so
`patch-dark-tilted` sets the light by hand (`-patchLight "0.5,0.6"`).

| Shot | Against |
| --- | --- |
| `board-dark`, `board-light`, `board-ax` | Page 6, 07 The patch board; page 16, light appearance |
| `patch-dark`, `patch-dark-tilted`, `patch-light` | Page 6, 08 The patch; page 13 |
| `card-dark`, `card-light`, `card-ax` | Page 6, 09 The paper card; page 10 |
| `species-dark` | Page 7, 10 Two editions |

## Differences from the boards

- **Patterns** are drawn by the app from the patch's own colour edges, as #134 asks, so they carry the motif as well as the
  bird and are busier than the prototype's painted outlines.
- **The species view's other editions are blanks**, not patterns of the bird: San Diego, the Bay Area, the Deserts and
  Orlando have no patches until their references are isolated (#58). Only Los Angeles can draw the bird.
- **The paper card** holds more than the mock at default text size, because the excerpts run 25–50 words. The history's
  rows are a short scroll down inside the card; its count and footer stay in view.
- **On the light board** the card's edge is quiet against the linen. Page 16 fixes the paper and asks for oatmeal linen;
  #138 can decide whether it wants more shadow there.
- **Uncharted patches** are the plain canvas blank with a paper tag on their page, with no bird in thread: there is no
  Uncharted painting. #138 owns that state.

## Not checked here

The light on a real phone (tilt, and stopping with the phone) and the frame rate at 120 Hz. The simulator has no motion and
its display is capped at 60 Hz, where `-patchLightSweep YES` logs a flat 16.7 ms.
