"""Generate Folio Android icon resources from assets/app_icon/folio.svg.

Run with Python 3 and Pillow: python tools/generate_launcher_icon.py
The SVG intentionally uses only solid polygons so Android vectors and PNGs
share exact geometry without an SVG rendering dependency.
"""

from __future__ import annotations

import math
from pathlib import Path
import xml.etree.ElementTree as ET

from PIL import Image, ImageDraw, ImageFont, PngImagePlugin


ROOT = Path(__file__).resolve().parents[1]
ASSET_DIR = ROOT / "assets" / "app_icon"
RES = ROOT / "android" / "app" / "src" / "main" / "res"
SVG_NS = {"svg": "http://www.w3.org/2000/svg"}
ANDROID_NS = "http://schemas.android.com/apk/res/android"
DENSITIES = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}


def write_resource(relative_path: str, content: str) -> None:
    destination = RES / relative_path
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(content, encoding="utf-8", newline="\n")


def main() -> None:
    source = ET.parse(ASSET_DIR / "folio.svg").getroot()
    background = source.find("svg:rect", SVG_NS).attrib["fill"]
    polygons = [
        (
            element.attrib["fill"],
            [tuple(map(float, pair.split(","))) for pair in element.attrib["points"].split()],
        )
        for element in source.findall("svg:polygon", SVG_NS)
    ]
    if not polygons:
        raise ValueError("The source must contain the Folio mark polygons")
    for _, points in polygons:
        if any(math.hypot(x - 54, y - 54) > 33 for x, y in points):
            raise ValueError("Mark extends beyond the adaptive icon safe circle")

    for name, monochrome in (("foreground", False), ("monochrome", True)):
        paths = []
        for color, points in polygons:
            path = "M" + " L".join(f"{x:g},{y:g}" for x, y in points) + " Z"
            paths.append(
                f'    <path android:fillColor="{"#FFFFFF" if monochrome else color}" '
                f'android:pathData="{path}" />'
            )
        write_resource(
            f"drawable/ic_launcher_{name}.xml",
            '<?xml version="1.0" encoding="utf-8"?>\n'
            f'<vector xmlns:android="{ANDROID_NS}" android:width="108dp" '
            'android:height="108dp" android:viewportWidth="108" android:viewportHeight="108">\n'
            + "\n".join(paths) + "\n</vector>\n",
        )
    write_resource(
        "drawable/ic_launcher_background.xml",
        '<?xml version="1.0" encoding="utf-8"?>\n'
        f'<shape xmlns:android="{ANDROID_NS}" android:shape="rectangle">\n'
        f'    <solid android:color="{background}" />\n</shape>\n',
    )
    for version in (26, 33):
        monochrome_line = (
            '    <monochrome android:drawable="@drawable/ic_launcher_monochrome" />\n'
            if version == 33 else ""
        )
        write_resource(
            f"mipmap-anydpi-v{version}/ic_launcher.xml",
            '<?xml version="1.0" encoding="utf-8"?>\n'
            f'<adaptive-icon xmlns:android="{ANDROID_NS}">\n'
            '    <background android:drawable="@drawable/ic_launcher_background" />\n'
            '    <foreground android:drawable="@drawable/ic_launcher_foreground" />\n'
            + monochrome_line + "</adaptive-icon>\n",
        )

    def render(size: int, mask: str = "rounded", themed: bool = False) -> Image.Image:
        # Android displays the inner 72 dp of the 108 dp adaptive canvas.
        # Match that apparent scale in legacy PNGs and the mask preview.
        scale = size * 4 / 72
        high_size = size * 4
        image = Image.new("RGBA", (high_size, high_size), "#DCE3EC" if themed else background)
        draw = ImageDraw.Draw(image)
        for color, points in polygons:
            draw.polygon(
                [((x - 18) * scale, (y - 18) * scale) for x, y in points],
                fill="#253244" if themed else color,
            )
        alpha = Image.new("L", image.size, 0)
        mask_draw = ImageDraw.Draw(alpha)
        bounds = (0, 0, high_size - 1, high_size - 1)
        if mask == "circle":
            mask_draw.ellipse(bounds, fill=255)
        else:
            mask_draw.rounded_rectangle(bounds, radius=high_size * 0.225, fill=255)
        image.putalpha(alpha)
        return image.resize((size, size), Image.Resampling.LANCZOS)

    metadata = PngImagePlugin.PngInfo()
    metadata.add_text("Source", "Original geometric artwork: assets/app_icon/folio.svg")
    metadata.add_text("Generator", "tools/generate_launcher_icon.py; 4x supersampling")
    for density, size in DENSITIES.items():
        destination = RES / f"mipmap-{density}" / "ic_launcher.png"
        destination.parent.mkdir(parents=True, exist_ok=True)
        render(size).save(destination, pnginfo=metadata)
    render(512).save(ASSET_DIR / "folio.png", pnginfo=metadata)

    preview = Image.new("RGB", (1000, 500), "#181B21")
    draw = ImageDraw.Draw(preview)
    font_path = str(ROOT / "assets" / "fonts" / "Inter.ttf")
    title = ImageFont.truetype(font_path, 30)
    caption = ImageFont.truetype(font_path, 17)
    draw.text((40, 30), "Folio", fill="#F4F3EF", font=title)
    for index, (label, mask, themed) in enumerate([
        ("Adaptive · rounded", "rounded", False),
        ("Adaptive · circle", "circle", False),
        ("Monochrome · themed", "circle", True),
    ]):
        x = 40 + index * 328
        icon = render(220, mask, themed)
        preview.paste(icon, (x, 100), icon)
        draw.text((x, 340), label, fill="#CBD2DB", font=caption)
        small_icon = render(48, mask, themed)
        preview.paste(small_icon, (x, 397), small_icon)
        draw.text((x + 62, 411), "48 px", fill="#9DA9B8", font=caption)
    preview.save(ASSET_DIR / "preview.png", pnginfo=metadata)
    print("Generated five density PNGs, adaptive/monochrome vectors, and icon previews.")


if __name__ == "__main__":
    main()
