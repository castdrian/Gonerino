#!/bin/sh
set -eu

device_id="${1:-00008030-001624583AF9402E}"
output_dir="${2:-/tmp/gonerino-blocklist-backup}"
cli_bin="${JB_P1LOT_BIN:-/Users/adrian/go/bin/jb-p1lot}"
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
preference_path=""
remote_copy="/tmp/gonerino-$run_id-youtube.plist"

mkdir -p "$output_dir"

"$cli_bin" device_status --json --device "$device_id" > "$output_dir/device-status.json"
if ! rg -q '"id"[[:space:]]*:[[:space:]]*"00008030-001624583AF9402E"' "$output_dir/device-status.json"; then
    printf '%s\n' "device status did not match the pinned UDID" >&2
    exit 1
fi
if ! rg -q '"productType"[[:space:]]*:[[:space:]]*"iPhone12,8"' "$output_dir/device-status.json"; then
    printf '%s\n' "pinned device is not the iPhone SE" >&2
    exit 1
fi
if ! rg -q '"bridge"[[:space:]]*:[[:space:]]*true' "$output_dir/device-status.json"; then
    printf '%s\n' "pinned device bridge is unavailable" >&2
    exit 1
fi

"$cli_bin" shell_exec --json --device "$device_id" --command "find /var/mobile/Containers/Data/Application -path '*/Library/Preferences/com.google.ios.youtube.plist' -type f -print 2>/dev/null | head -1" > "$output_dir/preference-path.json"
preference_path="$(jq -r '.data.output // empty' "$output_dir/preference-path.json" | sed -n '1p')"
case "$preference_path" in
    /var/mobile/Containers/Data/Application/*/Library/Preferences/com.google.ios.youtube.plist)
        ;;
    *)
        printf '%s\n' "could not locate YouTube's app-container preferences" >&2
        exit 1
        ;;
esac

cleanup() {
    "$cli_bin" shell_exec --json --device "$device_id" --command "rm -f '$remote_copy'" > "$output_dir/remote-cleanup.json" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

"$cli_bin" shell_exec --json --device "$device_id" --command "cp '$preference_path' '$remote_copy'" > "$output_dir/copy.json"
"$cli_bin" file_transfer --json --device "$device_id" --direction download --source "$remote_copy" --destination "$output_dir/youtube-preferences.plist" > "$output_dir/download.json"

python3 - "$output_dir/youtube-preferences.plist" "$output_dir/block-lists.json" <<'PY'
import json
import pathlib
import plistlib
import sys

source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
values = plistlib.loads(source.read_bytes())
keys = ["GonerinoBlockedChannels", "GonerinoBlockedVideos", "GonerinoBlockedWords"]
backup = {key: values.get(key, []) for key in keys}
destination.write_text(json.dumps(backup, indent=2, sort_keys=True) + "\n")
PY

printf '%s\n' "device=$device_id" "preference_path=$preference_path" "backup_dir=$output_dir" > "$output_dir/manifest.txt"
printf '%s\n' "$output_dir"
