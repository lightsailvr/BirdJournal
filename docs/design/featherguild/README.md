# Featherguild design guide 1.0

The approved direction for the phone UI (November 1, 2026), implemented by #110 and its sub-issues. It supersedes the field-journal palette of [bird-collection/](../bird-collection/) (style guide 0.2). That guide's collection rules still hold where this one doesn't replace them.

**The name.** The guide was drawn up under the working name "Bird Quest", which was dropped on 2026-11-02 because two App Store bird apps and a UK trademark application already use it. Read every "Bird Quest" in these files as **Featherguild**.

**Files:**
- [pages/](pages/): every page of the PDF as a JPEG, 1600 px wide.
- [guide.md](guide.md): the text of every page, for searching.
- [prompts.md](prompts.md): the image-generation prompts behind the boards, embedded in the PDF. The smaller-italic revisions are the latest.

The 17 MB PDF stays out of the repository. The maintainer's copy is `~/Desktop/bird-quest-design-guide-v1.pdf`.

## Pages

| Page | Content |
|---|---|
| 1–2 | Cover; what to carry forward |
| 3 | Board: Listen, Collection and a Guild page (dark) |
| 4 | Board: active listening, Atlas and Guilds (light) |
| 5 | **Board: story-first card fronts (the reference card)** |
| 6 | Board: from the collection grid to the opened card |
| 7 | Card anatomy |
| 8 | Typography |
| 9 | Color tokens, dark and light |
| 10 | Information architecture: Listen, Collection, Atlas, Guilds |
| 11 | Listen |
| 12 | Collection rules |
| 13 | Guilds |
| 14 | Atlas and the field guide |
| 15 | Board: the flip and the first-discovery reveal (its front is superseded by pages 5–6) |
| 16 | Motion, accessibility and states |
| 17 | Lore, art and provenance |
| 18 | Implementation handoff and the checks before merging |
| 19 | Design prompts and the avoid list |
| 20 | Sources and credits |

## Reading the boards

- **Written rules win over raster details.** The boards are generated concepts, not dimensioned templates or production sizes. Small metadata in them is not a type specification.
- **Pages 5–6 are the reference card.** The earlier boards' simpler card fronts are superseded.
- **Sample data is illustrative.** Members, progress, dates and rarity are made up. The story titles ("The Waterside Mason", "The Orchard Singer", "The White Architect") are proposals; they don't exist in the packs yet.
- **Credits.** The bird paintings are adapted from the Los Angeles v8 pack art, and the photographic reference credits are on page 20. The lore excerpts are the pack's reviewed lore (CC BY-SA 4.0, adapted from Wikipedia).
