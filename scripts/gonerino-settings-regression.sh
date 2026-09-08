#!/bin/sh
set -eu

device_id="${1:-00008030-001624583AF9402E}"
cli_bin="${JB_P1LOT_BIN:-/Users/adrian/go/bin/jb-p1lot}"
pmd3_bin="${PYMOBILEDEVICE3_BIN:-/Users/adrian/.local/bin/pymobiledevice3}"
repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
run_dir="${2:-$(mktemp -d "$repo_dir/.theos/gonerino-settings.XXXXXX")}"
open_count="${3:-20}"

mkdir -p "$run_dir"

capture_text() {
    name="$1"
    "$pmd3_bin" developer dvt screenshot --userspace --udid "$device_id" "$run_dir/$name.png"
    (
        cd "$run_dir"
        tesseract "$name.png" "$name" >/dev/null 2>&1 || :
    )
}

assert_custom_page() {
    name="$1"
    if ! rg -qi 'Donate on Ko-fi|SUPPORT|Support Gonerino development' "$run_dir/$name.txt"; then
        printf '%s\n' "$name did not render the custom Gonerino page" >&2
        printf '%s\n' "$run_dir" >&2
        exit 1
    fi
}

index=1
while [ "$index" -le "$open_count" ]; do
    "$cli_bin" ui_action --json --device "$device_id" --action tap --x 180 --y 97 --deadlineMs 10000 > "$run_dir/open-$index.json"
    sleep 0.05
    capture_text "open-$index-first"
    assert_custom_page "open-$index-first"
    sleep 0.75
    capture_text "open-$index-settled"
    assert_custom_page "open-$index-settled"
    if [ "$index" -lt "$open_count" ]; then
        "$cli_bin" ui_action --json --device "$device_id" --action tap --x 20 --y 42 --deadlineMs 10000 > "$run_dir/back-$index.json"
        sleep 0.25
    fi
    index=$((index + 1))
done

printf '%s\n' "$run_dir"
