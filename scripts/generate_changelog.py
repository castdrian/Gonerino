import argparse
import datetime
import re
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CHANGELOG_PATH = ROOT / "CHANGELOG.md"
RELEASE_NOTES_PATH = ROOT / ".github" / "release-notes.md"
SECTION_PATTERN = re.compile(r"^## ([^\n]+)\n.*?(?=^## |\Z)", re.MULTILINE | re.DOTALL)
COMMIT_PATTERN = re.compile(r"^(?P<kind>[a-z]+)(?:\([^)]*\))?(?P<breaking>!)?:\s*(?P<subject>.+)$", re.IGNORECASE)
GROUPS = {
    "feat": "Features",
    "fix": "Fixes",
    "perf": "Performance",
    "refactor": "Refactoring",
    "docs": "Documentation",
    "test": "Tests",
    "build": "Build",
    "ci": "CI",
    "chore": "Maintenance",
    "style": "Style",
    "revert": "Reverts",
}


def command(*args):
    result = subprocess.run(args, cwd=ROOT, check=False, capture_output=True, text=True)
    return result.stdout.strip()


def previous_tag():
    return command("git", "describe", "--tags", "--abbrev=0")


def commits_since(tag):
    range_name = f"{tag}..HEAD" if tag else "HEAD"
    output = command("git", "log", "--no-merges", "--format=%h%x09%s", range_name)
    return [line.split("\t", 1) for line in output.splitlines() if "\t" in line]


def current_section(text, version):
    for match in SECTION_PATTERN.finditer(text):
        if match.group(1).split(" ", 1)[0] == version:
            return match.group(0).rstrip()
    return ""


def generated_section(version, commits):
    grouped = {}
    for short_hash, subject in commits:
        match = COMMIT_PATTERN.match(subject)
        if match:
            group = GROUPS.get(match.group("kind").lower(), "Other changes")
            entry = match.group("subject").strip()
            if match.group("breaking"):
                group = "Breaking changes"
        else:
            group = "Other changes"
            entry = subject.strip()
        grouped.setdefault(group, []).append(f"- {entry} ({short_hash})")

    lines = [f"## {version} - {datetime.date.today().isoformat()}", ""]
    for group in ["Breaking changes", "Features", "Fixes", "Performance", "Refactoring", "Documentation", "Tests", "Build", "CI", "Maintenance", "Style", "Reverts", "Other changes"]:
        entries = grouped.get(group)
        if not entries:
            continue
        lines.extend([f"### {group}", "", *entries, ""])
    if len(lines) == 2:
        lines.extend(["No conventional commits were found for this release.", ""])
    return "\n".join(lines).rstrip()


def update_changelog(version):
    previous = CHANGELOG_PATH.read_text() if CHANGELOG_PATH.exists() else "# Changelog\n"
    tag = previous_tag()
    commits = commits_since(tag)
    section = generated_section(version, commits) if commits else current_section(previous, version)
    if not section:
        section = generated_section(version, [])
    without_current = SECTION_PATTERN.sub(lambda match: "" if match.group(1).split(" ", 1)[0] == version else match.group(0), previous)
    history = without_current.replace("# Changelog", "", 1).strip()
    result = "# Changelog\n\n" + section
    if history:
        result += "\n\n" + history
    result += "\n"
    CHANGELOG_PATH.write_text(result)
    RELEASE_NOTES_PATH.write_text(section + "\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    args = parser.parse_args()
    update_changelog(args.version)


if __name__ == "__main__":
    main()
