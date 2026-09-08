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
    canvas_height = 930
    body_width = 410
    body_height = 850
    body_y = 20
    screen_x_offset = 22
    screen_y_offset = 75
    screen_width = 366
    screen_height = 651
    positions = (25, 545, 1065)
    definitions = [
        '<linearGradient id="body" x1="0" y1="0" x2="1" y2="1">',
        '<stop offset="0" stop-color="#555b65"/>',
        '<stop offset="0.1" stop-color="#242932"/>',
        '<stop offset="0.5" stop-color="#0d0f13"/>',
        '<stop offset="0.9" stop-color="#252a32"/>',
        '<stop offset="1" stop-color="#626873"/>',
        '</linearGradient>',
        '<filter id="shadow" x="-25%" y="-15%" width="150%" height="145%">',
        '<feDropShadow dx="0" dy="14" stdDeviation="12" flood-color="#000000" flood-opacity="0.28"/>',
        '</filter>',
    ]
    for index, _ in enumerate(SCREENSHOTS):
        x = positions[index]
        screen_x = x + screen_x_offset
        screen_y = body_y + screen_y_offset
        definitions.append(
            f'<clipPath id="screen-{index}"><rect x="{screen_x}" y="{screen_y}" width="{screen_width}" height="{screen_height}" rx="18"/></clipPath>'
        )
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{canvas_width}" height="{canvas_height}" viewBox="0 0 {canvas_width} {canvas_height}" role="img" aria-labelledby="title description">',
        '<title id="title">Gonerino screenshots</title>',
        '<desc id="description">Gonerino custom settings, long-form blocking actions, and Shorts blocking actions shown in second-generation iPhone SE frames.</desc>',
        "<defs>",
        *definitions,
        "</defs>",
    ]
    for index, (filename, label) in enumerate(SCREENSHOTS):
        x = positions[index]
        screen_x = x + screen_x_offset
        screen_y = body_y + screen_y_offset
        body_right = x + body_width
        left_button_x = x - 7
        parts.extend(
            [
                '<g filter="url(#shadow)">',
                f'<rect x="{x}" y="{body_y}" width="{body_width}" height="{body_height}" rx="52" fill="url(#body)" stroke="#747a84" stroke-width="2"/>',
                f'<rect x="{x + 7}" y="{body_y + 7}" width="{body_width - 14}" height="{body_height - 14}" rx="46" fill="none" stroke="#050608" stroke-opacity="0.75" stroke-width="3"/>',
                f'<rect x="{screen_x - 2}" y="{screen_y - 2}" width="{screen_width + 4}" height="{screen_height + 4}" rx="20" fill="#050608" stroke="#6b7079" stroke-opacity="0.35" stroke-width="2"/>',
                f'<image x="{screen_x}" y="{screen_y}" width="{screen_width}" height="{screen_height}" preserveAspectRatio="none" clip-path="url(#screen-{index})" href="data:image/png;base64,{encoded_image(ROOT / "assets" / filename)}"/>',
                f'<rect x="{screen_x}" y="{screen_y}" width="{screen_width}" height="{screen_height}" rx="18" fill="none" stroke="#000000" stroke-opacity="0.55" stroke-width="2"/>',
                f'<rect x="{x + 162}" y="{body_y + 35}" width="86" height="8" rx="4" fill="#08090b"/>',
                f'<circle cx="{x + 273}" cy="{body_y + 39}" r="5" fill="#08090b" stroke="#696f78" stroke-opacity="0.4"/>',
                f'<circle cx="{x + 291}" cy="{body_y + 39}" r="2" fill="#30343b"/>',
                f'<rect x="{left_button_x}" y="{body_y + 150}" width="7" height="32" rx="3.5" fill="#20242a" stroke="#626872" stroke-width="1"/>',
                f'<rect x="{left_button_x}" y="{body_y + 205}" width="7" height="66" rx="3.5" fill="#20242a" stroke="#626872" stroke-width="1"/>',
                f'<rect x="{left_button_x}" y="{body_y + 286}" width="7" height="66" rx="3.5" fill="#20242a" stroke="#626872" stroke-width="1"/>',
                f'<rect x="{body_right}" y="{body_y + 214}" width="7" height="96" rx="3.5" fill="#20242a" stroke="#626872" stroke-width="1"/>',
                f'<circle cx="{x + body_width / 2}" cy="{body_y + 774}" r="34" fill="#090b0e" stroke="#666c76" stroke-width="2"/>',
                f'<circle cx="{x + body_width / 2}" cy="{body_y + 774}" r="27" fill="none" stroke="#20242a" stroke-width="2"/>',
                "</g>",
                f'<text x="{x + body_width / 2}" y="{body_y + body_height + 40}" text-anchor="middle" fill="#3f4753" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif" font-size="20" font-weight="600">{label}</text>',
            ]
        )
    parts.append("</svg>")
    return "\n".join(parts) + "\n"


OUTPUT_PATH.write_text(render())
