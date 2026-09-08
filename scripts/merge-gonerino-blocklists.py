#!/usr/bin/env python3

import json
import pathlib
import plistlib
import sys


KEYS = ["GonerinoBlockedChannels", "GonerinoBlockedVideos", "GonerinoBlockedWords"]


def main():
    if len(sys.argv) != 4:
        print("usage: merge-gonerino-blocklists.py CURRENT_PLIST BACKUP_JSON OUTPUT_PLIST", file=sys.stderr)
        return 2

    current = pathlib.Path(sys.argv[1])
    backup = pathlib.Path(sys.argv[2])
    output = pathlib.Path(sys.argv[3])
    values = plistlib.loads(current.read_bytes())
    block_lists = json.loads(backup.read_text())
    for key in KEYS:
        value = block_lists.get(key)
        if not isinstance(value, list):
            raise SystemExit(f"backup value for {key} is not an array")
        values[key] = value
    output.write_bytes(plistlib.dumps(values, fmt=plistlib.FMT_BINARY, sort_keys=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
