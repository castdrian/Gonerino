import base64
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUTPUT_PATH = ROOT / "assets" / "screenshots.svg"
SCREENSHOTS = (
    ("settings.png", "Custom settings"),
    ("long-form-menu.png", "Long-form controls"),
    ("shorts-menu.png", "Shorts controls"),
)


def encoded_image(path):
    return base64.b64encode(path.read_bytes()).decode("ascii")


def render():
    canvas_width = 1500
    canvas_height = 850
    body_width = 390
    body_height = 760
    body_y = 28
    screen_x_offset = 25
    screen_y_offset = 52
    screen_width = 340
    screen_height = 605
    positions = (35, 555, 1075)
    definitions = [
        '<linearGradient id="body" x1="0" y1="0" x2="1" y2="1">',
        '<stop offset="0" stop-color="#4b5059"/>',
        '<stop offset="0.12" stop-color="#20242b"/>',
        '<stop offset="0.5" stop-color="#0d0f13"/>',
        '<stop offset="0.88" stop-color="#22262d"/>',
        '<stop offset="1" stop-color="#525761"/>',
        '</linearGradient>',
        '<filter id="shadow" x="-30%" y="-20%" width="160%" height="155%">',
        '<feDropShadow dx="0" dy="18" stdDeviation="15" flood-color="#000000" flood-opacity="0.3"/>',
        '</filter>',
    ]
    for index, (_, _) in enumerate(SCREENSHOTS):
        x = positions[index]
        screen_x = x + screen_x_offset
        screen_y = body_y + screen_y_offset
        definitions.append(
            f'<clipPath id="screen-{index}"><rect x="{screen_x}" y="{screen_y}" width="{screen_width}" height="{screen_height}" rx="32"/></clipPath>'
        )
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{canvas_width}" height="{canvas_height}" viewBox="0 0 {canvas_width} {canvas_height}" role="img" aria-labelledby="title description">',
        '<title id="title">Gonerino screenshots</title>',
        '<desc id="description">Gonerino custom settings, long-form blocking actions, and Shorts blocking actions shown in transparent iPhone SE device frames.</desc>',
        "<defs>",
        *definitions,
        "</defs>",
    ]
    for index, (filename, label) in enumerate(SCREENSHOTS):
        x = positions[index]
        screen_x = x + screen_x_offset
        screen_y = body_y + screen_y_offset
        body_right = x + body_width
        side_button_x = x - 9
        parts.extend(
            [
                f'<g filter="url(#shadow)">',
                f'<rect x="{x}" y="{body_y}" width="{body_width}" height="{body_height}" rx="64" fill="url(#body)" stroke="#747a84" stroke-width="2"/>',
                f'<rect x="{x + 7}" y="{body_y + 7}" width="{body_width - 14}" height="{body_height - 14}" rx="58" fill="none" stroke="#050608" stroke-opacity="0.72" stroke-width="3"/>',
                f'<rect x="{screen_x - 2}" y="{screen_y - 2}" width="{screen_width + 4}" height="{screen_height + 4}" rx="35" fill="#050608" stroke="#6b7079" stroke-opacity="0.32" stroke-width="2"/>',
                f'<image x="{screen_x}" y="{screen_y}" width="{screen_width}" height="{screen_height}" preserveAspectRatio="xMidYMid slice" clip-path="url(#screen-{index})" href="data:image/png;base64,{encoded_image(ROOT / "assets" / filename)}"/>',
                f'<rect x="{screen_x}" y="{screen_y}" width="{screen_width}" height="{screen_height}" rx="32" fill="none" stroke="#000000" stroke-opacity="0.65" stroke-width="2"/>',
                f'<rect x="{x + 145}" y="{body_y + 20}" width="100" height="8" rx="4" fill="#050607"/>',
                f'<circle cx="{x + 265}" cy="{body_y + 24}" r="4" fill="#08090b" stroke="#676c75" stroke-opacity="0.35"/>',
                f'<rect x="{side_button_x}" y="{body_y + 136}" width="9" height="34" rx="4" fill="#20242a" stroke="#626872" stroke-width="1"/>',
                f'<rect x="{side_button_x}" y="{body_y + 188}" width="9" height="64" rx="4" fill="#20242a" stroke="#626872" stroke-width="1"/>',
                f'<rect x="{side_button_x}" y="{body_y + 266}" width="9" height="64" rx="4" fill="#20242a" stroke="#626872" stroke-width="1"/>',
                f'<rect x="{body_right}" y="{body_y + 190}" width="9" height="92" rx="4" fill="#20242a" stroke="#626872" stroke-width="1"/>',
                f'<circle cx="{x + body_width / 2}" cy="{body_y + 696}" r="31" fill="#090b0e" stroke="#666c76" stroke-width="2"/>',
                f'<circle cx="{x + body_width / 2}" cy="{body_y + 696}" r="25" fill="none" stroke="#20242a" stroke-width="2"/>',
                "</g>",
                f'<text x="{x + body_width / 2}" y="827" text-anchor="middle" fill="#3f4753" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif" font-size="20" font-weight="600">{label}</text>',
            ]
        )
    parts.append("</svg>")
    return "\n".join(parts) + "\n"


OUTPUT_PATH.write_text(render())
