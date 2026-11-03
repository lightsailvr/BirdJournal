# Featherguild: the final screenshot review (#110, taken for #119)

Every reskinned screen and every designed state of design guide page 16, from an iPhone 17 Pro simulator (iOS 27.2) on
Los Angeles v10, half size, reduced to 256 colours, taken by `capture.sh`. Each shot is in three appearances: `-dark`,
`-light` and `-ax3` (light at accessibility extra large). The seeded collection is #28's six sightings
(`-inMemoryAlbum YES -seedJournal YES`); the Guilds use the in-memory fake server (`-fakeAccount signedIn -fakeCircles
some`); runs play the example soundscape with a location fix in Griffith Park. Compare them with the boards in
`docs/design/featherguild/pages/`: page 3 (Listen, Collection and a Guild, dark), page 4 (active listening, Atlas and
Guilds, light), pages 5–6 (the card fronts, collection to story) and page 15 (the flip and the reveal).

## Screens

| Shot | What | Board |
|---|---|---|
| `screen-listen-ready` | Listen, ready: the Los Angeles cover, the source, Start listening, the local set | 3 |
| `screen-listen-active` | A phone run: the time, the waveform, the candidates, Stop | 4 |
| `screen-reveal` | The Legendary reveal of the Black Phoebe | 15 |
| `screen-cards`, `screen-sightings`, `screen-species` | Collection's three modes | 3, 6 |
| `screen-card-front`, `screen-card-back` | The Black Phoebe's card, front (Legendary) and back | 5, 6, 15 |
| `screen-share` | "A story to share" with the rendered card | — |
| `screen-atlas`, `screen-set`, `screen-profile`, `screen-packs` | The Atlas, the Los Angeles set, the Black Phoebe's profile, the bird packs | 4 |
| `screen-guilds`, `screen-guild`, `screen-guild-feed` | The Guilds list, Sunday Group's page, its finds | 3, 4 |
| `screen-settings` | Settings | — |
| `screen-accessory` | Collection with a run on: the listening accessory over the tab bar | 3 |

## States (page 16)

| State | Shot |
|---|---|
| No cards yet | `state-no-cards` |
| No Guilds yet | `state-no-guilds` |
| Signed out | `state-signed-out` |
| Offline | `state-offline-guilds`, `state-offline-atlas` (the last good sets), `state-offline-pack` (a download's "You're offline", from the debug transfer states) |
| No location | `state-no-location-listen` (the run's notice), `state-no-location-rarity` (the card: "Place not recorded") |
| Unknown rarity | `state-no-location-rarity` ("Rarity unavailable for this place and season"; the Common Blackbird also has no art) |
| Art pending, art failed | `state-art-pending`, `state-art-failed` (the card, saved either way) |
| Empty filters or search | `state-search-collection`, `state-search-atlas` |
| Denied microphone | `state-denied-microphone` (the real denial: `simctl privacy revoke microphone`) |
| Denied location | `state-no-location-listen` |
| Denied notifications | `state-denied-notifications` (a Guild's settings) |
| Disconnected glasses | `state-glasses-not-connected`, `state-glasses-none-linked`, `state-glasses-unregistered` (`-fakeGlasses`) |

## Accessibility

- `ax5-listen`, `ax5-cards`, `ax5-card-front`, `ax5-atlas`, `ax5-guild`: the five screens of the VoiceOver walk
  (`ScreenAccessibilityTests`) at the largest accessibility size (light), checked for clipping and overlap.
- `contrast-accessory-dark|light`, `contrast-listen-dark|light`: the system glass (the tab bar, the listening
  accessory) with Increase Contrast. `measure-glass.py` measures the glass on full-size screenshots; the figures are in
  DECISIONS.md, "Featherguild slice 4".
