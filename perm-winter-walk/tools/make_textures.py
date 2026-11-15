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


def needle_texture(out: Path, n: int = 256) -> None:
    """Spruce needles along a branchlet (v = along the branch), tileable, plus a normal map."""
    ss = 2
    size = n * ss
    rng = np.random.default_rng(7)
    height = Image.new("L", (size, size), 0)
    color = Image.new("RGB", (size, size), (6, 16, 10))
    dh = ImageDraw.Draw(height)
    dc = ImageDraw.Draw(color)
    for _ in range(5200):
        x, y = rng.uniform(0, size, 2)
        side = 1 if rng.random() < 0.5 else -1
        ang = np.radians(90 + side * rng.uniform(25, 55))   # needles splay out from the twig
        length = rng.uniform(9, 17) * ss
        dx, dy = np.cos(ang) * length, -np.sin(ang) * length
        g = rng.uniform(0.6, 1.25)
        col = (int(14 * g), int(44 * g), int(26 * g))
        if rng.random() < 0.12:
            col = (int(30 * g), int(58 * g), int(28 * g))   # a few younger, lighter needles
        w = int(rng.integers(1, 3)) * ss
        hv = int(rng.uniform(120, 255))
        for ox in (-size, 0, size):
            for oy in (-size, 0, size):
                seg = [(x + ox, y + oy), (x + ox + dx, y + oy + dy)]
                dc.line(seg, fill=col, width=w)
                dh.line(seg, fill=hv, width=w)
    # twig lines running along v
    for x in np.linspace(0, size, 5)[:-1] + rng.uniform(0, size / 4):
        for ox in (-size, 0, size):
            dc.line([(x + ox, 0), (x + ox, size)], fill=(22, 18, 12), width=2 * ss)
    color = color.resize((n, n), Image.LANCZOS)
    color.save(out / "needles.png")
    h = np.asarray(height.resize((n, n), Image.LANCZOS), dtype=np.float64) / 255.0
    h = np.asarray(Image.fromarray((h * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(0.6)),
                   dtype=np.float64) / 255.0
    strength = 3.0
    dx = (np.roll(h, -1, axis=1) - np.roll(h, 1, axis=1)) * strength
    dy = (np.roll(h, -1, axis=0) - np.roll(h, 1, axis=0)) * strength
    nz = np.ones_like(h)
    norm = np.sqrt(dx * dx + dy * dy + nz * nz)
    nrm = np.stack([-dx / norm, -dy / norm, nz / norm], axis=-1) * 0.5 + 0.5
    Image.fromarray(to_u8(nrm), "RGB").save(out / "needles_normal.png")


def needle_fringe_texture(out: Path, w: int = 256, h: int = 128) -> None:
    """Hanging twigs ("bottle brushes" of short needles) along a branch edge, v = 0 at the
    edge; alpha-tested, tileable in u. Gives near spruces a ragged, feathery outline."""
    ss = 2
    W, H = w * ss, h * ss
    rng = np.random.default_rng(11)
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, W, int(0.1 * H)], fill=(9, 28, 17, 255))
    for _ in range(230):
        x = rng.uniform(0, W)
        y0 = rng.uniform(0.0, 0.2 * H)
        length = rng.uniform(0.3, 0.85) * H
        ang = np.radians(rng.uniform(-22, 22))
        ux, uy = np.sin(ang), np.cos(ang)
        g = rng.uniform(0.65, 1.3)
        base = (int(12 * g), int(40 * g), int(24 * g), 255)
        steps = int(length / (2.2 * ss))
        for k in range(steps):
            t = k / max(steps - 1, 1)
            px, py = x + ux * length * t, y0 + uy * length * t
            nl = (11 - 6 * t) * ss * rng.uniform(0.8, 1.2)   # needles shorter towards the tip
            for side in (-1, 1):
                a = ang + side * np.radians(rng.uniform(40, 65))
                qx, qy = px + np.sin(a) * nl, py + np.cos(a) * nl
                col = base if rng.random() > 0.1 else (int(26 * g), int(56 * g), int(30 * g), 255)
                for ox in (-W, 0, W):
                    d.line([(px + ox, py), (qx + ox, qy)], fill=col, width=ss)
        for ox in (-W, 0, W):
            d.line([(x + ox, y0), (x + ux * length + ox, y0 + uy * length)], fill=(20, 16, 10, 255), width=ss)
    img = img.resize((w, h), Image.LANCZOS)
    img.save(out / "needle_fringe.png")


SIGN_WORDS = ["ПРОДУКТЫ", "АПТЕКА", "КАФЕ", "ЦВЕТЫ", "ХЛЕБ", "ОПТИКА", "КНИГИ", "ПИЦЦА",
              "ОБУВЬ", "СТОЛОВАЯ", "ЧАСЫ", "МАГАЗИН", "24 ЧАСА", "СУВЕНИРЫ", "ШАУРМА", "САЛОН"]


def shop_sign_atlas(out: Path) -> None:
    """Generic Russian shop signs (no brands), one word per 512x64 row, white on black.
    The facade shader tints them and lights them up above shop windows."""
    from PIL import ImageFont
    font_path = None
    for cand in ("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",):
        if Path(cand).exists():
            font_path = cand
    if font_path is None:
        import matplotlib
        font_path = str(Path(matplotlib.__file__).parent / "mpl-data/fonts/ttf/DejaVuSans-Bold.ttf")
    cw, ch = 512, 64
    img = Image.new("L", (cw, ch * len(SIGN_WORDS)), 0)
    d = ImageDraw.Draw(img)
    for i, word in enumerate(SIGN_WORDS):
        size = 46
        font = ImageFont.truetype(font_path, size)
        while d.textlength(word, font=font) > cw - 40 and size > 20:
            size -= 2
            font = ImageFont.truetype(font_path, size)
        w = d.textlength(word, font=font)
        d.text(((cw - w) / 2, i * ch + (ch - size) / 2 - 4), word, fill=255, font=font)
    img.save(out / "shop_signs.png")


def main() -> None:
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "game/textures")
    out.mkdir(parents=True, exist_ok=True)
    snow_textures(out)
    footprint_texture(out)
    needle_texture(out)
    needle_fringe_texture(out)
    shop_sign_atlas(out)
    print("textures written to", out)


if __name__ == "__main__":
    main()
