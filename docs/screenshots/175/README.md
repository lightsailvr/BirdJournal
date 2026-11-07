# Launch loading — issue #175

Measured on the maintainer's unlocked iPhone 17 Pro running iOS 27.2 on 2026-11-07, preserving the real journal and its downloads. There were **37 sightings** and five loaded field guides: LA v12, Bay v2, Desert v2, SD v4 and Orlando v2. No journal, original photos, authentication tokens or shared widget files were erased or reset.

The baseline is `78a7ad1` with instrumentation only; the after build contains all eight issue fixes (`fbbc2dc` Debug, `d72247e` Release; the latter adds only test changes). Each configuration has one launch immediately after installing over the existing app, followed by two repeat launches. These are process launches with existing filesystem/GPU caches, not erased-device or first-ever GPU compilations.

## Results

Milliseconds; medians of three runs. The origin is the first recorded App Launch lifecycle initialization event, **not a home-screen tap**. First frame means the end of the instrument's Initial Frame Rendering interval.

| Configuration | Before first frame | After first frame | Before synchronous app init | After synchronous app init |
|---|---:|---:|---:|---:|
| Debug | 259.78 | 112.11 | 119.39 | 54.56 |
| Release | 239.25 | 248.43 | 114.62 | 56.89 |

The benefit demonstrated here is less synchronous startup work and an earlier responsive loading surface in Debug. **These measurements do not establish universally faster time to interactive.** Release first-frame medians are similar and the readiness proxy varies substantially.

`Journal interactive` records the root's SwiftUI appearance, which can occur before its pixels are presented. The readiness proxy below is `max(first-frame completion, root appearance)`. It does not measure a tapped response or guarantee that a later Listen frame has been presented. A true tap-to-interactive measurement remains a limitation.

| Configuration / run | Before first frame | After first frame | Before readiness proxy | After readiness proxy |
|---|---:|---:|---:|---:|
| Debug 1, after install | 414.19 | 240.34 | 414.19 | 416.56 |
| Debug 2 | 259.78 | 110.65 | 259.78 | 173.89 |
| Debug 3 | 256.69 | 112.11 | 256.69 | 227.67 |
| Release 1, after install | 418.02 | 248.43 | 418.02 | 413.79 |
| Release 2 | 237.94 | 306.95 | 237.94 | 456.84 |
| Release 3 | 239.25 | 107.14 | 239.25 | 225.70 |

All samples are retained in [the CSV](device-launch-metrics.csv), with phase timings in [the redacted JSON](device-launch-metrics.json). No current normal run reproduced a seconds-long launch hang. All root-appearance signals were below 500 ms. This small, sequential sample does not control background phone activity or thermal state.

The slower second after-Release run also had 74 ms of system-framework initialization (14 ms in run 3), 44 ms in one UIKit scene-creation interval (5 ms in run 3), and 104 ms in app initialization (57 ms in run 3). This affects the comparison; it is not discarded as an outlier.

## What the phase data supports

Before, all pack reads, the collection build and cover decode run on the main thread. After, the trace verifies that the pack reads, initial collection fetch/build, cover decode and shader precompile begin on worker threads. Synchronous app initialization still contains wearable setup, SwiftData container opening/migration, and the small Guild/outbox reads.

Downloaded packs are **still opened eagerly**, together on a worker. In the after-Release runs, opening all packs took 137 / 92 / 80 ms; collection building took 2–3 ms and the cover 16–18 ms. Startup therefore still scales with downloaded packs. Laziness/metadata-only opening remains unfinished rather than being represented as implemented.

The shader did not hold the ready gate in these Release runs: it completed 42 / 66 / 63 ms before pack opening finished. Removing its await would not have improved these measured launches. The current implementation is retained rather than making an unmeasured scheduling change.

A repeated index read whose effective collection sets did not change no longer triggers the second collection fetch. The loading surface adds an accessible status and system progress indicator only after 300 ms of loading, with no fixed minimum hold. A Debug-only explicit loading barrier is covered by UI tests, including Reduce Motion and a repeat launch; the ordinary real-phone reads here finished too quickly to exercise a long spinner interval.

## Missing-widget probe

Two additional Debug launches select a fresh temporary `WidgetStore` using an instrumentation-only `-launchWidgetProbe YES` flag. They use the real journal's latest patch and the production publisher/render path. The shared widget cache is untouched. Both probes verify that an approved painting is present; this exercises the lit patch rather than only its blank.

| Probe | Publication starts, from origin | Full publication interval | Synchronous main work | Worker PNG encode |
|---|---:|---:|---:|---:|
| Before | 502.59 ms | 86.94 ms | 55.15 ms, rendering **and** PNG encoding | — |
| After | 2559.65 ms | 69.78 ms | 1.23 ms, rendering | 28.45 ms |

After publication begins about 2.18 seconds after Listen appears. Its full interval includes awaited texture loading and PNG work; it is not a continuous main-thread block. Neither probe showed a synchronous widget interval over one second. These are single probe runs, not a statistical renderer benchmark.

The GPU/driver cache was not cleared. This covers missing widget files, but does **not** reproduce the very first shader compilation on a fresh device. SwiftUI `ImageRenderer` remains on the main actor. The after implementation delays/coalesces publication for two seconds after store readiness and moves PNG encoding to a worker; it does not claim the renderer itself moved off main.

Probe changes are not shipped: the original integration source bytes and clean Debug product were restored, and the clean review Debug app (`0.1.0`, local commit `fbbc2dc`) was reinstalled and launched on the phone afterward. Raw traces, binaries and device logs remain under ignored local `build/`; only redacted measurements, extraction code and source patches are committed.

## Reproduce

For the baseline, check out `78a7ad1` in an isolated worktree and apply [the instrumentation patch](baseline-instrumentation.patch) with `git apply --unidiff-zero`. Populate real model and pack files using the repository download scripts; resource symlinks to another checkout cannot be installed on a phone. The after revision already includes the launch signposts.

Set `BIRDJOURNAL_PHONE_ID` to the connected phone's identifier. Keep the phone unlocked and install over the existing app; do not uninstall it, reset its album, or pass seeding/in-memory flags.

```sh
xcodebuild -project BirdJournal/BirdJournal.xcodeproj -scheme BirdJournal \
  -configuration Debug -destination "platform=iOS,id=$BIRDJOURNAL_PHONE_ID" \
  -derivedDataPath build/DeviceLaunch -skipMacroValidation -jobs 4 build
xcrun devicectl device install app --device "$BIRDJOURNAL_PHONE_ID" \
  build/DeviceLaunch/Build/Products/Debug-iphoneos/BirdJournal.app
xcrun xctrace record --template 'App Launch' --instrument os_signpost \
  --device "$BIRDJOURNAL_PHONE_ID" --time-limit 12s \
  --output build/launch-debug-1.trace --no-prompt \
  --launch -- com.matthewcelia.mybirdjournal
python3 docs/screenshots/175/extract_launch_metrics.py \
  build/launch-debug-1.trace --output build/launch-debug-1.json
```

Wait for the recording to finish saving before exporting. Repeat twice without reinstalling, then repeat the three-launch series using Release and its `Release-iphoneos` product. If a reused app product fails signing its codeless ONNX stub, remove only that generated app product and its build database before rebuilding, as the repository's normal build script does.

For the cold-widget probes, apply [the baseline probe patch](baseline-widget-probe.patch) after its instrumentation patch, or [the after probe patch](after-widget-probe.patch) to the after revision, using `git apply --unidiff-zero` for these context-free patches. Build Debug, then append `-launchWidgetProbe YES` after the bundle identifier in the recording command. Restore source and reinstall the clean review product after capture.

`extract_launch_metrics.py` exports lifecycle timestamps, the app's launch intervals and aggregate count/version context. It excludes call stacks, identifiers, journal entries and images. The device traces contain profiling warnings about mismatched requested/configured sampling periods; lifecycle and signpost events remain present. Phase timings are wall intervals, not CPU durations: an interval beginning on main can contain an async await and must not be treated as a main-thread stall.

## Automated coverage

`CollectionStoreTests.deferredLaunch` checks deferred initial loading, equality with the album, immediate later saves and idempotent startup. `LaunchPackTests` covers deferred/idempotent pack loading. `PlaceTests` checks asynchronous cover preparation. `LaunchUITests` and the updated `FeelUITests` check progress on first and repeat launches, a working ready screen, Reduce Motion, and the existing animated-launch regression.
