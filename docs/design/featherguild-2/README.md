# Featherguild design guide 2.0: patches

The approved direction for the collection (November 3, 2026), built by #131 and its slices #132–#138. It supersedes [guide 1.0](../featherguild/) where they differ: the card becomes an embroidered **patch**, one per species per edition, lit by the app and turned over to a paper card. Guide 1.0's app shell, tokens, flows and Guild rules stay the reference for everything this guide doesn't redraw.

**Files:**
- [pages/](pages/): every page as a JPEG, 1600 px wide.
- [guide.md](guide.md): the text of every page, for searching.

The PDF, the clickable prototype (13 journey steps, the lighting, the stitch-in and the flip) and the sample patches stay on the maintainer's machine, in `~/Desktop/featherguild-design-guide-v2-patches.pdf` and `build/badge-guide/`. Their art was painted on comfybox with FLUX.3 Image Klein from the Los Angeles pack's isolated reference birds.

## Amendment: the widened material rule (November 5, 2026, #150)

Guide 2.0 limited material to the objects you collect, and kept guide 1.0 as the reference for everything it didn't redraw. So a few screens spoke 2.0 and the rest still spoke 1.0. The maintainer has widened the rule. It decides how anything looks, and where it differs from a page of this guide or of 1.0, it wins:

> If you earned it or belong to it, it's an object you could hold. If you read it, it's printed on paper. If you operate it, it's plain iOS.

- **Objects**: patches, felt and linen, and a Guild's page. A feed of finds is a run of objects, so it may sit on felt.
- **Printed matter**: the paper card, the Atlas's plates and the share image. Tracked capitals stay on the paper card's edition line and the wordmark, and nowhere else.
- **Plain iOS**: controls, navigation, and the lists that operate something, such as Settings and a Guild's Info sheet.

One picture grammar: a patch is on the patches, a photo is how a bird looks, and a silhouette means it's still out there. The Collection's Patches and a patch's page have patches. A Sightings row has your own photo, else the Atlas's reference photo, captioned so it never reads as yours. A Species row always has the reference photo. The Atlas is a guidebook, with no patches anywhere in it (the maintainer, 2026-11-06, in `DECISIONS.md`). A run's rows, Listen's latest patches, a sighting's page, map pins, Guilds, Compare and goals still have patches, pending the maintainer.

These bans stay, with this rule in force:

- No fake stitching on buttons. A progress bar isn't a button, so thread may show progress.
- No stitched or embossed type.
- No felt behind lists of controls.
- No wood grain or brushed metal on chrome.
- No idle glints: the light moves only when you move.
- No heraldry, confetti, XP or scarcity.

The light page moved from ivory `#F4F2E9` to a pale sage-grey `#EEF1EC` in the same issue, and page 16's value is superseded. Card stock keeps its colour, with its fibre eased on linen so that the paper measures lighter than the cloth. The words are in `CONTEXT.md`, "Words a birder reads".

## Pages

| Page | Content |
|---|---|
| 1–2 | Cover; what changes and what stays |
| 3 | The journey at a glance (13 steps) |
| 4 | Board: ready, a call, review and add (and the lens) |
| 5 | Board: stitching, the new patch, seen again (and the lens) |
| 6 | Board: the patch board, the patch, the paper card |
| 7 | Board: two editions of one bird; the Atlas |
| 8 | Board: share; a Guild find |
| 9 | Patch anatomy |
| 10 | The paper card |
| 11 | Editions: shape, cord, twill and motif per set |
| 12 | **The collecting rule: one patch per bird, per place** |
| 13 | Light and material: the app does the lighting |
| 14 | Motion and accessibility |
| 15 | States |
| 16 | Typography and colour, the material tokens |
| 17 | Patch art: the pipeline and what the samples showed |
| 18 | Implementation handoff and the checks before merging |
| 19 | Design prompts and the avoid list |
| 20 | Open questions, sources and credits |

## Reading the boards

- **Written rules win over raster details.** The screens are a clickable HTML prototype captured in Chrome; its SVG lighting stands in for the production Metal shader, and nothing in it is a dimensioned template.
- **Sample data is illustrative**: sightings, counts, members and progress are made up. Names, story titles, lore, biology and collector numbers are the Los Angeles pack's.
- **The sample patches are samples.** The black phoebe and the cedar waxwing failed (dark and dim references grew pale patterns in thread) and are left out; page 17 shows them.
