"""Generate launcher icon variants from the adaptive layers in res/drawable-nodpi.

Run with Python 3 and Pillow: python tools/generate_launcher_icon.py
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, PngImagePlugin


ROOT = Path(__file__).resolve().parents[1]
ASSET_DIR = ROOT / "assets" / "app_icon"
RES = ROOT / "android" / "app" / "src" / "main" / "res"
ANDROID_NS = "http://schemas.android.com/apk/res/android"
DENSITIES = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}


def write_resource(relative_path: str, content: str) -> None:
    destination = RES / relative_path
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(content, encoding="utf-8", newline="\n")


def main() -> None:
    layers = RES / "drawable-nodpi"
    with (
        Image.open(layers / "ic_launcher_background.png") as background,
        Image.open(layers / "ic_launcher_foreground.png") as foreground,
        Image.open(layers / "ic_launcher_monochrome.png") as monochrome,
    ):
        color_icon = Image.alpha_composite(background.convert("RGBA"), foreground)
        themed_icon = Image.new("RGBA", color_icon.size, "#DCE3EC")
        themed_icon.paste("#253244", (0, 0, *themed_icon.size), monochrome.getchannel("A"))

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
        source = themed_icon if themed else color_icon
        margin = source.width // 6
        high_size = size * 4
        image = source.crop(
            (margin, margin, source.width - margin, source.height - margin),
        ).resize((high_size, high_size), Image.Resampling.LANCZOS)
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
    metadata.add_text("Source", "Folio adaptive launcher layers in res/drawable-nodpi")
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
    print("Generated five density PNGs, adaptive icon XML, and color and themed previews.")


if __name__ == "__main__":
    main()
