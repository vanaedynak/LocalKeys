"""Generates the app icons (iOS AppIcon + Windows .ico files). Run: python tools/make_icons.py"""
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def gradient(size, top, bottom):
    img = Image.new("RGB", (size, size))
    d = ImageDraw.Draw(img)
    for y in range(size):
        d.line([(0, y), (size, y)], fill=lerp(top, bottom, y / (size - 1)))
    return img


def draw_keyboard(d, size, color, accent):
    """A stylised keyboard: three rows of keycaps and a space bar."""
    s = size / 1024
    left, right = 170 * s, 854 * s
    top = 300 * s
    gap = 22 * s
    rows = [7, 6, 5]
    key_h = 84 * s
    r = 20 * s
    for ri, count in enumerate(rows):
        width = right - left
        indent = ri * 48 * s
        kw = (width - 2 * indent - gap * (count - 1)) / count
        y = top + ri * (key_h + gap)
        for k in range(count):
            x = left + indent + k * (kw + gap)
            fill = accent if (ri == 1 and k in (1, 2, 3)) or (ri == 0 and k == 1) else color
            d.rounded_rectangle([x, y, x + kw, y + key_h], radius=r, fill=fill)
    y = top + 3 * (key_h + gap)
    d.rounded_rectangle([left + 150 * s, y, right - 150 * s, y + key_h], radius=r, fill=color)


def app_icon(size, rounded=False):
    img = gradient(size, (76, 92, 255), (150, 70, 230)).convert("RGBA")
    d = ImageDraw.Draw(img)
    draw_keyboard(d, size, (255, 255, 255, 255), (255, 214, 102, 255))
    if rounded:
        mask = Image.new("L", (size, size), 0)
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1], radius=int(size * 0.22), fill=255)
        img.putalpha(mask)
    return img


def tray_icon(size, color):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, size * 0.18, size - 1, size * 0.82], radius=size * 0.16, fill=color)
    hole = (0, 0, 0, 0)
    cols, rows = 5, 2
    pad = size * 0.14
    kw = (size - 2 * pad) / cols
    for r in range(rows):
        for c in range(cols):
            x = pad + c * kw
            y = size * 0.28 + r * size * 0.17
            d.rectangle([x + kw * 0.18, y, x + kw * 0.82, y + size * 0.1], fill=hole)
    d.rectangle([size * 0.3, size * 0.64, size * 0.7, size * 0.72], fill=hole)
    return img


def main():
    ios = ROOT / "ios/LocalKeys/Assets.xcassets/AppIcon.appiconset"
    ios.mkdir(parents=True, exist_ok=True)
    app_icon(1024).convert("RGB").save(ios / "icon-1024.png")

    win = ROOT / "windows/LocalKeys/Assets"
    win.mkdir(parents=True, exist_ok=True)
    big = app_icon(512, rounded=True)
    big.save(win / "app.ico", sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    for name, color in (("tray_on.ico", (110, 200, 255, 255)), ("tray_off.ico", (170, 170, 170, 255))):
        tray_icon(64, color).save(win / name, sizes=[(16, 16), (24, 24), (32, 32), (48, 48)])
    big.save(ROOT / "docs/icon.png") if (ROOT / "docs").exists() else None
    print("icons written")


if __name__ == "__main__":
    main()
