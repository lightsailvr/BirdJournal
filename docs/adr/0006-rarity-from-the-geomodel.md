# Rarity comes from the BirdNET geomodel, saved at the add

Status: accepted, 2026-10-13

A card's rarity is the BirdNET geomodel v3.0.4's occurrence probability for the species at the sighting's coordinate and week. It is saved with the sighting at the add, with the calibration version, and shown as Common, Uncommon, Rare or Exceptional. The obvious source, eBird frequency, is non-commercial and not redistributable. GBIF occurrence counts mix licenses, are patchy, and would be a large build. iNaturalist counts already order the packs but ignore season. The geomodel is Apache-2.0, already on the phone, works offline everywhere, and is seasonal. It measures "expected here this week" rather than "reported here", which is close enough for a card.

## Consequences

- Identification already drops species below 0.03 occurrence when there is a location, so the label thresholds are calibrated above that floor.
- A sighting without a location gets "Rarity unavailable for this place and season", never a guess.
- Changing the source later leaves old cards with their saved labels. Snapshots are never recomputed.

## Amendment, 2026-11-11: a bird changed by the birder (#190)

One case reads a sighting's rarity after its add. When the birder changes the bird of a sighting they named from a photo ("Change bird", #190), the snapshot saved for the old bird would be a label for the wrong species, so rarity is read again, once, for the new bird at the sighting's own coordinate and in the week of its own date (`SightingRecorder.changeBird`). A new bird the geomodel doesn't know, or a sighting with no place, has none afterwards.

This is a first reading for a different bird, not a recomputation: the snapshot of a bird at a place and week is still never read twice, and a change of source or calibration still leaves every saved label as it was.
