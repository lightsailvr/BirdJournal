#!/usr/bin/env bash
# Issue #150 slice 7's evidence: a Guild's page against the reference, the Guilds tab, a find's page, the Info sheet, sign-in and
# join, in dark, in light and at the largest text size, from the running app at half size, JPEG. Leaves the text size at `large`,
# and the appearance at dark. Then each felt surface under a moving light, counting patch decodes (`decode-counts.txt`).
#
#   docs/screenshots/150/guilds/capture.sh <simulator UDID> <app path>
#   docs/screenshots/150/guilds/capture.sh --sheets
#
# The waits are fixed, so look over the shots afterwards; CAPTURE_SLOW=<seconds> adds to each wait, and CAPTURE_ONLY=<prefix> takes
# only the shots whose names start with it.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
out="$repo_root/docs/screenshots/150/guilds"
reference="${REFERENCE:-/Users/matthewcelia/Documents/repos/BirdJournal/output/ux-audit/reference/1-guild-page.png}"

if [[ "${1:-}" == "--sheets" ]]; then
    mkdir -p "$out/sheets"
    sheet() {  # name, columns, shots
        local name="$1" columns="$2"; shift 2
        uv run -q "$repo_root/docs/screenshots/138/sheet.py" "$out/sheets/$name.jpg" "$columns" "${@/#/$out/}"
    }
    # The reference first, scaled to the sheet's width like the rest.
    sips -Z 800 -s format jpeg -s formatOptions 80 "$reference" --out "$out/reference-1-guild-page.jpg" >/dev/null
    sheet against-reference 3 reference-1-guild-page.jpg guild-reference-dark.jpg guild-reference-light.jpg
    sheet the-tab 4 tab-two-dark.jpg tab-open-dark.jpg tab-one-dark.jpg tab-two-light.jpg
    sheet a-find 4 find-dark.jpg find-card-dark.jpg find-nopack-dark.jpg find-otheredition-dark.jpg find-secret-dark.jpg find-light.jpg
    sheet info 3 info-dark.jpg info-members-dark.jpg info-light.jpg
    sheet invitations 4 signedout-dark.jpg join-dark.jpg empty-dark.jpg signedout-light.jpg
    sheet ax5 4 guild-ax5.jpg feed-ax5.jpg tab-ax5.jpg find-ax5.jpg info-ax5.jpg join-ax5.jpg
    sheet contrast 2 guild-contrast-dark.jpg guild-contrast-light.jpg
    exit 0
fi

udid="${1:?give the simulator UDID}"
app="${2:?give the app path}"
bundle="com.matthewcelia.mybirdjournal"
slow="${CAPTURE_SLOW:-0}"

xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl install "$udid" "$app"
xcrun simctl privacy "$udid" grant location "$bundle"
xcrun simctl location "$udid" set 34.1365,-118.2942
xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 2>/dev/null || true

launch() {  # seconds flags...
    local wait="$1"; shift
    xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
    sleep 2
    xcrun simctl launch "$udid" "$bundle" "$@" >/dev/null
    sleep $((wait + slow))
}
snap() {
    xcrun simctl io "$udid" screenshot --type=jpeg "$out/$1.jpg" >/dev/null 2>&1
    sips -Z 800 -s formatOptions 78 "$out/$1.jpg" >/dev/null
    echo "$1"
}
shot() {  # name seconds flags...
    local name="$1" wait="$2"; shift 2
    [[ -z "${CAPTURE_ONLY:-}" || "$name" == "$CAPTURE_ONLY"* ]] || return 0
    launch "$wait" "$@"
    snap "$name"
}

base=(-inMemoryAlbum YES -seedJournal YES -collectionIntroShown YES -fakeAccount signedIn -autoLocation griffith)
out_base=(-inMemoryAlbum YES -collectionIntroShown YES -fakeAccount signedOut -fakeCircles empty -autoLocation griffith)

dark_and_light() {
    local suffix="$1"
    shot "guild-reference-$suffix" 10 "${base[@]}" -fakeCircles reference -autoScreen circle
    shot "tab-two-$suffix"         10 "${base[@]}" -fakeCircles shared -autoScreen circles
    shot "find-$suffix"            10 "${base[@]}" -fakeCircles some -autoScreen find
    shot "info-$suffix"            10 "${base[@]}" -fakeCircles some -autoScreen circle-info
    shot "signedout-$suffix"        8 "${out_base[@]}" -autoScreen circles
}

xcrun simctl ui "$udid" content_size large
xcrun simctl ui "$udid" appearance dark
dark_and_light dark
shot feed-dark              10 "${base[@]}" -fakeCircles some -autoScreen circle -autoScrollTo guild-feed
shot tab-open-dark          10 "${base[@]}" -fakeCircles shared -autoScreen circles -autoOpenRepeats YES
shot tab-one-dark           10 "${base[@]}" -fakeCircles one -autoScreen circles
shot find-card-dark         10 "${base[@]}" -fakeCircles some -autoScreen find -autoCardBack YES
shot find-nopack-dark       10 "${base[@]}" -fakeCircles shared -autoScreen find -autoFind lee/00000000-0000-4000-8000-000000000014
shot find-otheredition-dark 10 "${base[@]}" -fakeCircles shared -autoScreen find -autoFind lee/00000000-0000-4000-8000-000000000013
shot find-secret-dark       10 "${base[@]}" -fakeCircles some -autoScreen find -autoFind sam/00000000-0000-4000-8000-000000000003
shot info-members-dark      10 "${base[@]}" -fakeCircles some -autoScreen circle-info -autoScrollTo guild-settings
shot join-dark               8 "${base[@]}" -fakeCircles empty -autoScreen join -autoInvite fake-invite
shot empty-dark              8 "${base[@]}" -fakeCircles empty -autoScreen circles

xcrun simctl ui "$udid" appearance light
dark_and_light light

xcrun simctl ui "$udid" appearance dark
xcrun simctl ui "$udid" content_size accessibility-extra-extra-extra-large
shot guild-ax5 12 "${base[@]}" -fakeCircles reference -autoScreen circle
shot feed-ax5  12 "${base[@]}" -fakeCircles some -autoScreen circle -autoScrollTo guild-feed
shot tab-ax5   12 "${base[@]}" -fakeCircles shared -autoScreen circles
shot find-ax5  12 "${base[@]}" -fakeCircles some -autoScreen find
shot info-ax5  12 "${base[@]}" -fakeCircles some -autoScreen circle-info
shot join-ax5  10 "${base[@]}" -fakeCircles empty -autoScreen join -autoInvite fake-invite
xcrun simctl ui "$udid" content_size large

# Increase Contrast, in both appearances.
xcrun simctl ui "$udid" increase_contrast enabled
xcrun simctl ui "$udid" appearance dark
shot guild-contrast-dark 10 "${base[@]}" -fakeCircles reference -autoScreen circle
xcrun simctl ui "$udid" appearance light
shot guild-contrast-light 10 "${base[@]}" -fakeCircles reference -autoScreen circle
xcrun simctl ui "$udid" increase_contrast disabled
xcrun simctl ui "$udid" appearance dark

# Patches on a feed under a moving light. A healthy sweep decodes each patch once, as it comes on screen (colour and layers, so two
# for each patch), and nothing after that; a thumbnail that had stayed a lazy provider would log AV1 lines at about the frame rate.
decodes() {  # seconds of log
    xcrun simctl spawn "$udid" log show --last "$1" --process BirdJournal --info --style compact 2>/dev/null
}
window() {
    local log
    log="$(decodes 8s)"
    printf '%s patch decodes, %s AV1 or ImageIO lines' "$(grep -c 'patch-decode' <<<"$log" || true)" "$(grep -Ec 'AV1|AVIF|ImageIO' <<<"$log" || true)"
}
count() {  # label flags...
    local label="$1"; shift
    launch 14 "$@" -patchLightSweep YES -patchDecodeLog YES
    local first second
    first="$(window)"
    sleep 12
    second="$(window)"
    printf '%s: first window: %s. 20 s later: %s. Patch decodes in the last minute: %s.\n' "$label" "$first" "$second" "$(decodes 1m | grep -c 'patch-decode' || true)"
}
if [[ -z "${CAPTURE_ONLY:-}" || "counts" == "$CAPTURE_ONLY"* ]]; then
    {
        count "A Guild's page" "${base[@]}" -fakeCircles reference -autoScreen circle
        count "The Guilds tab" "${base[@]}" -fakeCircles shared -autoScreen circles
        count "A find's page" "${base[@]}" -fakeCircles some -autoScreen find
        count "Sign-in, with its samples" "${out_base[@]}" -autoScreen circles
    } | tee "$out/decode-counts.txt"
fi
