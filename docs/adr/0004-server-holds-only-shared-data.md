# The server holds only what is shared; the phone holds the journal

Status: accepted, 2026-10-13. Until #137 (2026-11-04) the server also held art jobs and painted art, and a private member's sightings could reach it as transient art-job inputs. Those ended before anyone had a painting on the server, so nothing painted is kept there and the rule has no exception.

The phone's SwiftData store stays the only full copy of a birder's sightings, notes and original photos, restored on a new phone from the iPhone's iCloud backup. The server holds accounts, circles, finds, shared cards, reactions, goals and device tokens. A private member's sightings never reach it. We chose this over syncing the whole journal for signed-in birders. That would have given multi-device access and server-side backup, but a private setting would then still mean "on our server". It would also grow storage costs with every photo and make account deletion and data requests heavier.

## Consequences

- There is no iPad, web or second-phone view of a collection, and patches and set progress are computed on the phone.
- A find carries the facts a circle needs (species, method, place label, time, whether it sewed a new patch and in which edition, rarity, art) so the server never needs the sighting itself. Until #136 (2026-11-04) the new-patch flag was the `legendary` flag, retired with Legendary (#131). The edition is the set's pack id, no finer than the pack id the art key already carried.
