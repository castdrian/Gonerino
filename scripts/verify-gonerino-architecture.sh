#!/bin/sh
set -eu

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

if rg -n "layoutSubviews|didMoveToWindow|scheduleFiltering|FilterVisible|GapCollapse|filterScheduled|lastFilterTime|MetadataNodeForView|CollectTextNodeValues|CollectElementTreeMetadata|CollectObject|VideoNodeFromView|ActionMetadataNodeFromObject|VisibleFeedCellForVideoID|AsyncCollectionViewInView|\.transform" "$repo_dir/sources/Util.m" "$repo_dir/sources/Tweak.x"; then
    printf '%s\n' "legacy UI-driven filtering symbols are still present" >&2
    exit 1
fi

rg -q "FeedMetadataRecord" "$repo_dir/headers/Util.h"
rg -q "AdaptLongFormVideoNode" "$repo_dir/sources/Util.m"
rg -q "AdaptElementsFeedNode" "$repo_dir/sources/Util.m"
rg -q "AdaptShortsNode" "$repo_dir/sources/Util.m"
rg -q "nodeForItemAtIndexPath" "$repo_dir/sources/Tweak.x"
rg -q "FilteredNodeForBlockedVideo" "$repo_dir/sources/Tweak.x"
rg -q "pushViewController" "$repo_dir/sources/Settings.x"
rg -q "FeedFilterStateDidChangeNotification" "$repo_dir/sources/Tweak.x" "$repo_dir/sources/CustomSettings.m" "$repo_dir/sources/Util.m"
rg -q 'long-form' "$repo_dir/scripts/gonerino-performance.sh"
rg -q '00008030-001624583AF9402E' "$repo_dir/scripts/gonerino-performance-suite.sh"
rg -q '"rendererClass": "YTVideoNode"' "$repo_dir/tests/metadata-fixtures.json"
rg -q '"rendererClass": "YTVideoWithContextNode"' "$repo_dir/tests/metadata-fixtures.json"
rg -q '"rendererClass": "ELMCellNode"' "$repo_dir/tests/metadata-fixtures.json"
rg -q '"rendererClass": "YTShortsVideoNode"' "$repo_dir/tests/metadata-fixtures.json"
rg -q '"expectedVisible": true' "$repo_dir/tests/metadata-fixtures.json"

printf '%s\n' "Gonerino architecture checks passed"
