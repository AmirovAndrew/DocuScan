#!/usr/bin/env python3
"""Generate the small tileable textures the game uses.

Everything here is procedural (numpy noise), so the outputs carry no third-party
licence; they are dedicated to the public domain (CC0) like the rest of the
generated assets. Re-run after changing parameters:

    python3 tools/make_textures.py game/textures
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter


def fractal_noise(n: int, beta: float, seed: int, kmin: float = 0.0, kmax: float = 1.0) -> np.ndarray:
    """Periodic (tileable) 1/f^beta noise in [0, 1], band-limited to [kmin, kmax] of Nyquist."""
    rng = np.random.default_rng(seed)
    spec = np.fft.fft2(rng.standard_normal((n, n)))
    kx = np.fft.fftfreq(n)[:, None]
    ky = np.fft.fftfreq(n)[None, :]
    k = np.sqrt(kx * kx + ky * ky) / 0.5  # 1.0 == Nyquist
    k[0, 0] = 1.0
    spec *= 1.0 / np.power(k, beta)
    spec[(k < kmin) | (k > kmax)] = 0.0
    spec[0, 0] = 0.0
    out = np.real(np.fft.ifft2(spec))
    out -= out.min()
    out /= max(out.max(), 1e-9)
    return out


def to_u8(a: np.ndarray) -> np.ndarray:
    return np.clip(a * 255.0 + 0.5, 0, 255).astype(np.uint8)


def snow_textures(out: Path, n: int = 256) -> None:
    low = fractal_noise(n, 2.2, 1, kmax=0.08)     # drifts, metres-scale
    mid = fractal_noise(n, 1.6, 2, kmax=0.35)     # lumps
    fine = fractal_noise(n, 0.9, 3)               # grain
    sparkle = np.random.default_rng(4).random((n, n))
    rgba = np.stack([low, mid, fine, sparkle], axis=-1)
    Image.fromarray(to_u8(rgba), "RGBA").save(out / "snow_noise.png")

    # Normal map from a soft height field (periodic gradients via np.roll).
    h = 0.55 * low + 0.35 * mid + 0.10 * fine
    strength = 6.0
    dx = (np.roll(h, -1, axis=1) - np.roll(h, 1, axis=1)) * strength
    dy = (np.roll(h, -1, axis=0) - np.roll(h, 1, axis=0)) * strength
    nz = np.ones_like(h)
    norm = np.sqrt(dx * dx + dy * dy + nz * nz)
    nrm = np.stack([-dx / norm, -dy / norm, nz / norm], axis=-1) * 0.5 + 0.5
    Image.fromarray(to_u8(nrm), "RGB").save(out / "snow_normal.png")


def footprint_texture(out: Path) -> None:
    """Single boot print (toe at the top), white = pressed-in snow. 64x128."""
    w, h, ss = 64, 128, 4
    img = Image.new("L", (w * ss, h * ss), 0)
    d = ImageDraw.Draw(img)
    s = ss
    d.ellipse([14 * s, 6 * s, 50 * s, 70 * s], fill=255)      # sole / toe box
    d.rectangle([18 * s, 50 * s, 46 * s, 84 * s], fill=235)   # arch
    d.ellipse([16 * s, 80 * s, 48 * s, 122 * s], fill=255)    # heel
    # Tread: darker grooves across the sole and heel.
    for y in range(12, 118, 7):
        if 74 <= y <= 84:
            continue
        d.rectangle([10 * s, y * s, 54 * s, (y + 2) * s], fill=150)
    mask = Image.new("L", (w * ss, h * ss), 0)
    md = ImageDraw.Draw(mask)
    md.ellipse([14 * s, 6 * s, 50 * s, 70 * s], fill=255)
    md.rectangle([18 * s, 50 * s, 46 * s, 84 * s], fill=255)
    md.ellipse([16 * s, 80 * s, 48 * s, 122 * s], fill=255)
    img = Image.composite(img, Image.new("L", img.size, 0), mask)
    img = img.filter(ImageFilter.GaussianBlur(2.5 * ss)).resize((w, h), Image.LANCZOS)
    img.save(out / "footprint.png")


def main() -> None:
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "game/textures")
    out.mkdir(parents=True, exist_ok=True)
    snow_textures(out)
    footprint_texture(out)
    print("textures written to", out)


if __name__ == "__main__":
    main()
