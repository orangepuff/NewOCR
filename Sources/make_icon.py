from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter


APP_DIR = Path(__file__).resolve().parents[1]
ASSET_DIR = APP_DIR / "Assets"
ICONSET_DIR = ASSET_DIR / "NewOCR.iconset"


def rounded_rect_mask(size, radius):
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle((0, 0, size, size), radius=radius, fill=255)
    return mask


def gradient(size, top, bottom):
    image = Image.new("RGBA", (size, size))
    pix = image.load()
    for y in range(size):
        t = y / max(1, size - 1)
        row = tuple(int(top[i] * (1 - t) + bottom[i] * t) for i in range(4))
        for x in range(size):
            pix[x, y] = row
    return image


def draw_icon(size=1024):
    scale = size / 1024

    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    mask = rounded_rect_mask(size, int(224 * scale))

    base = gradient(size, (47, 151, 255, 255), (8, 92, 183, 255))
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse(
        (int(80 * scale), int(-120 * scale), int(1040 * scale), int(650 * scale)),
        fill=(108, 238, 255, 88),
    )
    gd.ellipse(
        (int(-150 * scale), int(430 * scale), int(760 * scale), int(1210 * scale)),
        fill=(29, 213, 187, 74),
    )
    glow = glow.filter(ImageFilter.GaussianBlur(int(36 * scale)))
    base = Image.alpha_composite(base, glow)
    base.putalpha(mask)

    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle(
        (int(64 * scale), int(78 * scale), int(960 * scale), int(980 * scale)),
        radius=int(210 * scale),
        fill=(0, 35, 90, 130),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(int(22 * scale)))
    shadow.putalpha(Image.composite(shadow.getchannel("A"), Image.new("L", (size, size), 0), mask))

    canvas = Image.alpha_composite(canvas, shadow)
    canvas = Image.alpha_composite(canvas, base)

    draw = ImageDraw.Draw(canvas)

    # Document shadow
    doc_shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    dsd = ImageDraw.Draw(doc_shadow)
    doc_box = (
        int(258 * scale),
        int(166 * scale),
        int(770 * scale),
        int(854 * scale),
    )
    dsd.rounded_rectangle(doc_box, radius=int(44 * scale), fill=(0, 32, 82, 120))
    doc_shadow = doc_shadow.filter(ImageFilter.GaussianBlur(int(28 * scale)))
    canvas = Image.alpha_composite(canvas, doc_shadow)
    draw = ImageDraw.Draw(canvas)

    # Main PDF page
    draw.rounded_rectangle(doc_box, radius=int(44 * scale), fill=(249, 253, 255, 255))
    draw.rounded_rectangle(
        (
            int(282 * scale),
            int(188 * scale),
            int(746 * scale),
            int(830 * scale),
        ),
        radius=int(28 * scale),
        outline=(208, 231, 250, 255),
        width=max(2, int(4 * scale)),
    )

    # Folded corner
    fold = [
        (int(653 * scale), int(166 * scale)),
        (int(770 * scale), int(283 * scale)),
        (int(652 * scale), int(283 * scale)),
    ]
    draw.polygon(fold, fill=(217, 239, 255, 255))
    draw.line(
        (
            (int(652 * scale), int(168 * scale)),
            (int(652 * scale), int(283 * scale)),
            (int(767 * scale), int(283 * scale)),
        ),
        fill=(180, 219, 247, 255),
        width=max(2, int(5 * scale)),
    )

    # OCR text bars
    for y, width, alpha in [
        (368, 308, 235),
        (431, 382, 220),
        (494, 330, 205),
        (618, 370, 195),
        (681, 286, 185),
    ]:
        draw.rounded_rectangle(
            (
                int(332 * scale),
                int(y * scale),
                int((332 + width) * scale),
                int((y + 24) * scale),
            ),
            radius=int(12 * scale),
            fill=(118, 156, 188, alpha),
        )

    # Scan beam and bright center line
    beam = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    bd = ImageDraw.Draw(beam)
    bd.rounded_rectangle(
        (
            int(295 * scale),
            int(544 * scale),
            int(735 * scale),
            int(604 * scale),
        ),
        radius=int(30 * scale),
        fill=(27, 221, 198, 82),
    )
    beam = beam.filter(ImageFilter.GaussianBlur(int(8 * scale)))
    canvas = Image.alpha_composite(canvas, beam)
    draw = ImageDraw.Draw(canvas)
    draw.rounded_rectangle(
        (
            int(301 * scale),
            int(566 * scale),
            int(728 * scale),
            int(581 * scale),
        ),
        radius=int(7 * scale),
        fill=(21, 218, 198, 255),
    )
    draw.rounded_rectangle(
        (
            int(301 * scale),
            int(562 * scale),
            int(728 * scale),
            int(566 * scale),
        ),
        radius=int(2 * scale),
        fill=(217, 255, 250, 230),
    )

    # OCR focus sparkle
    cx, cy = int(706 * scale), int(625 * scale)
    draw.ellipse(
        (
            cx - int(38 * scale),
            cy - int(38 * scale),
            cx + int(38 * scale),
            cy + int(38 * scale),
        ),
        outline=(16, 180, 205, 255),
        width=max(3, int(9 * scale)),
    )
    draw.line(
        (
            cx + int(30 * scale),
            cy + int(30 * scale),
            cx + int(91 * scale),
            cy + int(91 * scale),
        ),
        fill=(16, 180, 205, 255),
        width=max(4, int(14 * scale)),
    )
    draw.line(
        (
            int(360 * scale),
            int(284 * scale),
            int(360 * scale),
            int(324 * scale),
        ),
        fill=(255, 255, 255, 230),
        width=max(2, int(6 * scale)),
    )
    draw.line(
        (
            int(340 * scale),
            int(304 * scale),
            int(380 * scale),
            int(304 * scale),
        ),
        fill=(255, 255, 255, 230),
        width=max(2, int(6 * scale)),
    )

    return canvas


def save_iconset():
    ICONSET_DIR.mkdir(parents=True, exist_ok=True)
    source = draw_icon(1024)

    sizes = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]

    for filename, px in sizes:
        resized = source.resize((px, px), Image.Resampling.LANCZOS)
        resized.save(ICONSET_DIR / filename)

    source.save(ASSET_DIR / "NewOCR-icon-preview.png")


if __name__ == "__main__":
    save_iconset()
