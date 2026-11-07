# UX cohesion slice 10: after the run (issue #150)

Every picture is an iPhone 17 Pro simulator (iOS 27.2) at half size, taken by `capture.sh`, at the default text size (`large`), or larger where the name says so. There's no mock: this follows the rule ("if you read it, it's printed on paper").

| Pick | What | Shots |
|---|---|---|
| L5 | The recap on card stock, with the patches the run sewed and the place the share may carry | `recap-dark`, `recap-light`, `recap-empty-dark`, `recap-empty-light`, `recap-ax5` |
| L5 | What the system share sends: the same card on linen, a fixed size and appearance | `share-image-dark`, `share-image-light` (the same image: it doesn't follow the phone) |
| L5 | Skipped birds can still be added, and the rest are said to go | `recap-dark`; `AfterTheRunUITests` |
| L6 | The real Live Activity: compact and expanded Island, Lock Screen | `real-activity-island-compact`, `real-activity-island-expanded`, `real-activity-lock-screen` |
| L6 | Stop on the Lock Screen, with Collection showing, ends the run and the activity, and the recap is waiting in the app | `real-activity-recap-after-lock-stop`; `GlanceCaptureUITests` taps it |
| L6 | The real widget on a Home Screen, added through the gallery, and what a tap on it opens | `real-widget-home`, `real-widget-opened`; on an iPhone SE, the phone with the lowest image limit, `real-widget-home-se` |
| L6 | The surfaces' own views drawn in the app, for both appearances and every family | `activity-dark`, `activity-light`, `widgets-dark`, `widgets-light`, `activity-large-text`, `widgets-large-text` |

`sheets/` holds the contact sheets the PR shows.

The first run's Lock Screen shows the system's own "Allow Live Activities from Featherguild?" under the activity. That's iOS asking once, after the first activity.

## Tests

- `GlanceTests.swift`: the two pure seams (`RunSnapshot` over the real coordinator and album, `WidgetSnapshot` and its rewrite rule), the activity's lifecycle with a double for ActivityKit, Stop through the intent, the recap's words and place rule, and the share image's metadata.
- `AfterTheRunUITests`: real taps through the recap, the City switch and the system share; Stop from another tab; a review surviving the app being killed; and the widget's link warm, cold, to a patch that's gone, and during an open review.
- `RunEndTests` and `pausedTimeIsNotListened`'s real glasses run: time paused isn't time listened, any end lands on the review, and the review outlives the app.
- `GlanceCaptureUITests`: the system's own UI. It runs only when given a folder, so it isn't in the suite. See `capture.sh`.

## Not provable here

The Dynamic Island's feel, the Lock Screen on a phone's own wallpaper, Stop with the phone really locked and a passcode set, and a glasses run behind a locked phone. These are the slice's on-phone checks.
