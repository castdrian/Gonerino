#!/bin/sh
set -eu

if [ "$#" -lt 3 ]; then
    printf '%s\n' "usage: gonerino-performance.sh DEVICE enabled|disabled home|subscriptions|search|long-form|shorts [duration_ms] [output_dir]" >&2
    exit 2
fi

cli_bin="${JB_P1LOT_BIN:-/Users/adrian/go/bin/jb-p1lot}"
device_id="$1"
run_mode="$2"
profile="$3"
duration_ms="${4:-60000}"
output_root="${5:-/tmp/gonerino-performance}"
youtube_bundle_id="${YOUTUBE_BUNDLE_ID:-com.google.ios.youtube}"
gesture_duration_ms=450

case "$run_mode" in
    enabled|disabled)
        ;;
    *)
        printf '%s\n' "mode must be enabled or disabled" >&2
        exit 2
        ;;
esac

case "$profile" in
    home|subscriptions|search|long-form|shorts)
        ;;
    *)
        printf '%s\n' "profile must be home, subscriptions, search, long-form, or shorts" >&2
        exit 2
        ;;
esac

if ! command -v perl >/dev/null 2>&1; then
    printf '%s\n' "perl is required for millisecond timing" >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1 || [ ! -x /usr/bin/plutil ]; then
    printf '%s\n' "jq and macOS plutil are required for preference control" >&2
    exit 1
fi

now_ms() {
    perl -MTime::HiRes -e 'printf "%.0f\n", Time::HiRes::time() * 1000'
}

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
run_dir="$output_root/$run_mode-$profile-$run_id"
mkdir -p "$run_dir"
preference_path=""
preference_original_file=""
run_finished=0
restore_preferences() {
    if [ -z "$preference_path" ] || [ ! -f "$preference_original_file" ]; then
        return 0
    fi

    "$cli_bin" shell_exec --json --device "$device_id" --command "killall -9 YouTube >/dev/null 2>&1 || true" > "$run_dir/preference-restore-force-quit.json" 2>/dev/null || true
    if "$cli_bin" file_transfer --json --device "$device_id" --direction upload --source "$preference_original_file" --destination "$preference_device_temp" > "$run_dir/preference-restore-upload.json" 2>/dev/null; then
        "$cli_bin" shell_exec --json --device "$device_id" --command "chown mobile:mobile '$preference_device_temp' && chmod 600 '$preference_device_temp' && mv '$preference_device_temp' '$preference_path' && killall -9 cfprefsd >/dev/null 2>&1 || true" > "$run_dir/preference-restore-ownership.json" 2>/dev/null || true
    fi
}
finish_run() {
    if [ "$run_finished" -ne 0 ]; then
        return 0
    fi
    run_finished=1
    restore_preferences
    "$cli_bin" ui_action --json --device "$device_id" --action screen_off > "$run_dir/screen-off.json" 2>/dev/null || true
}
trap finish_run EXIT INT TERM

"$cli_bin" device_list --json > "$run_dir/device-list.json"
"$cli_bin" device_status --json --device "$device_id" > "$run_dir/device-status.json"
if ! rg -q "\"id\"[[:space:]]*:[[:space:]]*\"$device_id\"" "$run_dir/device-status.json"; then
    printf '%s\n' "device status did not match the pinned UDID" >&2
    exit 1
fi
if ! rg -q '"productType"[[:space:]]*:[[:space:]]*"iPhone12,8"' "$run_dir/device-status.json"; then
    printf '%s\n' "pinned device is not the iPhone SE" >&2
    exit 1
fi
if ! rg -q '"bridge"[[:space:]]*:[[:space:]]*true' "$run_dir/device-status.json"; then
    printf '%s\n' "pinned device bridge is unavailable" >&2
    exit 1
fi

preference_value=false
if [ "$run_mode" = "enabled" ]; then
    preference_value=true
fi

"$cli_bin" ui_action --json --device "$device_id" --action screen_on > "$run_dir/screen-on.json"
"$cli_bin" ui_action --json --device "$device_id" --action button --button unlock > "$run_dir/unlock.json"
"$cli_bin" shell_exec --json --device "$device_id" --command "killall -9 YouTube >/dev/null 2>&1 || true" > "$run_dir/force-quit.json"
sleep 2

"$cli_bin" shell_exec --json --device "$device_id" --command "find /var/mobile/Containers/Data/Application -path '*/Library/Preferences/com.google.ios.youtube.plist' -type f -print 2>/dev/null | head -1" > "$run_dir/preference-path.json"
preference_path="$(jq -r '.data.output // empty' "$run_dir/preference-path.json" | sed -n '1p')"
case "$preference_path" in
    /var/mobile/Containers/Data/Application/*/Library/Preferences/com.google.ios.youtube.plist)
        ;;
    *)
        printf '%s\n' "could not locate YouTube's app-container preferences" >&2
        exit 1
        ;;
esac

preference_device_temp="/tmp/gonerino-$run_id-youtube.plist"
preference_file="$run_dir/youtube-preferences.plist"
preference_original_file="$run_dir/youtube-preferences-original.plist"
preference_copy_json="$run_dir/preference-copy.json"
"$cli_bin" shell_exec --json --device "$device_id" --command "cp '$preference_path' '$preference_device_temp'" > "$preference_copy_json"
if ! rg -q '"exitCode"[[:space:]]*:[[:space:]]*0' "$preference_copy_json"; then
    printf '%s\n' "could not stage YouTube's preferences" >&2
    exit 1
fi
"$cli_bin" file_transfer --json --device "$device_id" --direction download --source "$preference_device_temp" --destination "$preference_original_file" > "$run_dir/preference-download-original.json"
"$cli_bin" file_transfer --json --device "$device_id" --direction download --source "$preference_device_temp" --destination "$preference_file" > "$run_dir/preference-download.json"
if ! /usr/bin/plutil -replace GonerinoEnabled -bool "$preference_value" "$preference_file"; then
    /usr/bin/plutil -insert GonerinoEnabled -bool "$preference_value" "$preference_file"
fi
/usr/bin/plutil -extract GonerinoEnabled raw -o - "$preference_file" > "$run_dir/preference-read.txt"
"$cli_bin" file_transfer --json --device "$device_id" --direction upload --source "$preference_file" --destination "$preference_device_temp" > "$run_dir/preference-upload.json"
"$cli_bin" shell_exec --json --device "$device_id" --command "chown mobile:mobile '$preference_device_temp' && chmod 600 '$preference_device_temp' && mv '$preference_device_temp' '$preference_path' && killall -9 cfprefsd >/dev/null 2>&1 || true" > "$run_dir/preference-ownership.json"
"$cli_bin" app_manage --json --device "$device_id" --action launch --bundleId "$youtube_bundle_id" > "$run_dir/launch.json"
sleep 3
"$cli_bin" screen_capture --json --device "$device_id" > "$run_dir/start-screen.json"
"$cli_bin" crash_manage --json --device "$device_id" --action list --process YouTube > "$run_dir/crashes-before.json"
"$cli_bin" process_manage --json --device "$device_id" --action list > "$run_dir/processes-before.json"

case "$profile" in
    home)
        profile_action="tap-home"
        profile_x=40
        profile_y=635
        search_query=""
        ;;
    subscriptions)
        profile_action="tap-subscriptions"
        profile_x=260
        profile_y=635
        search_query=""
        ;;
    search)
        profile_action="tap-search"
        profile_x=345
        profile_y=48
        search_query="cats"
        ;;
    long-form)
        profile_action="tap-search"
        profile_x=345
        profile_y=48
        search_query="documentary"
        ;;
    shorts)
        profile_action="tap-shorts"
        profile_x=112
        profile_y=635
        search_query=""
        ;;
esac

profile_start=$(now_ms)
"$cli_bin" ui_action --json --device "$device_id" --action tap --x "$profile_x" --y "$profile_y" --deadlineMs 10000 > "$run_dir/profile-navigation.json"
profile_end=$(now_ms)
printf '%s\n' "start_ms=$profile_start" "end_ms=$profile_end" "elapsed_ms=$((profile_end - profile_start))" "action=$profile_action" "query=$search_query" > "$run_dir/profile-navigation.txt"
sleep 2

if [ -n "$search_query" ]; then
    search_text_status=0
    "$cli_bin" ui_action --json --device "$device_id" --action text --text "$search_query" --deadlineMs 10000 > "$run_dir/search-text.json" || search_text_status=$?
    if [ "$search_text_status" -ne 0 ]; then
        printf '%s\n' "search text injection failed; repair jb-p1lot text input before using search profiles" > "$run_dir/search-status.txt"
        exit 1
    fi
    "$cli_bin" ui_action --json --device "$device_id" --action tap --x 338 --y 620 --deadlineMs 10000 > "$run_dir/search-submit.json"
    sleep 3
fi

case "$profile" in
    home|subscriptions|search|long-form)
        start_x=188
        start_y=585
        end_x=188
        end_y=185
        scroll_count=12
        ;;
    shorts)
        start_x=188
        start_y=600
        end_x=188
        end_y=90
        scroll_count=12
        ;;
esac

printf '%b\n' 'index\tstarted_ms\tended_ms\tcommand_ms\tdevice_action_ms\tgesture_ms\ttouch_overhead_ms\tstall_over_50ms\thang\tstatus' > "$run_dir/touch-latency.tsv"
printf '%b\n' 'sample\tstarted_ms\tended_ms\tcommand_ms\tscreen_status\tsnapshot_status' > "$run_dir/frame-responsiveness.tsv"

calibration_start=$(now_ms)
calibration_status=0
"$cli_bin" ui_action --json --device "$device_id" --action tap --x 1 --y 1 --deadlineMs 10000 > "$run_dir/touch-calibration.json" || calibration_status=$?
calibration_end=$(now_ms)
calibration_ms=$((calibration_end - calibration_start))
calibration_action_ms="$(jq -r '.data.actionDurationMs // empty' "$run_dir/touch-calibration.json")"
if [ "$calibration_status" -ne 0 ]; then
    printf '%s\n' "touch calibration failed" >&2
    exit 1
fi
if [ -z "$calibration_action_ms" ]; then
    printf '%s\n' "touch calibration did not return device-side action timing" >&2
    exit 1
fi
calibration_action_ms="$(printf '%s\n' "$calibration_action_ms" | perl -ne 'chomp; printf "%.0f\n", $_')"
printf '%s\n' "started_ms=$calibration_start" "ended_ms=$calibration_end" "command_ms=$calibration_ms" "device_action_ms=$calibration_action_ms" "status=$calibration_status" > "$run_dir/touch-calibration.txt"

calibration_swipe_status=0
"$cli_bin" ui_action --json --device "$device_id" --action swipe --x "$start_x" --y "$start_y" --points "[[${start_x},${start_y}],[${end_x},${end_y}]]" --durationMs "$gesture_duration_ms" --deadlineMs 10000 > "$run_dir/touch-calibration-swipe.json" || calibration_swipe_status=$?
calibration_swipe_action_ms="$(jq -r '.data.actionDurationMs // empty' "$run_dir/touch-calibration-swipe.json")"
if [ "$calibration_swipe_status" -ne 0 ] || [ -z "$calibration_swipe_action_ms" ]; then
    printf '%s\n' "swipe calibration failed" >&2
    exit 1
fi
calibration_swipe_action_ms="$(printf '%s\n' "$calibration_swipe_action_ms" | perl -ne 'chomp; printf "%.0f\n", $_')"
printf '%s\n' "device_action_ms=$calibration_swipe_action_ms" "status=$calibration_swipe_status" > "$run_dir/touch-calibration-swipe.txt"

capture_frame_sample() {
    sample_label="$1"
    sample_start=$(now_ms)
    screen_status=0
    snapshot_status=0
    "$cli_bin" screen_capture --json --device "$device_id" > "$run_dir/frame-$sample_label-screen.json" || screen_status=$?
    "$cli_bin" ui_snapshot --json --device "$device_id" --application YouTube > "$run_dir/frame-$sample_label-snapshot.json" || snapshot_status=$?
    sample_end=$(now_ms)
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$sample_label" "$sample_start" "$sample_end" "$((sample_end - sample_start))" "$screen_status" "$snapshot_status" >> "$run_dir/frame-responsiveness.tsv"
}

collect_process_metrics() {
    sample_label="$1"
    "$cli_bin" metrics_stream --json --device "$device_id" --process YouTube --durationMs 5000 --intervalMs 250 > "$run_dir/metrics-$sample_label.json"
}

collect_process_metrics before

index=0
run_started_ms=$(now_ms)
while [ "$index" -eq 0 ] || [ $(( $(now_ms) - run_started_ms )) -lt "$duration_ms" ]; do
    started_ms=$(now_ms)
    swipe_status=0
    "$cli_bin" ui_action --json --device "$device_id" --action swipe --x "$start_x" --y "$start_y" --points "[[${start_x},${start_y}],[${end_x},${end_y}]]" --durationMs "$gesture_duration_ms" --deadlineMs 10000 > "$run_dir/swipe-$index.json" || swipe_status=$?
    ended_ms=$(now_ms)
    command_ms=$((ended_ms - started_ms))
    device_action_ms="$(jq -r '.data.actionDurationMs // empty' "$run_dir/swipe-$index.json")"
    if [ -z "$device_action_ms" ]; then
        printf '%s\n' "swipe $index did not return device-side action timing" >&2
        exit 1
    fi
    device_action_ms="$(printf '%s\n' "$device_action_ms" | perl -ne 'chomp; printf "%.0f\n", $_')"
    touch_overhead_ms=$((device_action_ms - calibration_swipe_action_ms))
    if [ "$touch_overhead_ms" -lt 0 ]; then
        touch_overhead_ms=0
    fi
    stall_over_50ms=0
    if [ "$touch_overhead_ms" -gt 50 ]; then
        stall_over_50ms=1
    fi
    hang=0
    if [ "$swipe_status" -ne 0 ] || [ "$command_ms" -gt 5000 ]; then
        hang=1
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$index" "$started_ms" "$ended_ms" "$command_ms" "$device_action_ms" "$gesture_duration_ms" "$touch_overhead_ms" "$stall_over_50ms" "$hang" "$swipe_status" >> "$run_dir/touch-latency.tsv"
    if [ $((index % 3)) -eq 0 ]; then
        capture_frame_sample "$index"
        collect_process_metrics "sample-$index"
    fi
    index=$((index + 1))
    sleep 1
done

collect_process_metrics after
capture_frame_sample end
"$cli_bin" process_manage --json --device "$device_id" --action list > "$run_dir/processes-after.json"
"$cli_bin" crash_manage --json --device "$device_id" --action list --process YouTube > "$run_dir/crashes-after.json"
printf '%s\n' "mode=$run_mode" "profile=$profile" "duration_ms=$duration_ms" "scroll_count=$scroll_count" "device=$device_id" "product_type=iPhone12,8" "youtube_bundle_id=$youtube_bundle_id" > "$run_dir/run.txt"
printf '%s\n' "$run_dir"
