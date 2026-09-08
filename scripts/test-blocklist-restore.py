#!/usr/bin/env python3

import json
import pathlib
import plistlib
import subprocess
import sys
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
MERGE = ROOT / "scripts" / "merge-gonerino-blocklists.py"
KEYS = ["GonerinoBlockedChannels", "GonerinoBlockedVideos", "GonerinoBlockedWords"]


def main():
    with tempfile.TemporaryDirectory() as temporary_directory:
        directory = pathlib.Path(temporary_directory)
        current = directory / "current.plist"
        backup = directory / "block-lists.json"
        restored = directory / "restored.plist"
        current_values = {
            "GonerinoBlockedChannels": ["old channel"],
            "GonerinoBlockedVideos": [{"id": "old"}],
            "GonerinoBlockedWords": ["old word"],
            "UnrelatedYouTubeSetting": {"enabled": True},
        }
        backup_values = {
            "GonerinoBlockedChannels": ["new channel"],
            "GonerinoBlockedVideos": [{"id": "new"}],
            "GonerinoBlockedWords": ["new word"],
        }
        current.write_bytes(plistlib.dumps(current_values, fmt=plistlib.FMT_BINARY, sort_keys=False))
        backup.write_text(json.dumps(backup_values))
        subprocess.run([sys.executable, str(MERGE), str(current), str(backup), str(restored)], check=True)
        restored_values = plistlib.loads(restored.read_bytes())
        for key in KEYS:
            if restored_values[key] != backup_values[key]:
                raise SystemExit(f"{key} was not restored")
        if restored_values["UnrelatedYouTubeSetting"] != current_values["UnrelatedYouTubeSetting"]:
            raise SystemExit("an unrelated YouTube preference changed")
    print("block-list restore checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
