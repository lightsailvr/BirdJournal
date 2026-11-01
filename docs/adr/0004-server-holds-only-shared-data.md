# The server holds only what is shared; the phone holds the journal

Status: accepted, 2026-10-13

The phone's SwiftData store stays the only full copy of a birder's sightings, notes and original photos, restored on a new phone from the iPhone's iCloud backup. The server holds accounts, circles, finds, shared cards, reactions, goals, device tokens and art jobs. It keeps painted art only while a find or shared card shows it, and otherwise deletes it once the phone has downloaded it. A private member's sightings never reach it except as transient art-job inputs, which are deleted after a day. We chose this over syncing the whole journal for signed-in birders. That would have given multi-device access and server-side backup, but a private setting would then still mean "on our server". It would also grow storage costs with every photo and make account deletion and data requests heavier.

## Consequences

- There is no iPad, web or second-phone view of a collection, and Legendary and set progress are computed on the phone.
- A find carries the facts a circle needs (species, method, place label, time, Legendary and rarity flags, card art) so the server never needs the sighting itself.
