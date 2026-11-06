# Slice 11: the mascot

Audit pick V7. The six birds in glasses as the app icon choices, and the perched finch on the launch screen, the first-launch splash, the sign-in page and the empty pages. There's no mock: the look is the patches on felt in `output/ux-audit/reference/1-guild-page.png`, a real object with a soft drop shadow.

| What | Shots |
|---|---|
| Launch screen and splash, before and after, dark and light | `sheets/before-after-launch.jpg` |
| Empty collection and Settings → Account signed out, before and after, dark and light | `sheets/before-after-states.jpg` |
| The same at ax5 | `sheets/before-after-ax5.jpg` |
| Each icon on a simulator home screen, beside today's hawk, at true pixels | `home-icons.jpg` (whole screens: `sheets/home-screen.jpg`) |
| The icon in the system's appearances (Icon Composer's renderings) | `icon-appearances.jpg` |
| Settings → App icon | `icons-dark.jpg` |
| The finch's glasses at true pixels, at the size a state uses and at ax5 | `finch-true-pixels-large.jpg`, `finch-true-pixels-ax5.jpg` |

Not shot: "No field guide yet", which takes a phone with no field guide, and the bundled set means that doesn't happen in a normal build. It's the same `StateNotice` mark as the empty collection.

Unchanged, on purpose: the Listen hero (its fallback still draws `PerchedBirdDrawing`), set headers, and the Guilds sign-in and join pages, which keep the emblem. See `DECISIONS.md`, "The mascot in the app".

To take them: `capture.sh <udid> <before app> before-`, `capture.sh <udid> <app>`, then the UI test for the icons, then `capture.sh --sheets` and `icon-sheets.py`.
