"""Grainy silk-marble backgrounds for the first-run pages.

A smooth domain-warped field folded into flowing bands (the silk), shaded
with a fake light from the field's gradient, mapped onto a dark/mid/sheen
palette per page, then monochrome grain. Rendered oversize and cropped so
no wrap seam shows. 780x1688 JPEG (2x of the 390x844 board frame).
"""
import sys
import numpy as np
from PIL import Image

W, H = 780, 1688
PAD = 1.35  # oversize factor before the centre crop


def value_noise(shape, cells, rng):
    h, w = shape
    grid = rng.random((cells, max(2, int(cells * w / h)))).astype(np.float32)
    img = Image.fromarray((grid * 255).astype(np.uint8), 'L').resize((w, h), Image.BICUBIC)
    return np.asarray(img).astype(np.float32) / 255.0


def fbm(shape, rng, base_cells=3, octaves=4, gain=0.45):
    out = np.zeros(shape, np.float32)
    amp, cells, total = 1.0, base_cells, 0.0
    for _ in range(octaves):
        out += amp * value_noise(shape, cells, rng)
        total += amp
        amp *= gain
        cells *= 2
    return out / total


def warp(a, dx, dy, strength):
    h, w = a.shape
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    xs = np.clip(xx + (dx - 0.5) * strength * w, 0, w - 1.001)
    ys = np.clip(yy + (dy - 0.5) * strength * h, 0, h - 1.001)
    x0 = xs.astype(int); y0 = ys.astype(int)
    x1 = np.minimum(x0 + 1, w - 1); y1 = np.minimum(y0 + 1, h - 1)
    fx = xs - x0; fy = ys - y0
    return (a[y0, x0] * (1 - fx) * (1 - fy) + a[y0, x1] * fx * (1 - fy)
            + a[y1, x0] * (1 - fx) * fy + a[y1, x1] * fx * fy)


def blur(a, sigma):
    """Separable float blur: three box passes approximate a Gaussian."""
    r = max(1, int(sigma * 0.9))
    for _ in range(3):
        for axis in (0, 1):
            pad = np.pad(a, [(r, r) if i == axis else (0, 0) for i in range(2)], mode='edge')
            c = np.cumsum(pad, axis=axis, dtype=np.float64)
            n = a.shape[axis]
            if axis == 0:
                a = ((c[2 * r:2 * r + n, :] - np.concatenate([np.zeros((1, c.shape[1])), c[:n - 1, :]], 0)) / (2 * r + 1)).astype(np.float32)
            else:
                a = ((c[:, 2 * r:2 * r + n] - np.concatenate([np.zeros((c.shape[0], 1)), c[:, :n - 1]], 1)) / (2 * r + 1)).astype(np.float32)
    return a


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


def hex_rgb(s):
    s = s.lstrip('#')
    return np.array([int(s[i:i + 2], 16) for i in (0, 2, 4)], np.float32) / 255.0


def silk(seed, dark, mid, sheen, folds=1.6, grain=0.07):
    rng = np.random.default_rng(seed)
    h, w = int(H * PAD), int(W * PAD)
    shape = (h, w)
    f = fbm(shape, rng, 2, 4)
    qx, qy = fbm(shape, rng, 2, 3), fbm(shape, rng, 2, 3)
    f = warp(f, qx, qy, 0.5)
    rx, ry = fbm(shape, rng, 3, 3), fbm(shape, rng, 3, 3)
    f = warp(f, rx, ry, 0.3)
    f = (f - f.min()) / (f.max() - f.min() + 1e-6)
    f = blur(f, 9)

    # Fold the field into flowing bands, like creased silk.
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    diag = (0.55 * xx / w + 0.45 * yy / h)
    b = 0.5 + 0.5 * np.sin(2 * np.pi * (folds * diag + 2.0 * f))
    b = blur(b.astype(np.float32), 12)

    # Fake light from the band gradient: one side of each fold catches it.
    gy, gx = np.gradient(b)
    light = np.clip(1.0 + 650 * (gx * -0.6 + gy * -0.8), 0.78, 1.22)

    # Palette: dark body, mid where the fold rises, grey-cream sheen at the crest.
    t_mid = smoothstep(0.25, 0.7, b)[..., None]
    t_sheen = 0.62 * smoothstep(0.7, 0.98, b)[..., None]
    col = dark * (1 - t_mid) + mid * t_mid
    col = col * (1 - t_sheen) + sheen * t_sheen
    col = col * light[..., None]

    # Broad luminance drift so no region is flat, and a calmer lower third.
    drift = fbm(shape, rng, 2, 2)[..., None]
    col = col * (0.78 + 0.3 * drift)
    y01 = (yy / h)[..., None]
    col = col * (1 - 0.28 * smoothstep(0.55, 1.0, y01))

    g = rng.normal(0, grain, (h, w, 1)).astype(np.float32)
    col = np.clip(col + g, 0, 1)
    y0, x0 = (h - H) // 2, (w - W) // 2
    return Image.fromarray((col[y0:y0 + H, x0:x0 + W] * 255).astype(np.uint8), 'RGB')


PAGES = {
    'welcome': (11, '#3b0f22', '#8e2748', '#cdb9ad'),
    'artists': (23, '#201538', '#5a4489', '#cdc5d6'),
    'step-1':  (37, '#0f2131', '#3c6684', '#c6cfd2'),
    'step-2':  (41, '#13261b', '#3f6a4d', '#c9d0c3'),
    'step-3':  (53, '#3e1f10', '#9b5435', '#d8cbbc'),
    'sign-in': (67, '#120f16', '#3a2f43', '#bfb6c0'),
}

if __name__ == '__main__':
    out_dir = sys.argv[1]
    for name, (seed, dark, mid, sheen) in PAGES.items():
        img = silk(seed, hex_rgb(dark), hex_rgb(mid), hex_rgb(sheen))
        img.save(f'{out_dir}/bg-{name}.jpg', quality=88, optimize=True)
        print(name, 'ok')
