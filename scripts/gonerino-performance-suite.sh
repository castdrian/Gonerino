#!/bin/sh
set -eu

cli_bin="/Users/adrian/go/bin/jb-p1lot"
if [ -n "${JB_P1LOT_BIN-}" ]; then
    cli_bin="$JB_P1LOT_BIN"
fi
device_id="${GONERINO_DEVICE_ID:-00008030-001624583AF9402E}"
duration_ms="${GONERINO_PERFORMANCE_DURATION_MS:-60000}"
output_root="${GONERINO_PERFORMANCE_OUTPUT:-/tmp/gonerino-performance-suite}"
performance_script="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/gonerino-performance.sh"
package_path="${GONERINO_PACKAGE-}"

if [ "$#" -eq 0 ]; then
    profiles="home subscriptions search long-form shorts"
else
    profiles="$*"
fi

mkdir -p "$output_root"
"$cli_bin" device_list --json > "$output_root/device-list.json"
if ! rg -q "\"id\"[[:space:]]*:[[:space:]]*\"$device_id\"" "$output_root/device-list.json"; then
    printf '%s\n' "the pinned SE UDID was not found" >&2
    exit 1
fi
if ! rg -q '"productType"[[:space:]]*:[[:space:]]*"iPhone12,8"' "$output_root/device-list.json"; then
    printf '%s\n' "the pinned UDID is not an iPhone SE" >&2
    exit 1
fi

if [ -n "$package_path" ]; then
    "$cli_bin" tweak_deploy --json --device "$device_id" --package "$package_path" --processes YouTube --reload none > "$output_root/deployment.json"
    "$cli_bin" shell_exec --json --device "$device_id" --command "killall -9 YouTube >/dev/null 2>&1 || true" > "$output_root/deployment-force-quit.json"
    sleep 2
    "$cli_bin" app_manage --json --device "$device_id" --action launch --bundleId com.google.ios.youtube > "$output_root/deployment-launch.json"
    sleep 3
fi

printf '%s\n' "profile\tmode\tpath" > "$output_root/runs.tsv"
for profile in $profiles; do
    enabled_path=$("$performance_script" "$device_id" enabled "$profile" "$duration_ms" "$output_root")
    printf '%s\t%s\t%s\n' "$profile" enabled "$enabled_path" >> "$output_root/runs.tsv"
    disabled_path=$("$performance_script" "$device_id" disabled "$profile" "$duration_ms" "$output_root")
    printf '%s\t%s\t%s\n' "$profile" disabled "$disabled_path" >> "$output_root/runs.tsv"
done

printf '%s\n' "device=$device_id" "product_type=iPhone12,8" "duration_ms=$duration_ms" "profiles=$profiles" > "$output_root/suite.txt"
"$cli_bin" device_action --json --device "$device_id" --action screen_off --reason "Gonerino performance suite complete" > "$output_root/screen-off.json" 2>/dev/null || true
printf '%s\n' "$output_root"

