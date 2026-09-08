#!/bin/sh
set -eu

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

if rg -n "layoutSubviews|didMoveToWindow|scheduleFiltering|FilterVisible|GapCollapse|filterScheduled|lastFilterTime|MetadataNodeForView|CollectTextNodeValues|CollectElementTreeMetadata|CollectObject|VideoNodeFromView|ActionMetadataNodeFromObject|VisibleFeedCellForVideoID|AsyncCollectionViewInView|deleteItemsAtIndexPaths|scrollToItemAtIndexPath|setContentOffset|reelContentViewRequestsAdvanceToNextVideo|%hook YTInlinePlaybackPlayerNode|%hook YTElementsInlineMutedPlaybackView|setAsdPlayableEntry:" "$repo_dir/sources/Util.m" "$repo_dir/sources/Tweak.x" "$repo_dir/sources/FeedDataSourceAdapter.m"; then
    printf '%s\n' "legacy UI-driven filtering symbols are still present" >&2
    exit 1
fi

if rg -n "subviews|accessibilityElements" "$repo_dir/sources/Util.m"; then
    printf '%s\n' "recursive UI-tree metadata extraction is still present" >&2
    exit 1
fi

if awk '
    /- \(NSMutableArray \*\)buttons \{/ { in_buttons = 1 }
    /- \(NSMutableArray \*\)visibleButtons \{/ { in_visible_buttons = 1 }
    (in_buttons || in_visible_buttons) && /addSubview:owner\.actionButton/ { bad = 1 }
    in_buttons && /^\}/ { in_buttons = 0 }
    in_visible_buttons && /^\}/ { in_visible_buttons = 0 }
    END { exit bad ? 0 : 1 }
' "$repo_dir/sources/Tweak.x"; then
    printf '%s\n' "navigation button is still reattached from an array accessor" >&2
    exit 1
fi

if awk '
    /%hook YTAsyncCollectionView/ { in_async_collection = 1 }
    in_async_collection && /- \(void\)setAsyncDataSource:/ { has_setter = 1 }
    in_async_collection && /- \(/ && !/- \(void\)setAsyncDataSource:/ { bad = 1 }
    in_async_collection && /^%end/ { exit bad || !has_setter ? 0 : 1 }
    END { exit bad || !has_setter ? 0 : 1 }
' "$repo_dir/sources/Tweak.x"; then
    printf '%s\n' "async data-source subclass hook includes unsupported selectors" >&2
    exit 1
fi

if awk '
    /- \(NSMutableArray \*\)buttons \{/ { in_buttons = 1 }
    /- \(NSMutableArray \*\)visibleButtons \{/ { in_visible_buttons = 1 }
    in_buttons && /UpdateNavigationButton\(self\)/ { bad = 1 }
    in_visible_buttons && /UpdateNavigationButton\(self\)/ { bad = 1 }
    in_buttons && /^\}/ { in_buttons = 0 }
    in_visible_buttons && /^\}/ { in_visible_buttons = 0 }
    END { exit bad ? 0 : 1 }
' "$repo_dir/sources/Tweak.x"; then
    printf '%s\n' "navigation button state is still mutated from its array accessors" >&2
    exit 1
fi

if rg -n "(^|[^A-Za-z0-9_])(QueueShortsContentMetadata|ShortsMetadataForContentView|ShortsMetadataCaptureStateKey)([^A-Za-z0-9_]|$)" "$repo_dir/sources/Tweak.x"; then
    printf '%s\n' "repeated Shorts lifecycle metadata capture is still present" >&2
    exit 1
fi

if rg -n "SettingsCategoryPending|CurrentSettingsManager|YTCollectionViewController|setTitle:" "$repo_dir/sources/Settings.x" "$repo_dir/headers/Settings.h"; then
    printf '%s\n' "legacy settings lifecycle or title redirect state is still present" >&2
    exit 1
fi

rg -q "FeedMetadataRecord" "$repo_dir/headers/Util.h"
rg -q "AdaptLongFormVideoNode" "$repo_dir/sources/Util.m"
rg -q "AdaptElementsFeedNode" "$repo_dir/sources/Util.m"
rg -q "AdaptShortsNode" "$repo_dir/sources/Util.m"
rg -q "setAsyncDataSource" "$repo_dir/sources/Tweak.x"
rg -q "presentFromView" "$repo_dir/sources/Tweak.x"
rg -q "shouldDismissOnAction = YES" "$repo_dir/sources/Tweak.x"
rg -q "nodeForItemAtIndexPath" "$repo_dir/sources/FeedDataSourceAdapter.m"
rg -q "sourceItemsBySection" "$repo_dir/sources/FeedDataSourceAdapter.m"
rg -q "EmptyFeedNode" "$repo_dir/sources/FeedDataSourceAdapter.m"
rg -q "calculateSizeThatFits" "$repo_dir/sources/FeedDataSourceAdapter.m"
rg -q 'FeedEmptyCellNode' "$repo_dir/sources/FeedDataSourceAdapter.m"
if awk '
    /- \(FeedMetadataRecord \*\)metadataForNode:/ { in_metadata_lookup = 1 }
    in_metadata_lookup && /SourcePathForRelatedNode/ { bad = 1 }
    in_metadata_lookup && /^\}/ { exit bad ? 0 : 1 }
    END { exit bad ? 0 : 1 }
' "$repo_dir/sources/FeedDataSourceAdapter.m"; then
    printf '%s\n' "normal feed metadata lookup still walks related objects" >&2
    exit 1
fi
if rg -n "return \[self snapshotForCountRequest\];" "$repo_dir/sources/FeedDataSourceAdapter.m"; then
    printf '%s\n' "snapshot construction still has unbounded recursive retry" >&2
    exit 1
fi
rg -q "snapshotForCountRequestWithRetryCount" "$repo_dir/sources/FeedDataSourceAdapter.m"
if awk '
    /- \(FeedCollectionSnapshot \*\)snapshotForCountRequestWithRetryCount:.*\{/ { in_snapshot = 1 }
    in_snapshot && /sourceIdentifierAtIndexPath|sourceModelAtIndexPath/ { bad = 1 }
    in_snapshot && /^\}/ { exit bad ? 0 : 1 }
    END { exit bad ? 0 : 1 }
' "$repo_dir/sources/FeedDataSourceAdapter.m"; then
    printf '%s\n' "snapshot construction still queries per-item upstream metadata" >&2
    exit 1
fi
rg -q "pushViewController" "$repo_dir/sources/Settings.x"
rg -q "expectedCategory" "$repo_dir/sources/Settings.x"
rg -q "SettingsNavigationTransactionKey" "$repo_dir/sources/Settings.x"
rg -q "FeedFilterStateDidChangeNotification" "$repo_dir/sources/Tweak.x" "$repo_dir/sources/CustomSettings.m" "$repo_dir/sources/Util.m"
rg -q 'long-form' "$repo_dir/scripts/gonerino-performance.sh"
rg -q '00008030-001624583AF9402E' "$repo_dir/scripts/gonerino-performance-suite.sh"
rg -q '"rendererClass": "YTVideoNode"' "$repo_dir/tests/metadata-fixtures.json"
rg -q '"rendererClass": "YTVideoWithContextNode"' "$repo_dir/tests/metadata-fixtures.json"
rg -q '"rendererClass": "ELMCellNode"' "$repo_dir/tests/metadata-fixtures.json"
rg -q '"rendererClass": "YTShortsVideoNode"' "$repo_dir/tests/metadata-fixtures.json"
rg -q '"expectedVisible": true' "$repo_dir/tests/metadata-fixtures.json"
test -x "$repo_dir/scripts/test-metadata-fixtures.py"
test -x "$repo_dir/scripts/analyze-gonerino-performance.py"
test -x "$repo_dir/scripts/test-feed-data-source-adapter-simulator.sh"
test -x "$repo_dir/scripts/gonerino-blocklist-backup.sh"
test -x "$repo_dir/scripts/gonerino-blocklist-restore.sh"
test -x "$repo_dir/scripts/merge-gonerino-blocklists.py"
test -x "$repo_dir/scripts/test-blocklist-restore.py"
"$repo_dir/scripts/test-metadata-fixtures.py" >/dev/null
"$repo_dir/scripts/test-blocklist-restore.py" >/dev/null
rg -q 'collect_process_metrics "sample-' "$repo_dir/scripts/gonerino-performance.sh"
rg -q 'analyze-gonerino-performance.py' "$repo_dir/scripts/gonerino-performance-suite.sh"
rg -q 'GonerinoBlockedChannels' "$repo_dir/scripts/gonerino-blocklist-backup.sh"
rg -q 'GonerinoBlockedVideos' "$repo_dir/scripts/gonerino-blocklist-backup.sh"
rg -q 'GonerinoBlockedWords' "$repo_dir/scripts/gonerino-blocklist-backup.sh"
rg -q 'GonerinoBlockedChannels' "$repo_dir/scripts/merge-gonerino-blocklists.py"
rg -q 'GonerinoBlockedVideos' "$repo_dir/scripts/merge-gonerino-blocklists.py"
rg -q 'GonerinoBlockedWords' "$repo_dir/scripts/merge-gonerino-blocklists.py"
rg -q 'merge-gonerino-blocklists\.py' "$repo_dir/scripts/gonerino-blocklist-restore.sh"

printf '%s\n' "Gonerino architecture checks passed"
