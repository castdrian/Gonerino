#!/bin/sh
set -eu

device_id="${1:-00008030-001624583AF9402E}"
backup_dir="${2:-/tmp/gonerino-blocklist-backup}"
output_dir="${3:-$backup_dir/restore-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
cli_bin="${JB_P1LOT_BIN:-/Users/adrian/go/bin/jb-p1lot}"
repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
preference_path=""
remote_current="/tmp/gonerino-$run_id-youtube-current.plist"
remote_restore="/tmp/gonerino-$run_id-youtube-restore.plist"

mkdir -p "$output_dir"
if [ ! -f "$backup_dir/block-lists.json" ]; then
    printf '%s\n' "block-list backup is missing" >&2
    exit 1
fi

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
    "$cli_bin" shell_exec --json --device "$device_id" --command "rm -f '$remote_current' '$remote_restore'" > "$output_dir/remote-cleanup.json" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

"$cli_bin" shell_exec --json --device "$device_id" --command "killall -9 YouTube >/dev/null 2>&1 || true; cp '$preference_path' '$remote_current'" > "$output_dir/copy.json"
"$cli_bin" file_transfer --json --device "$device_id" --direction download --source "$remote_current" --destination "$output_dir/youtube-preferences-current.plist" > "$output_dir/download.json"

python3 "$repo_dir/scripts/merge-gonerino-blocklists.py" \
    "$output_dir/youtube-preferences-current.plist" \
    "$backup_dir/block-lists.json" \
    "$output_dir/youtube-preferences-restored.plist"

"$cli_bin" file_transfer --json --device "$device_id" --direction upload --source "$output_dir/youtube-preferences-restored.plist" --destination "$remote_restore" > "$output_dir/upload.json"
"$cli_bin" shell_exec --json --device "$device_id" --command "chown mobile:mobile '$remote_restore' && chmod 600 '$remote_restore' && mv '$remote_restore' '$preference_path' && killall -9 cfprefsd >/dev/null 2>&1 || true" > "$output_dir/install.json"

printf '%s\n' "device=$device_id" "preference_path=$preference_path" "backup_dir=$backup_dir" "restore_dir=$output_dir" > "$output_dir/manifest.txt"
printf '%s\n' "$output_dir"
