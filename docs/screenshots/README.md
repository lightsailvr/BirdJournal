# docs/screenshots/

Simulator screenshots of the phone screens, one folder per capture date, written by `scripts/screenshots.sh` at half
size (an iPhone 17 simulator, iOS 27). They are review evidence for the field-journal UX of issue #28, not design
references: `docs/design/` on the `docs/field-journal-design-2026-09-27` branch holds the boards.

File names are `<screen>-<appearance>.png` (`light`, `dark`), `<screen>-xxxl.png` (the largest non-accessibility
Dynamic Type size) and `<screen>-ax5.png` (the largest accessibility size); `journal-empty` and `listen-empty` are
the first-launch states. The journal screens run on `-seedJournal YES` sample sightings with generated frames (a green
field with a ring, standing in for a glasses camera frame); the listening screens are driven by the labeled clip from
`scripts/download-clips.sh` through the phone-microphone path. Hardware states (a glasses run, pause, reconnect) are
not pictured: DAT-SETUP-CHECKLIST.md step 9 verifies them on the glasses.

`2026-10-02/` is the evidence for issue #42 (calling-now order): the mock lens list with the newest caller marked
(`lens-list-calling`), the same list after the one-shot re-send cleared the lapsed marker (`lens-list-lapsed`), a
details page naming the bird calling now (`lens-details-now`), and the Listen tab with two rows calling and the same
rows twenty seconds later, aged and reordered (`listening-calling-dark`, `listening-aged-dark`); the lens shots are
the Developer hub's mock preview, full size.
