# -*- coding: utf-8 -*-
"""从统一构图重新生成各平台启动器图标。

本机没有 dart/flutter 与 SVG 渲染器，因此直接用 Pillow 绘制。
构图源文件: design/logo_mark.svg（满幅版，无内层终端框）。

用法（仓库根目录）:
    python3 tools/generate_app_icons.py

产出三种母版:
    app_icon.png          圆角 + 四角透明 -> macOS / Windows / Web
    app_icon_square.png   方形不透明     -> iOS / Android legacy / Web maskable
    adaptive_foreground.png 透明 + 主体居中 -> Android 自适应图标前景
"""
from pathlib import Path
import re

from PIL import Image, ImageDraw, ImageFilter, ImageOps

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "ai_terminal"
S = 1024
SS = 2
W = S * SS

BG_TOP = (27, 39, 66)
BG_BOTTOM = (11, 16, 28)
BLUE_TOP = (59, 125, 255)
BLUE_BOTTOM = (90, 154, 255)
GREEN = (124, 224, 90)
SPARKLE = (155, 240, 107)


def scale(v):
    return int(round(v * SS))


def gradient(c0, c1):
    g = Image.linear_gradient("L").resize((W, W), Image.LANCZOS)
    return ImageOps.colorize(g, black=c0, white=c1).convert("RGBA")


def rounded_mask():
    m = Image.new("L", (W, W), 0)
    ImageDraw.Draw(m).rounded_rectangle(
        [0, 0, W - 1, W - 1], radius=scale(224), fill=255
    )
    return m


def star_points(size):
    k = size / 1024.0
    cx, cy, outer = 762 * k, 276 * k, 147 * k
    inner = [(0, -14), (1.8, -5.2), (10, 0), (1.8, 5.2),
             (0, 14), (-1.8, 5.2), (-10, 0), (-1.8, -5.2)]
    f = outer / 14.0
    return [(cx + x * f, cy + y * f) for x, y in inner]


def subject(size=W):
    """只含彩色主体，背景透明。"""
    k = size / 1024.0
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    pts = star_points(size)
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(glow).polygon(pts, fill=(*SPARKLE, 210))
    glow = glow.filter(ImageFilter.GaussianBlur(max(1, 30 * k)))
    layer = Image.alpha_composite(layer, glow)

    d = ImageDraw.Draw(layer)
    d.polygon(pts, fill=(*SPARKLE, 255))

    d.rounded_rectangle(
        [566 * k, 682 * k, 866 * k, 782 * k],
        radius=50 * k,
        fill=(*GREEN, 255),
    )

    chevron = Image.new("L", (size, size), 0)
    cd = ImageDraw.Draw(chevron)
    line = [(250 * k, 268 * k), (548 * k, 512 * k), (250 * k, 756 * k)]
    width = int(104 * k)
    cd.line(line, fill=255, width=width, joint="curve")
    r = width / 2
    for x, y in line:
        cd.ellipse([x - r, y - r, x + r, y + r], fill=255)

    cg = Image.linear_gradient("L").resize((size, size), Image.LANCZOS)
    blue = ImageOps.colorize(cg, black=BLUE_TOP, white=BLUE_BOTTOM).convert("RGBA")
    blue.putalpha(chevron)
    layer = Image.alpha_composite(layer, blue)
    return layer


def build_masters():
    mask = rounded_mask()
    subj = subject()

    bg = gradient(BG_TOP, BG_BOTTOM)
    ImageDraw.Draw(bg).rounded_rectangle(
        [scale(2), scale(2), W - 1 - scale(2), W - 1 - scale(2)],
        radius=scale(222),
        outline=(48, 58, 86, 255),
        width=scale(3),
    )
    rounded = Image.alpha_composite(bg, subj)
    # 圆角外彻底透明，避免某些渲染器把透明区 RGB 显示成杂边
    rounded = Image.composite(
        rounded, Image.new("RGBA", (W, W), (0, 0, 0, 0)), mask
    )

    square = Image.alpha_composite(gradient(BG_TOP, BG_BOTTOM), subj)
    square.putalpha(255)

    inner = subject().resize((int(S * 0.66),) * 2, Image.LANCZOS)
    adaptive = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    offset = (S - inner.width) // 2
    adaptive.alpha_composite(inner, (offset, offset))

    out = APP / "assets" / "icons"
    rounded.resize((S, S), Image.LANCZOS).save(out / "app_icon.png")
    square.resize((S, S), Image.LANCZOS).save(out / "app_icon_square.png")
    adaptive.save(out / "adaptive_foreground.png")
    return {
        "rounded": rounded,
        "square": square,
        "adaptive": adaptive,
    }


def emit(master, path, size):
    path.parent.mkdir(parents=True, exist_ok=True)
    master.resize((size, size), Image.LANCZOS).save(path)


def main(m):
    res = APP / "android" / "app" / "src" / "main" / "res"
    web = APP / "web"

    # macOS: 16/32/64/128/256/512/1024
    mac = APP / "macos" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
    for p in mac.glob("app_icon_*.png"):
        emit(m["rounded"], p, int(p.stem.rsplit("_", 1)[1]))

    # iOS: 系统自带圆角遮罩，必须不透明
    ios = APP / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
    for p in ios.glob("Icon-App-*.png"):
        hit = re.search(r"Icon-App-([\d.]+)x[\d.]+@(\d)x", p.name)
        if hit:
            emit(m["square"], p, int(float(hit.group(1)) * int(hit.group(2))))

    # Android legacy mipmap
    for folder, size in [("mdpi", 48), ("hdpi", 72), ("xhdpi", 96),
                         ("xxhdpi", 144), ("xxxhdpi", 192)]:
        emit(m["square"], res / f"mipmap-{folder}" / "ic_launcher.png", size)

    # Android 自适应图标前景（108dp 系列）
    for folder, size in [("mdpi", 108), ("hdpi", 162), ("xhdpi", 216),
                         ("xxhdpi", 324), ("xxxhdpi", 432)]:
        emit(m["adaptive"], res / f"drawable-{folder}" / "ic_launcher_foreground.png", size)

    # Web
    for size in (192, 512):
        emit(m["rounded"], web / "icons" / f"Icon-{size}.png", size)
        emit(m["square"], web / "icons" / f"Icon-maskable-{size}.png", size)
    emit(m["rounded"], web / "favicon.png", 16)

    # Windows: 多尺寸 ICO，避免只有 48x48 导致放大发虚
    m["rounded"].resize((256, 256), Image.LANCZOS).save(
        APP / "windows" / "runner" / "resources" / "app_icon.ico",
        format="ICO",
        sizes=[(s, s) for s in (16, 20, 24, 32, 40, 48, 64, 96, 128, 256)],
    )

    print("generated: 3 masters + macOS/iOS/Android/Web/Windows icon sets")


if __name__ == "__main__":
    main(build_masters())
