# Launch loading — issue #175

The connected iPhone 17 Pro was detected, and the unmodified Debug app built successfully. A baseline App Launch recording was attempted before installing the changed build, using the existing installed app and the real journal. Instruments reported:

> Instruments will start recording when Matt’s iPhone 17 Pro (27.2) is unlocked.

The phone's `devicectl device info lockState` reported `passcodeRequired: true`. The recording ended without run data (`xctrace export --toc`: "Trace is malformed - run data is missing"). Consequently there are **no valid device before/after numbers**, in either configuration. The existing app's journal was not erased or reset. The first attempted installation was rejected transactionally because the worktree's model resources were absolute symlinks; those resources were replaced with real files for subsequent builds.

## Capture on the unlocked phone

Use the real journal and installed packs, without `-inMemoryAlbum`, `-seedLarge` or reset flags. Keep the device unlocked for the full capture. Build and capture both `dev` and this branch in Debug and Release. `dev` can be captured using its already-installed app first. Never uninstall the app to change builds: installing the same bundle identifier preserves its container.

```sh
xcodebuild -project BirdJournal/BirdJournal.xcodeproj -scheme BirdJournal \
  -configuration Debug -destination 'platform=iOS,id=00008150-001643C91E08401C' \
  -derivedDataPath build/DeviceLaunch -skipMacroValidation -jobs 4 build
xcrun devicectl device install app --device 00008150-001643C91E08401C \
  build/DeviceLaunch/Build/Products/Debug-iphoneos/BirdJournal.app
xcrun xctrace record --template 'App Launch' \
  --device 00008150-001643C91E08401C --time-limit 20s \
  --output build/launch-after-debug.trace --no-prompt \
  --launch -- com.matthewcelia.mybirdjournal
```

Repeat with `-configuration Release`, its `Release-iphoneos` product, and a distinct output trace. Clean the app product before rebuilding a different configuration if Xcode's stub ONNX framework reports "bundle format unrecognized"; the repository's build script documents this existing workaround.

Record launch duration to the first frame using the App Launch instrument. Record time to usable Listen against the `Journal interactive` event. The `Launch surface appeared` signpost denotes SwiftUI appearance, **not** a claim that its pixels have been presented. Compare the main-thread timeline with these `launch` category intervals:

- App init; Configure wearables; Open album store; Read Guild cache; Read find outbox
- Stores ready; Open packs; Open bundled pack; Open downloaded packs; Read cached index and sets
- Build collection; Decode cover; Warm patch shader; Refresh pack index; Publish widget

Take at least three launches per configuration, record installed pack versions and sighting count, and distinguish first-install shader/cache work from repeat launches. Verify that the loading status animates during a slow real read, and that no main-thread interval leaves it static for a second. The widget's ImageRenderer remains on main, deferred two seconds after readiness; its duration especially needs the phone trace.

## Automated coverage

`CollectionStoreTests.deferredLaunch` checks that the initial fetch is deferred, the background result matches the album, later saves are immediate, and a second start cannot overwrite live state. `LaunchPackTests` covers deferred/idempotent pack loading. `PlaceTests` checks the new asynchronous initial-cover contract. `LaunchUITests.testSlowRepeatLaunchShowsProgressUntilTheStoresAreReady` holds real loading behind an explicit test tap in Debug only, with Reduce Motion on and the old splash already marked shown, and checks progress is replaced by the ready tabs.
