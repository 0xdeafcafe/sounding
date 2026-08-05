#!/usr/bin/env python3
"""Generates desktop wallpapers in the SoundingTV palette.

Design: flowing aurora ribbons over a near-black field, warm SoundCloud orange
crossing a deep violet, in the same colour language as the app icon and the
pairing screen.

Two things matter for this not to look machine-generated:

  * Ribbons are built from summed sines rather than noise, so the bands are
    perfectly smooth and there are no lattice artifacts to catch the eye.
  * The float field is dithered immediately before quantising to 8-bit. Large
    smooth gradients band horribly otherwise, and banding is the single most
    obvious tell of a programmatic wallpaper.

The composition keeps the upper-left calm so the menu bar and desktop icons
stay legible, and puts the interest low and right.

Usage:  python3 tools/make_wallpaper.py [--preview]
"""

import argparse
import os

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUTDIR = os.path.join(ROOT, "Design", "Wallpapers")

# Matches Color.scAccent / the icon palette.
ACCENT = (255, 107, 26)
EMBER = (214, 58, 12)
VIOLET = (92, 58, 168)
INDIGO = (44, 30, 96)
ROSE = (196, 52, 82)

# (width, height, label) — the sizes worth shipping for current Macs.
TARGETS = [
    (6016, 3384, "6K"),
    (5120, 2880, "5K"),
    (3456, 2234, "MBP16"),
    (3024, 1964, "MBP14"),
    (2560, 1440, "QHD"),
]

# Ribbons, painted back to front. Each is drawn twice: a wide dim halo for
# bloom, then a thin bright core. Thin cores with genuine black between them is
# what separates an aurora from a sunset — the first pass at this used broad
# overlapping bands and they merged into one continuous wash.
#
# The violet group sits high and the warm group sits low, with an unlit gap
# between, so the two families never blend into mud.
#
#   colour, centre (0-1 of height), tilt across frame, wave amplitude,
#   core thickness, halo thickness, brightness, [(frequency, phase), ...]
RIBBONS = [
    (VIOLET, 0.20,  0.10, 0.045, 0.011, 0.085, 0.55, [(0.8, 0.4), (1.9, 2.1)]),
    (INDIGO, 0.32,  0.14, 0.055, 0.020, 0.130, 0.50, [(0.9, 1.2), (2.2, 4.0)]),
    (EMBER,  0.63, -0.10, 0.050, 0.016, 0.115, 0.75, [(0.8, 3.1), (2.0, 0.6)]),
    (ACCENT, 0.73, -0.13, 0.042, 0.010, 0.075, 1.00, [(1.1, 2.4), (2.5, 5.0)]),
    (ROSE,   0.68, -0.11, 0.038, 0.007, 0.045, 0.45, [(1.3, 0.9), (2.9, 3.3)]),
    (ACCENT, 0.84, -0.07, 0.030, 0.006, 0.048, 0.65, [(1.7, 4.4), (3.4, 1.1)]),
]


def field(w, h):
    """Compose the colour field in normalised coordinates, float32 RGB 0-1."""
    x = np.linspace(0.0, 1.0, w, dtype=np.float32)[None, :]
    y = np.linspace(0.0, 1.0, h, dtype=np.float32)[:, None]

    # Base: near-black, cooling very slightly toward the bottom.
    rgb = np.zeros((h, w, 3), dtype=np.float32)
    rgb[..., 0] = 0.020 + 0.010 * y
    rgb[..., 1] = 0.020 + 0.008 * y
    rgb[..., 2] = 0.033 + 0.022 * y

    def add(colour, mask, strength):
        col = np.asarray(colour, dtype=np.float32) / 255.0
        m = (mask * strength)[..., None]
        # Screen blend — keeps highlights from clipping to flat colour.
        np.add(rgb, (1.0 - rgb) * col * m, out=rgb)

    # Ribbons fade toward the left so the menu bar and the icon column stay
    # over near-black and remain legible.
    envelope = np.clip((x - 0.02) / 0.55, 0.0, 1.0).astype(np.float32) ** 0.9
    envelope = 0.10 + 0.90 * envelope

    for colour, base, tilt, amp, core_t, halo_t, bright, waves in RIBBONS:
        centre = base + tilt * x
        for freq, phase in waves:
            centre = centre + amp * np.sin(2.0 * np.pi * freq * x + phase) / len(waves)

        dh = (y - centre) / halo_t
        add(colour, np.exp(-0.5 * dh * dh, dtype=np.float32) * envelope, bright * 0.16)

        dc = (y - centre) / core_t
        add(colour, np.exp(-0.5 * dc * dc, dtype=np.float32) * envelope, bright * 0.80)

    # A broad warm bloom low and right, anchoring the composition.
    ar = w / float(h)
    dx = (x - 0.76) * ar
    dy = y - 0.74
    r = np.sqrt(dx * dx + dy * dy) / 0.80
    add(ACCENT, np.clip(1.0 - r, 0.0, 1.0) ** 2.4, 0.13)

    # Vignette — gentle, and biased so the top-left stays darkest.
    dx = (x - 0.62) * ar
    dy = y - 0.60
    r = np.sqrt(dx * dx + dy * dy) / (1.05 * max(ar, 1.0))
    rgb *= (1.0 - 0.55 * np.clip(r, 0.0, 1.0) ** 1.5)[..., None]

    return rgb


def render(w, h, seed=17):
    """Render at half resolution, upscale in float, then grain + dither."""
    rw, rh = max(w // 2, 8), max(h // 2, 8)
    small = field(rw, rh)

    chans = []
    for i in range(3):
        im = Image.fromarray(small[..., i], mode="F").resize((w, h), Image.BICUBIC)
        chans.append(np.asarray(im, dtype=np.float32))
    arr = np.stack(chans, axis=-1)

    rng = np.random.default_rng(seed)
    # Fine luminance grain — gives the flat darks some tooth.
    arr += rng.normal(0.0, 0.0035, (h, w, 1)).astype(np.float32)
    # Dither immediately before quantising. Without this, the dark smooth
    # areas band into visible steps.
    arr += rng.uniform(-0.5, 0.5, arr.shape).astype(np.float32) / 255.0

    return Image.fromarray((np.clip(arr, 0.0, 1.0) * 255.0).astype(np.uint8), "RGB")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--preview", action="store_true",
                    help="render a single small image for eyeballing")
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    if args.preview:
        path = args.out or "/tmp/wallpaper_preview.png"
        render(2048, 1152).save(path)
        print(path)
        return

    os.makedirs(OUTDIR, exist_ok=True)
    for w, h, label in TARGETS:
        path = os.path.join(OUTDIR, f"SoundingTV-{label}-{w}x{h}.png")
        render(w, h).save(path)
        print(f"{label:6} -> {path}")


if __name__ == "__main__":
    main()
