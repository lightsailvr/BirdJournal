# Striking a release

A release is one merge of `dev` into `main`; Xcode Cloud builds `main` for the public beta channel. Do this when the maintainer says it's time to merge with main or strike a release, and at no other time.

Every release carries notes. The app shows the newest entry of `BirdJournal/BirdJournal/WhatsNew/whats-new.json` on the "What's new" card the first time a tester opens it after updating, so the notes are how the maintainer tells testers what changed and what to try. `scripts/release.py` refuses to strike a release without an entry for its version.

## Steps

1. **Agree the version** with the maintainer if they haven't given one. The app is at `MARKETING_VERSION` in `BirdJournal/Version.xcconfig`; a beta release is usually the next minor (0.1.0 → 0.2.0), a fixes-only release the next patch.
2. **Work from dev as GitHub has it**, in a worktree of its own: `git fetch origin && git worktree add ../BirdJournal-release origin/dev`. `dev` must be green (`scripts/build-and-test.sh`); if the last full run is older than the newest merge, run it.
3. **Read what changed**: `scripts/release.py changes` lists every pull request merged into `dev` since `main`, with its description (also written to `build/release/changes.md`). Read the pull requests themselves where a title doesn't say what a birder would notice.
4. **Write the entry** at the top of `whats-new.json`, for the new version, following "How the notes read" below. Leave the older entries alone.
5. **Prepare**: `scripts/release.py prepare <version>` checks the entry, dates it today, sets `MARKETING_VERSION` and commits `Release <version>` here. Nothing is pushed. It prints the card as text.
6. **Show the maintainer the card and wait for their yes on the wording.** Paste the printed card into your reply. If they want to see it drawn, build and launch on your simulator with `-whatsNew show` (a debug build never shows the card unasked). Change the entry as they ask, amend the release commit, and show it again.
7. **Strike**, only after that yes: `scripts/release.py strike --yes`. It pushes the release commit to `dev`, opens the `dev` → `main` pull request with the notes as its body, and merges it with a merge commit. `--dry-run` says what it would do; `--no-merge` leaves the pull request open for the maintainer to merge.
8. **Report** the pull request and the version, and remove the worktree. The maintainer's checkout on `main` needs a `git pull`.

`strike` stops if `dev` has moved since step 5 (rebase the release commit onto `origin/dev` and check whether the notes should mention what arrived) or if `dev` doesn't merge into `main` cleanly (merge `main` into `dev` through a pull request first).

## How the notes read

The reader is a beta tester with the app in their hand, not someone who has seen the repository. Write what they will see and what to do with it.

- **Three to five items**, most noticeable first. Six is the limit; a release with twenty merged pull requests still gets five items. Fold small fixes into one item ("Smoother all round") or leave them out.
- **`title`**: what changed, in a few words, as a heading with no full stop ("Guilds are open"). 40 characters.
- **`detail`**: one or two plain sentences on what it means for the birder. 170 characters.
- **`try`**: what a tester can do to exercise it, as an instruction ("Start a Guild, send its invite to another tester, then each add a bird."). 120 characters. Give one wherever there is something to do; leave it out for changes that just happen (a faster launch).
- **`headline`**: an optional line under the title, like a card's story title, naming the release's main thing. 48 characters, no full stop.
- **`note`**: an optional closing line. Keep the previous release's unless the way to send feedback has changed.
- The app's words, as the screens have them: Guild, patch, Sew it, Collection, Atlas, Listen, run. The product is Featherguild.
- Nothing internal: no issue or pull request numbers, no file, framework or branch names, no "refactor", no test or build changes. If a change has no effect a tester could notice, it isn't on the card.
- Typographic quotes (’ “ ”), British spelling ("colour"), sentence case.
- Don't promise what isn't in the build. Check a claim against the merged code if a pull request's description is ahead of it.

`scripts/release.py check` enforces the lengths, the punctuation and the internal words; `scripts/release.py preview` prints the newest entry as the card lays it out. The tone is yours to get right.

## What the app does with it

`WhatsNewCenter` (in `BirdJournal/BirdJournal/WhatsNew/`) shows the newest entry once per version, when its version is the build's own, to anyone who had the app before this launch; a fresh install sees nothing until its first update. It waits for a moment with no run, review or sheet in the way. Settings → About → "What's new" opens it again. `WhatsNewTests` fails if the newest entry and `MARKETING_VERSION` disagree, which is what a version bumped by hand looks like.
