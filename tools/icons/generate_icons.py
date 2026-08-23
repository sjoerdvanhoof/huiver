"""Render the Narcisse app icons straight into both asset catalogs.

The artwork is "Narcisse at the water": a flat gold bloom on a stem, mirrored
below a waterline as a faint squashed reflection with ripple gaps. Everything
is drawn at 4x (4096) and downscaled with Lanczos, so the shipped PNGs stay
crisp without any vector tooling.

Run via the repo venv:  bun run icons
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageOps

REPO = Path(__file__).resolve().parents[2]
IOS_SET = REPO / "apps/ios/Huiver/Assets.xcassets/AppIcon.appiconset"
MAC_SET = REPO / "apps/mac/Huiver/Assets.xcassets/AppIcon.appiconset"

S = 4  # supersample factor; all geometry below is at 1024 master scale

FIELD_ABOVE = (0x12, 0x24, 0x1F, 255)
FIELD_BELOW = (0x0B, 0x1A, 0x16, 255)
WATERLINE = (0x7F, 0xB0, 0xA0, int(255 * 0.28))
PETAL = (0xD9, 0xA4, 0x41, 255)
TRUMPET = (0xB8, 0x80, 0x2B, 255)
STEM = (0x3E, 0x6B, 0x5A, 255)

WATER_Y = 594
BLOOM = (512, 330)
REFLECTION_TOP = 600  # canvas y where the mirrored stem meets the water
SQUASH = 0.86
RIPPLES = (48, 118, 200)  # gaps in the reflection, offsets below the waterline


def artwork_layer(mouth_color: tuple[int, int, int, int]) -> Image.Image:
    """The bloom and stem on a transparent 1024x1024 layer (at 4x)."""
    layer = Image.new("RGBA", (1024 * S, 1024 * S), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)

    # Stem first, so the trumpet sits over its top end.
    draw.rounded_rectangle(
        [(512 - 10) * S, 392 * S, (512 + 10) * S, WATER_Y * S],
        radius=10 * S,
        fill=STEM,
    )

    # Six petals: one ellipse (200 long x 84 wide, inner end at radius 70)
    # rotated about the bloom center in 60-degree steps. Offset by 30 degrees
    # so no petal points straight down — the stem stays visible in the gap.
    petal = Image.new("RGBA", (1024 * S, 1024 * S), (0, 0, 0, 0))
    cx, cy = BLOOM
    ImageDraw.Draw(petal).ellipse(
        [(cx - 42) * S, (cy - 270) * S, (cx + 42) * S, (cy - 70) * S],
        fill=PETAL,
    )
    for k in range(6):
        layer.alpha_composite(
            petal.rotate(k * 60 + 30, center=(cx * S, cy * S), resample=Image.BICUBIC)
        )

    # Trumpet: deeper gold cup with the field showing through its mouth.
    draw = ImageDraw.Draw(layer)
    draw.ellipse([(cx - 62) * S, (cy - 62) * S, (cx + 62) * S, (cy + 62) * S], fill=TRUMPET)
    draw.ellipse([(cx - 26) * S, (cy - 26) * S, (cx + 26) * S, (cy + 26) * S], fill=mouth_color)

    return layer


def add_reflection(canvas: Image.Image, art: Image.Image) -> None:
    """Composite the mirrored, squashed, faded copy with ripple gaps."""
    squashed = ImageOps.flip(art).resize(
        (1024 * S, int(1024 * S * SQUASH)), Image.LANCZOS
    )
    squashed.putalpha(squashed.getchannel("A").point(lambda a: int(a * 0.34)))

    # The flipped stem bottom sits at (1024 - WATER_Y) * SQUASH inside the
    # squashed layer; place that point at REFLECTION_TOP on the canvas.
    paste_y = REFLECTION_TOP - round((1024 - WATER_Y) * SQUASH)

    erase = ImageDraw.Draw(squashed)
    for off in RIPPLES:
        top = (REFLECTION_TOP + off - paste_y) * S
        erase.rectangle([0, top, 1024 * S, top + 14 * S], fill=(0, 0, 0, 0))

    canvas.alpha_composite(squashed, (0, paste_y * S))


def compose_scene(transparent_field: bool) -> Image.Image:
    """Full 1024 master: field, waterline, reflection, bloom (at 4x)."""
    canvas = Image.new("RGBA", (1024 * S, 1024 * S), (0, 0, 0, 0))
    if not transparent_field:
        draw = ImageDraw.Draw(canvas)
        draw.rectangle([0, 0, 1024 * S, WATER_Y * S], fill=FIELD_ABOVE)
        draw.rectangle([0, WATER_Y * S, 1024 * S, 1024 * S], fill=FIELD_BELOW)

    line = Image.new("RGBA", (1024 * S, 1024 * S), (0, 0, 0, 0))
    ImageDraw.Draw(line).rectangle([0, 591 * S, 1024 * S, 597 * S], fill=WATERLINE)
    canvas.alpha_composite(line)

    mouth = (0, 0, 0, 0) if transparent_field else FIELD_ABOVE
    art = artwork_layer(mouth)
    add_reflection(canvas, art)
    canvas.alpha_composite(art)
    return canvas


def down(image: Image.Image, size: int) -> Image.Image:
    return image.resize((size, size), Image.LANCZOS)


def rounded_plate_master(scene: Image.Image) -> Image.Image:
    """macOS master: the scene on an inset rounded-rect plate, artwork x0.80."""
    scaled = scene.resize((round(1024 * S * 0.80),) * 2, Image.LANCZOS)
    offset = (1024 * S - scaled.width) // 2

    # Field behind the slightly-inset scene, split at the scaled waterline so
    # the sliver of plate showing around the scene matches the water tones.
    filled = Image.new("RGBA", (1024 * S, 1024 * S), FIELD_ABOVE)
    water_y = offset + round(WATER_Y * 0.80) * S
    ImageDraw.Draw(filled).rectangle([0, water_y, 1024 * S, 1024 * S], fill=FIELD_BELOW)
    filled.alpha_composite(scaled, (offset, offset))

    mask = Image.new("L", (1024 * S, 1024 * S), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [100 * S, 100 * S, 924 * S, 924 * S], radius=185 * S, fill=255
    )
    plate = Image.new("RGBA", (1024 * S, 1024 * S), (0, 0, 0, 0))
    plate.paste(filled, (0, 0), mask)
    return plate


def main() -> None:
    IOS_SET.mkdir(parents=True, exist_ok=True)
    MAC_SET.mkdir(parents=True, exist_ok=True)

    scene = compose_scene(transparent_field=False)
    down(scene, 1024).convert("RGB").save(IOS_SET / "AppIcon.png")

    dark = compose_scene(transparent_field=True)
    down(dark, 1024).save(IOS_SET / "AppIcon-dark.png")

    mac_master = rounded_plate_master(scene)
    for size in (16, 32, 128, 256, 512):
        down(mac_master, size).save(MAC_SET / f"icon_{size}.png")
        down(mac_master, size * 2).save(MAC_SET / f"icon_{size}@2x.png")

    print(f"wrote {IOS_SET}")
    print(f"wrote {MAC_SET}")


if __name__ == "__main__":
    main()
