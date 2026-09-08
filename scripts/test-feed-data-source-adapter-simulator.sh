#!/bin/sh
set -eu

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
simulator_id="${GONERINO_SIMULATOR_ID:-booted}"
build_dir="$(mktemp -d "$repo_dir/.theos/gonerino-adapter-harness.XXXXXX")"

cleanup() {
    find "$build_dir" -type f -delete
    find "$build_dir" -depth -type d -empty -delete
}
trap cleanup EXIT INT TERM

sdk_path="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun simctl bootstatus "$simulator_id" -b
xcrun clang \
    -arch arm64 \
    -isysroot "$sdk_path" \
    -mios-simulator-version-min=15.0 \
    -fobjc-arc \
    -fblocks \
    -Wno-incomplete-implementation \
    -I"$repo_dir/headers" \
    "$repo_dir/tests/feed-data-source-adapter-harness.m" \
    "$repo_dir/sources/FeedDataSourceAdapter.m" \
    -framework UIKit \
    -framework CoreGraphics \
    -o "$build_dir/GonerinoAdapterHarness"

mkdir -p "$build_dir/GonerinoAdapterHarness.app"
cp "$build_dir/GonerinoAdapterHarness" "$build_dir/GonerinoAdapterHarness.app/GonerinoAdapterHarness"
cp "$repo_dir/tests/feed-data-source-adapter-harness-Info.plist" "$build_dir/GonerinoAdapterHarness.app/Info.plist"
xcrun simctl install "$simulator_id" "$build_dir/GonerinoAdapterHarness.app"
xcrun simctl launch "$simulator_id" dev.adrian.gonerino.adapter-harness >/dev/null

attempt=0
while [ "$attempt" -lt 20 ]; do
    if xcrun simctl spawn "$simulator_id" log show --last 5s --style compact --predicate 'process == "GonerinoAdapterHarness"' 2>/dev/null | rg -q 'PASS: adapter snapshot'; then
        printf '%s\n' "feed data-source adapter simulator checks passed"
        exit 0
    fi
    attempt=$((attempt + 1))
    sleep 0.25
done

xcrun simctl spawn "$simulator_id" log show --last 30s --style compact --predicate 'process == "GonerinoAdapterHarness"' >&2 || true
printf '%s\n' "feed data-source adapter simulator checks did not report a pass" >&2
exit 1
