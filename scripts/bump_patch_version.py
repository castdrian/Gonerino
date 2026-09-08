import re
from pathlib import Path


root = Path(__file__).resolve().parents[1]
control_path = root / "control"
control = control_path.read_text(encoding="utf-8")
match = re.search(r"(?m)^Version:\s*(\d+)\.(\d+)\.(\d+)\s*$", control)

if match is None:
    raise SystemExit("control does not contain a semantic version")

major, minor, patch = (int(value) for value in match.groups())
next_version = f"{major}.{minor}.{patch + 1}"
updated_control = control[:match.start(1)] + next_version + control[match.end(1):]
control_path.write_text(updated_control, encoding="utf-8")
print(next_version)
