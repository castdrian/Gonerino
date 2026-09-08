#!/usr/bin/env python3

import json
import pathlib
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "tests" / "metadata-fixtures.json"

PATHS = {
    "long": [
        ("videoId",),
        ("videoID",),
        ("videoTitle",),
        ("title",),
        ("ownerDisplayName",),
        ("channelName",),
        ("channel",),
        ("element", "properties", "videoId"),
        ("element", "properties", "videoTitle"),
        ("element", "properties", "channelName"),
        ("element", "allProperties", "videoId"),
        ("element", "allProperties", "videoTitle"),
        ("element", "allProperties", "channelName"),
        ("renderer", "videoRenderer", "videoId"),
        ("renderer", "videoRenderer", "videoTitle"),
        ("renderer", "videoRenderer", "ownerDisplayName"),
    ],
    "elements": [
        ("contentVideoId",),
        ("videoId",),
        ("contentTitle",),
        ("videoTitle",),
        ("ownerDisplayName",),
        ("channelName",),
        ("element", "properties", "contentVideoId"),
        ("element", "properties", "contentTitle"),
        ("element", "properties", "ownerDisplayName"),
        ("element", "allProperties", "contentVideoId"),
        ("element", "allProperties", "contentTitle"),
        ("element", "allProperties", "ownerDisplayName"),
    ],
    "shorts": [
        ("videoId",),
        ("videoID",),
        ("title",),
        ("videoTitle",),
        ("channel",),
        ("channelName",),
        ("ownerDisplayName",),
        ("currentVideo", "videoId"),
        ("currentVideo", "videoTitle"),
        ("currentVideo", "title"),
        ("currentVideo", "channel"),
        ("currentVideo", "channelName"),
    ],
}


def value_at(node, path):
    value = node
    for key in path:
        if not isinstance(value, dict):
            return ""
        value = value.get(key, "")
    return value if isinstance(value, str) else ""


def is_synthetic_channel(value):
    return value.strip().lower() in {"action menu", "more actions"}


def renderer_kind(renderer):
    name = renderer.lower()
    if "elm" in name or "element" in name:
        return "elements"
    if "short" in name or "reel" in name:
        return "shorts"
    if "ytvideo" in name:
        return "long"
    return None


def extract(fixture):
    kind = renderer_kind(fixture["rendererClass"])
    if kind is None:
        return {}
    result = {}
    for path in PATHS[kind]:
        value = value_at(fixture["node"], path)
        if not value:
            continue
        key = path[-1].lower()
        if "id" in key and "id" not in result:
            result["id"] = value
        elif ("title" in key or key == "name") and "title" not in result:
            result["title"] = value
        elif any(token in key for token in ("channel", "owner")) and "channel" not in result:
            if not is_synthetic_channel(value):
                result["channel"] = value
    return result


def blocked(metadata, video_ids=(), channels=(), words=()):
    if metadata.get("id") in video_ids:
        return True
    channel = metadata.get("channel", "").casefold()
    title = metadata.get("title", "").casefold()
    return channel in {value.casefold() for value in channels} or any(value.casefold() in title for value in words)


def verify_snapshot(fixtures):
    known = [fixture for fixture in fixtures if fixture.get("expected")]
    if len(known) < 4:
        return ["snapshot contract needs at least four known renderer fixtures"]

    failures = []
    blocked_ids = {known[0]["expected"]["id"]}
    blocked_channels = {known[1]["expected"]["channel"]}
    blocked_words = {"elements"}
    visible = []
    for source_index, fixture in enumerate(fixtures):
        metadata = extract(fixture)
        if not blocked(metadata, blocked_ids, blocked_channels, blocked_words):
            visible.append(source_index)
    expected_visible = [index for index, fixture in enumerate(fixtures)
                        if index not in (0, 1, 3)]
    if visible != expected_visible:
        failures.append(f"snapshot mapping expected {expected_visible!r}, got {visible!r}")
    if set(visible).intersection({0, 1, 3}):
        failures.append("blocked source item remained in the visible mapping")
    return failures


def main():
    fixtures = json.loads(FIXTURES.read_text())
    failures = []
    for fixture in fixtures:
        expected = fixture.get("expected", {})
        actual = extract(fixture)
        if actual != expected:
            failures.append(f'{fixture["name"]}: expected {expected!r}, got {actual!r}')
        if renderer_kind(fixture["rendererClass"]) is None and not fixture.get("expectedVisible"):
            failures.append(f'{fixture["name"]}: unknown renderer must remain visible')
    failures.extend(verify_snapshot(fixtures))
    if failures:
        for failure in failures:
            print(failure, file=sys.stderr)
        return 1
    print(f"metadata fixture checks passed ({len(fixtures)} fixtures)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
