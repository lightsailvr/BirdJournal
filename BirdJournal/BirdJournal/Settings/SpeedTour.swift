#if DEBUG
import Album
import Foundation
import Pack
import QuartzCore
import SwiftData
import SwiftUI

/// Counts what issue #150's speed work is about: how often the collection is built, and how long that takes (reading the
/// album and comparing, built or not).
enum SpeedProbe {
    private(set) static var builds = 0
    private(set) static var buildTime = Duration.zero

    /// A read of the album by the store, whether or not it built anything.
    static func refreshed(in time: Duration) {
        buildTime += time
    }

    static func built() {
        builds += 1
    }

    static func reset() {
        builds = 0
        buildTime = .zero
    }
}

extension Duration {
    /// Whole milliseconds, for the tour's lines.
    nonisolated var speedMilliseconds: Int {
        Int((Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15).rounded())
    }
}

/// `-speedTour YES`, with `-seedLarge <n>` (issue #150): walks the app's screens by itself and prints a line per step, with
/// the longest the main thread held up a frame, the time over budget in all (frames past 34 ms), how many times the
/// collection was built and how long that took, and the process's CPU time. It works the same on a phone, where the lines
/// are in Xcode's console. Numbers from a Debug build, so compare them with each other, not with a release.
final class SpeedTour {
    private let context: ModelContext
    private let run: ListeningCoordinator
    private let library: PackLibrary
    private let circles: CircleStore
    @Binding private var tab: RootView.Tab
    @Binding private var journalMode: JournalView.Mode
    @Binding private var journalPath: NavigationPath
    @Binding private var guidePath: NavigationPath
    @Binding private var circlesPath: NavigationPath
    private let frames = FrameWatch()

    init(context: ModelContext, run: ListeningCoordinator, library: PackLibrary, circles: CircleStore, tab: Binding<RootView.Tab>, journalMode: Binding<JournalView.Mode>, journalPath: Binding<NavigationPath>, guidePath: Binding<NavigationPath>, circlesPath: Binding<NavigationPath>) {
        self.context = context
        self.run = run
        self.library = library
        self.circles = circles
        _tab = tab
        _journalMode = journalMode
        _journalPath = journalPath
        _guidePath = guidePath
        _circlesPath = circlesPath
    }

    func walk() async {
        let fetchStarted = ContinuousClock.now
        let all = (try? context.fetch(Sighting.newestFirst())) ?? []
        print("SPEED album-fetch ms=\((ContinuousClock.now - fetchStarted).speedMilliseconds)")
        print("SPEED album sightings=\(all.count) launch-builds=\(SpeedProbe.builds) launch-build-ms=\(SpeedProbe.buildTime.speedMilliseconds)")
        // What the store knows the moment the app is up, before any answer from the server.
        print("SPEED guilds-at-launch circles=\(circles.circles.count) feeds=\(circles.feeds.values.filter(\.isLoaded).count)")
        frames.start()
        await step("settle", seconds: 4) {}
        await step("idle-listen", seconds: 3) {}
        await step("collection-tab", seconds: 3) { tab = .journal; journalMode = .cards }
        await step("sightings-mode", seconds: 3) { journalMode = .sightings }
        await step("species-mode", seconds: 3) { journalMode = .species }
        await step("cards-mode", seconds: 2) { journalMode = .cards }
        if let newest = all.first {
            let collection = CardCollection(sightings: all, sets: library.cardSets)
            if let key = collection.patch(of: newest.identifier)?.id {
                await step("patch-page", seconds: 3) { journalPath.append(Route.patch(key)) }
                await step("patch-back", seconds: 2) { journalPath = NavigationPath() }
            }
        }
        await step("add-sighting", seconds: 2) { addSighting() }
        await step("atlas-tab", seconds: 3) { tab = .guide }
        await step("set-page", seconds: 3) { guidePath.append(Route.set(id: PackIndex.bundledPackID)) }
        await step("set-back", seconds: 2) { guidePath = NavigationPath() }
        await step("listen-tab", seconds: 3) { tab = .listen }
        await guilds()
        await listening()
        print("SPEED done")
    }

    /// One thing done, then how the app took it.
    private func step(_ name: String, seconds: Double, _ action: () -> Void) async {
        await frames.settle()
        frames.reset()
        SpeedProbe.reset()
        let cpu = Self.cpuTime()
        action()
        try? await Task.sleep(for: .seconds(seconds))
        report(name, cpu: cpu)
    }

    private func report(_ name: String, cpu: Double, extra: String = "") {
        print("SPEED \(name) worst-frame-ms=\(frames.worst) over-budget-ms=\(frames.over) frames=\(frames.count) builds=\(SpeedProbe.builds) build-ms=\(SpeedProbe.buildTime.speedMilliseconds) cpu-ms=\(Int((Self.cpuTime() - cpu) * 1000))\(extra)")
    }

    private func addSighting() {
        guard let label = try? SpeciesPack.bundled().species.first.map(DebugSeeds.sightingLabel) else { return }
        context.insert(Sighting(speciesID: label, confirmedAt: .now, location: Coordinate(latitude: 34.1365, longitude: -118.2942, accuracy: 15), soundConfidence: 0.7, source: .phone))
        try? context.save()
    }

    /// The Guilds tab and a Guild's page: how long from opening each to its content on screen.
    private func guilds() async {
        guard circles.isAvailable else { return }
        tab = .circles
        var started = ContinuousClock.now
        await waitFor { !circles.circles.isEmpty }
        print("SPEED guild-list content-ms=\((ContinuousClock.now - started).speedMilliseconds)")
        try? await Task.sleep(for: .seconds(1))
        guard let first = circles.circles.first else { return }
        started = ContinuousClock.now
        circlesPath.append(Route.circle(id: first.id))
        await waitFor { circles.feeds[first.id]?.isLoaded == true && circles.details[first.id] != nil }
        print("SPEED guild-page content-ms=\((ContinuousClock.now - started).speedMilliseconds)")
        try? await Task.sleep(for: .seconds(2))
        circlesPath = NavigationPath()
        tab = .listen
        try? await Task.sleep(for: .seconds(1))
    }

    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<600 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Two runs: Start to listening each time, and thirty seconds of the first run on screen.
    private func listening() async {
        guard UserDefaults.standard.string(forKey: "autoPhoneListening") != nil else { return }
        for pass in 1...2 {
            run.source = .phone
            await frames.settle()
            frames.reset()
            SpeedProbe.reset()
            let cpu = Self.cpuTime()
            let started = ContinuousClock.now
            await run.start()
            await waitFor { run.state == .listening }
            let startup = (ContinuousClock.now - started).speedMilliseconds
            report("start-to-listening-\(pass)", cpu: cpu, extra: " ms=\(startup)")
            if pass == 1 {
                await step("listening-30s", seconds: 30) {}
            }
            await run.stop()
            try? await Task.sleep(for: .seconds(2))
            run.dismissEnded()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// The process's user and system CPU seconds so far.
    private static func cpuTime() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
}

/// The gaps between display frames: a long gap is the main thread busy.
private final class FrameWatch: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private(set) var worst = 0
    private(set) var over = 0
    private(set) var count = 0

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func reset() {
        worst = 0
        over = 0
        count = 0
    }

    /// Waits a beat, so the last step's frames don't count for the next.
    func settle() async {
        try? await Task.sleep(for: .milliseconds(200))
    }

    @objc private func tick(_ link: CADisplayLink) {
        defer { last = link.timestamp }
        guard last > 0 else { return }
        let gap = Int((link.timestamp - last) * 1000)
        count += 1
        worst = max(worst, gap)
        if gap > 34 { over += gap - 17 }
    }
}
#endif
