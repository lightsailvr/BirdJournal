# Guild name and icon editor — issue #181

`guild-editor.png` is the iPhone 17 Pro simulator after choosing Bird and Sage, renaming Sunday Group to Lake Birders, saving, and reopening Edit Guild. The saved name and icon persist. The preview has no keyboard or clipping at the default text size.

Validation on 2026-11-07:

- Backend: `uv run pytest -q`, 392 passed; the final focused `tests/test_circles.py` run passed 58 tests, including creator handoff.
- Infrastructure: `uv run pytest -q`, 175 passed. The existing Lambda proxy accepts PATCH and the table grant already includes UpdateItem.
- App: 15 tests passed in HTTPCircleClientTests, CircleStoreTests and AtlasPackCollectionTests, including create/PATCH JSON, old cached Guild decoding, hashed fallback, and stored identity in the list/detail/invite.
- UI: creation and noncreator-hidden-edit tests passed. The edit UI test saved and reopened the correct name/icon, then found the Mark picker did not expose its selected value on the button. Explicit accessibility values were added for Mark and Colour; the final integrated edit UI test passed with the corrected Mark and Colour assertions.

The backend was deployed to the existing `BirdJournal` API in `us-west-2` on 2026-11-07, after the maintainer requested deployment. CloudFormation completed successfully; the deployed Lambda package hash matches the tested artifact. The live OpenAPI document exposes `PATCH /v1/circles/{circle_id}` and emblem fields on create/read/update, health checks pass, and an unauthenticated PATCH returns 401.

The deployment changed only the API function's code/asset metadata in the stack template. An unrelated pending privacy-page asset was deliberately preserved, using a reviewed API-only CloudFormation change set. No table migration was needed. Authenticated creator editing and the noncreator control check are ready for the phone smoke test.
