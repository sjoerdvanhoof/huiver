"""Derive the Narcisse app icons from design/narcisse-app-icon.png.

The design master is a rounded-rect card with white margins baked in. This
script crops it to a full-bleed square for iOS (the system applies its own
corner mask), paints the card's own white corner notches with the adjacent
background so no white can ever peek through a mask, and composes the macOS
set on Apple's inset rounded-rect plate with a transparent margin.

Run via the repo venv:  bun run icons
"""

from pathlib import Path

from PIL import Image, ImageDraw

REPO = Path(__file__).resolve().parents[2]
SOURCE = REPO / "design/narcisse-app-icon.png"
IOS_SET = REPO / "apps/ios/Huiver/Assets.xcassets/AppIcon.appiconset"
MAC_SET = REPO / "apps/mac/Huiver/Assets.xcassets/AppIcon.appiconset"

EDGE_LUMINANCE = 200  # anything darker than this counts as card, not margin
RIM_INSET = 0.02      # fraction of card size cropped to clear its rim highlight
CARD_RADIUS = 175     # the card's own corner radius at 1024, slightly padded


def card_bounds(img: Image.Image) -> tuple[int, int, int, int]:
    """Locate the rounded card by scanning the midlines for non-white pixels."""
    gray = img.convert("L")
    px = gray.load()
    w, h = img.size

    def scan(vals: list[int]) -> tuple[int, int]:
        lo = next(i for i, v in enumerate(vals) if v < EDGE_LUMINANCE)
        hi = len(vals) - 1 - next(i for i, v in enumerate(reversed(vals)) if v < EDGE_LUMINANCE)
        return lo, hi

    left, right = scan([px[x, h // 2] for x in range(w)])
    top, bottom = scan([px[w // 2, y] for y in range(h)])
    return left, top, right, bottom


def full_bleed(img: Image.Image) -> Image.Image:
    """1024x1024 full-bleed square with the card's white corner notches filled."""
    left, top, right, bottom = card_bounds(img)
    inset = round((right - left) * RIM_INSET)
    sq = img.crop((left + inset, top + inset, right - inset, bottom - inset))
    side = min(sq.size)
    sq = sq.crop(
        (
            (sq.width - side) // 2,
            (sq.height - side) // 2,
            (sq.width + side) // 2,
            (sq.height + side) // 2,
        )
    )
    out = sq.resize((1024, 1024), Image.LANCZOS)

    mask = Image.new("L", (1024, 1024), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, 1023, 1023], radius=CARD_RADIUS, fill=255)
    bg = Image.new("RGB", (1024, 1024))
    draw = ImageDraw.Draw(bg)
    for corner_x, corner_y, sample_x, sample_y in (
        (0, 0, 120, 120),
        (824, 0, 903, 120),
        (0, 824, 120, 903),
        (824, 824, 903, 903),
    ):
        draw.rectangle(
            [corner_x, corner_y, corner_x + 199, corner_y + 199],
            fill=out.getpixel((sample_x, sample_y)),
        )
    return Image.composite(out, bg, mask)


def mac_plate(icon: Image.Image) -> Image.Image:
    """macOS master: the icon on Apple's 824px rounded plate, margin transparent."""
    canvas = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    art = icon.resize((824, 824), Image.LANCZOS)
    mask = Image.new("L", (824, 824), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, 823, 823], radius=186, fill=255)
    canvas.paste(art, (100, 100), mask)
    return canvas


def main() -> None:
    IOS_SET.mkdir(parents=True, exist_ok=True)
    MAC_SET.mkdir(parents=True, exist_ok=True)

    icon = full_bleed(Image.open(SOURCE).convert("RGB"))
    icon.save(IOS_SET / "AppIcon.png")
    icon.save(IOS_SET / "AppIcon-dark.png")

    plate = mac_plate(icon)
    for size in (16, 32, 128, 256, 512):
        plate.resize((size, size), Image.LANCZOS).save(MAC_SET / f"icon_{size}.png")
        plate.resize((size * 2, size * 2), Image.LANCZOS).save(MAC_SET / f"icon_{size}@2x.png")

    print(f"wrote {IOS_SET}")
    print(f"wrote {MAC_SET}")


if __name__ == "__main__":
    main()
