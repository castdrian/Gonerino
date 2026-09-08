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
    width = 960
    row_height = 54
    header_height = 116
    footer_height = 44
    height = header_height + row_height * len(rows) + footer_height
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img" aria-labelledby="title description">',
        '<title id="title">Gonerino compatibility</title>',
        f'<desc id="description">{escape(config["subtitle"])}</desc>',
        '<rect width="960" height="%d" rx="22" fill="#f8fafc" stroke="#cbd5e1"/>' % height,
        '<rect width="960" height="116" rx="22" fill="#111827"/>',
        '<rect y="82" width="960" height="34" fill="#111827"/>',
        '<circle cx="54" cy="55" r="22" fill="#ef4444"/>',
        '<path d="M45 55h18M54 46v18" stroke="#fff" stroke-width="4" stroke-linecap="round"/>',
        f'<text x="92" y="53" fill="#fff" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif" font-size="27" font-weight="700">{escape(config["title"])}</text>',
        f'<text x="92" y="82" fill="#cbd5e1" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif" font-size="16">{escape(config["subtitle"])}</text>',
    ]
    for index, row in enumerate(rows):
        y = header_height + index * row_height
        fill = "#ffffff" if index % 2 == 0 else "#f1f5f9"
        label = escape(row["label"])
        value = escape(row.get("value", ""))
        status_label, status_color, status_fill = STATUS.get(row["status"], STATUS["untested"])
        parts.extend([
            f'<rect x="20" y="{y}" width="920" height="{row_height}" fill="{fill}"/>',
            f'<text x="48" y="{y + 34}" fill="#0f172a" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif" font-size="18" font-weight="600">{label}</text>',
            f'<text x="300" y="{y + 34}" fill="#334155" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif" font-size="17">{value}</text>',
            f'<rect x="794" y="{y + 12}" width="122" height="30" rx="15" fill="{status_fill}"/>',
            f'<circle cx="814" cy="{y + 27}" r="5" fill="{status_color}"/>',
            f'<text x="827" y="{y + 33}" fill="{status_color}" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif" font-size="14" font-weight="700">{status_label}</text>',
        ])
    footer_y = header_height + row_height * len(rows)
    parts.extend([
        f'<text x="48" y="{footer_y + 29}" fill="#64748b" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif" font-size="14">Updated automatically from .github/compatibility.json</text>',
        '</svg>',
    ])
    return "\n".join(parts) + "\n"


def main():
    config = json.loads(CONFIG_PATH.read_text())
    OUTPUT_PATH.write_text(render(config))


if __name__ == "__main__":
    main()
