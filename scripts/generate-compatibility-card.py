import html
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = ROOT / ".github" / "compatibility.json"
OUTPUT_PATH = ROOT / ".github" / "compatibility.svg"

STATUS = {
    "verified": ("Verified", "#15803d", "#dcfce7"),
    "partial": ("Partial", "#a16207", "#fef9c3"),
    "untested": ("Not tested", "#475569", "#e2e8f0"),
    "unsupported": ("Unsupported", "#b91c1c", "#fee2e2"),
}


def escape(value):
    return html.escape(str(value), quote=True)


def render(config):
    rows = config["rows"]
    width = 1080
    column_width = 500
    row_height = 104
    row_gap = 10
    rows_per_column = (len(rows) + 1) // 2
    height = 52 + rows_per_column * row_height + max(rows_per_column - 1, 0) * row_gap + 52
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img" aria-labelledby="title description">',
        '<title id="title">Gonerino compatibility</title>',
        f'<desc id="description">{escape(config["subtitle"])}</desc>',
        f'<rect width="{width}" height="{height}" rx="28" fill="#0d1118" stroke="#293241" stroke-width="2"/>',
    ]
    for index, row in enumerate(rows):
        column = index // rows_per_column
        row_index = index % rows_per_column
        x = 26 + column * (column_width + 28)
        y = 26 + row_index * (row_height + row_gap)
        label = escape(row["label"])
        value = escape(row.get("value") or "Not specified")
        status_label, status_color, status_fill = STATUS.get(row["status"], STATUS["untested"])
        parts.extend([
            f'<rect x="{x}" y="{y}" width="{column_width}" height="{row_height}" rx="18" fill="#151b25" stroke="#222b39"/>',
            f'<rect x="{x}" y="{y}" width="5" height="{row_height}" rx="2.5" fill="{status_color}"/>',
            f'<text x="{x + 22}" y="{y + 31}" fill="#f8fafc" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif" font-size="19" font-weight="700">{label}</text>',
            f'<text x="{x + 22}" y="{y + 62}" fill="#aab5c5" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif" font-size="15">{value}</text>',
            f'<rect x="{x + column_width - 158}" y="{y + 22}" width="136" height="32" rx="16" fill="{status_fill}"/>',
            f'<circle cx="{x + column_width - 140}" cy="{y + 38}" r="5" fill="{status_color}"/>',
            f'<text x="{x + column_width - 128}" y="{y + 43}" fill="{status_color}" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif" font-size="13" font-weight="700">{status_label}</text>',
        ])
    parts.append("</svg>")
    return "\n".join(parts) + "\n"


def main():
    config = json.loads(CONFIG_PATH.read_text())
    OUTPUT_PATH.write_text(render(config))


if __name__ == "__main__":
    main()
