import html
import json
import math
import textwrap
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = ROOT / ".github" / "compatibility.json"
OUTPUT_PATH = ROOT / ".github" / "compatibility.svg"

STATUS = {
    "verified": {"label": "Verified", "color": "#30d158", "fill": "#193325"},
    "partial": {"label": "Partial", "color": "#ffd60a", "fill": "#3a3217"},
    "untested": {"label": "Untested", "color": "#8e8e93", "fill": "#292a2e"},
    "unsupported": {"label": "Unsupported", "color": "#ff453a", "fill": "#3b1d20"},
}


def escape(value):
    return html.escape(str(value), quote=True)


def status_data(status):
    return STATUS.get(status, STATUS["untested"])


def render_legend_item(x, y, legend):
    status = status_data(legend.get("status"))
    label = escape(legend.get("label") or status["label"])
    description = textwrap.wrap(str(legend.get("description") or ""), width=25)[:2]
    parts = [
        f'<circle cx="{x + 7}" cy="{y + 8}" r="5" fill="{status["color"]}"/>',
        f'<text x="{x + 20}" y="{y + 13}" fill="#f5f5f7" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif" font-size="13" font-weight="600">{label}</text>',
    ]
    for index, line in enumerate(description):
        parts.append(
            f'<text x="{x}" y="{y + 34 + index * 16}" fill="#98989f" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif" font-size="11">{escape(line)}</text>'
        )
    return parts


def render(config):
    rows = config.get("rows", [])
    legend = config.get("legend", [])
    width = 1040
    margin = 40
    header_height = 76
    row_height = 78
    row_gap = 2
    legend_height = 112
    columns = 2
    column_gap = 36
    column_width = (width - margin * 2 - column_gap) // columns
    rows_per_column = max(math.ceil(len(rows) / columns), 1)
    rows_height = rows_per_column * row_height + max(rows_per_column - 1, 0) * row_gap
    height = margin + header_height + rows_height + 28 + legend_height + margin
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img" aria-labelledby="title description">',
        f'<title id="title">{escape(config.get("title") or "Compatibility")}</title>',
        f'<desc id="description">{escape(config.get("subtitle") or "")}</desc>',
        '<rect width="100%" height="100%" rx="26" fill="#121316" stroke="#2a2d33" stroke-width="2"/>',
        f'<text x="{margin}" y="{margin + 28}" fill="#f5f5f7" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif" font-size="22" font-weight="700">{escape(config.get("title") or "Compatibility")}</text>',
        f'<text x="{margin}" y="{margin + 52}" fill="#98989f" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif" font-size="13">{escape(config.get("subtitle") or "")}</text>',
    ]
    for index, row in enumerate(rows):
        column = index // rows_per_column
        row_index = index % rows_per_column
        x = margin + column * (column_width + column_gap)
        y = margin + header_height + row_index * (row_height + row_gap)
        status = status_data(row.get("status"))
        label = escape(row.get("label") or "")
        value = escape(row.get("value") or "Not specified")
        chip_label = escape(status["label"])
        parts.extend(
            [
                f'<line x1="{x}" y1="{y + row_height - 1}" x2="{x + column_width}" y2="{y + row_height - 1}" stroke="#2a2d33" stroke-width="1"/>',
                f'<circle cx="{x + 7}" cy="{y + 25}" r="5" fill="{status["color"]}"/>',
                f'<text x="{x + 24}" y="{y + 23}" fill="#f5f5f7" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif" font-size="15" font-weight="600">{label}</text>',
                f'<text x="{x + 24}" y="{y + 48}" fill="#98989f" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif" font-size="13">{value}</text>',
                f'<rect x="{x + column_width - 112}" y="{y + 10}" width="104" height="28" rx="14" fill="{status["fill"]}"/>',
                f'<text x="{x + column_width - 60}" y="{y + 28}" text-anchor="middle" fill="{status["color"]}" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif" font-size="11" font-weight="600">{chip_label}</text>',
            ]
        )
    legend_y = margin + header_height + rows_height + 28
    parts.append(
        f'<line x1="{margin}" y1="{legend_y - 14}" x2="{width - margin}" y2="{legend_y - 14}" stroke="#2a2d33" stroke-width="1"/>'
    )
    parts.append(
        f'<text x="{margin}" y="{legend_y + 10}" fill="#98989f" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif" font-size="11" font-weight="600" letter-spacing="1">STATUS</text>'
    )
    legend_width = (width - margin * 2) / max(len(legend), 1)
    for index, item in enumerate(legend):
        parts.extend(render_legend_item(margin + index * legend_width, legend_y + 28, item))
    parts.append("</svg>")
    return "\n".join(parts) + "\n"


def main():
    config = json.loads(CONFIG_PATH.read_text())
    OUTPUT_PATH.write_text(render(config))


if __name__ == "__main__":
    main()
