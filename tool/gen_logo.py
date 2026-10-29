#!/usr/bin/env python3
"""Ginagawa ang E-Sikad / Sakay Bacuag logo asset mula sa OPISYAL na disenyo.

Ang pinagmumulan ngayon ay ang EXAKTOGONG #sakay-bacuag-logo SVG na nasa
index.html / admin / docs (magkapareho ang tatlo — na-verify sa md5). Ang
proseso:

  1. tool/sakay-bacuag-logo.svg  — kinuha nang direkta sa symbol ng index.html
  2. tool/logo-master.png        — 1024px render nito (transparent ang mga sulok),
     ginawa gamit ang headless Chrome:
       chrome --headless=new --disable-gpu --hide-scrollbars \
         --default-background-color=00000000 --window-size=1024,1024 \
         --screenshot=tool/logo-master.png tool/_logo_render.html
  3. Ang script na ito ang nagda-downscale sa lahat ng kailangang laki —
     kaya GARANTO na pareho sa nakikita sa web pages (dating: mano-manong
     muli ang pagguhit, kaya may kaibahan sa index.html).

Output:
  assets/logo.png          - in-app logo (AppBar, header)
  android/app/src/main/res/mipmap-*/ic_launcher.png
  web/icons/Icon-*.png
  web/favicon.png           (kung mayroon)
"""
import os
import sys

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
MASTER = os.path.join(HERE, "logo-master.png")

# Kung wala pang master (bagong checkout), ipapakita kung paano gumawa.
MASTER_HELP = (
    "Wala pang tool/logo-master.png. Gumawa nito mula sa index.html SVG:\n"
    '  chrome --headless=new --disable-gpu --hide-scrollbars '
    '--default-background-color=00000000 --window-size=1024,1024 \\\n'
    '    --screenshot="tool/logo-master.png" tool/_logo_render.html'
)


def build(size, border_ratio=0.075):
    """Bumubuo ng logo sa {size}px.

    Puting base (ang lumalabas na "white border" na hiningi sa bug #11) +
    ang eksaktong artwork mula sa index.html sa loob nito.
    """
    if not os.path.exists(MASTER):
        sys.exit(MASTER_HELP)
    master = Image.open(MASTER).convert("RGBA")

    border = int(size * border_ratio)
    inner = size - 2 * border

    canvas = Image.new("RGBA", (size, size), (255, 255, 255, 255))
    art = master.resize((inner, inner), Image.LANCZOS)
    canvas.alpha_composite(art, (border, border))
    return canvas


def main():
    logo_path = os.path.join(ROOT, "assets", "logo.png")
    build(512).save(logo_path)
    print("wrote", logo_path)

    # Android launcher icons
    mipmap_root = os.path.join(ROOT, "android", "app", "src", "main", "res")
    densities = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
    for density, px in densities.items():
        out = os.path.join(mipmap_root, f"mipmap-{density}", "ic_launcher.png")
        if os.path.isdir(os.path.dirname(out)):
            build(px, border_ratio=0.075).save(out)
            print("wrote", out)

    # Web / PWA icons
    web_icons = os.path.join(ROOT, "web", "icons")
    if os.path.isdir(web_icons):
        for name, px in [("Icon-192.png", 192), ("Icon-512.png", 512)]:
            out = os.path.join(web_icons, name)
            build(px).save(out)
            print("wrote", out)
        for name, px in [("Icon-maskable-192.png", 192), ("Icon-maskable-512.png", 512)]:
            out = os.path.join(web_icons, name)
            # Maskable: mas malaking safe area, kaya mas maliit ang logo sa loob
            build(px, border_ratio=0.16).save(out)
            print("wrote", out)

    # Favicon (kung mayroon na sa starter)
    favicon = os.path.join(ROOT, "web", "favicon.png")
    if os.path.isfile(favicon):
        px = Image.open(favicon).size[0]
        build(px).save(favicon)
        print("wrote", favicon, f"({px}px)")


if __name__ == "__main__":
    main()
