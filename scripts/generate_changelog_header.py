from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_PATH = ROOT / "CHANGELOG.md"
OUTPUT_PATH = ROOT / "headers" / "ChangelogData.h"


def escape(value):
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\r", "").replace("\n", "\\n")


def main():
    contents = SOURCE_PATH.read_text() if SOURCE_PATH.exists() else "# Changelog\n"
    OUTPUT_PATH.write_text(f'#define GONERINO_CHANGELOG @"{escape(contents)}"\n')


if __name__ == "__main__":
    main()
