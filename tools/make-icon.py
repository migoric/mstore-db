#!/usr/bin/env python3
"""生成 AppIcon.icns。

为什么用脚本而不是提交一堆 PNG：图标要支持 16–1024 共 10 档，
手改一次要重出十张图。留脚本的好处是改配色只改常量。

macOS 图标画布留白规则：内容占 824/1024 见方（四周各留 100px 透明），
圆角半径约 185px，接近系统的 squircle。留白不对的话，Dock 里会比别人大一圈。
"""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw

SIZE = 1024
INSET = 100
RADIUS = 185

BG_TOP = (42, 42, 46)
BG_BOTTOM = (16, 16, 18)
BARS = [
    (125, 211, 252),  # 表头，最亮
    (56, 189, 248),
    (14, 165, 233),
    (2, 132, 199),
]

ROOT = Path(__file__).resolve().parent.parent


def rounded_mask(size: int, radius: int) -> Image.Image:
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, size - 1, size - 1), radius, fill=255)
    return m


def build_master() -> Image.Image:
    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))

    # 背景：竖直渐变，用逐行画线实现（PIL 没有原生渐变）
    box = SIZE - INSET * 2
    bg = Image.new("RGB", (1, box))
    for y in range(box):
        t = y / (box - 1)
        bg.putpixel(
            (0, y),
            tuple(round(a + (b - a) * t) for a, b in zip(BG_TOP, BG_BOTTOM)),
        )
    bg = bg.resize((box, box), Image.NEAREST).convert("RGBA")
    bg.putalpha(rounded_mask(box, RADIUS))
    canvas.paste(bg, (INSET, INSET), bg)

    draw = ImageDraw.Draw(canvas)

    # 四条横条：宽度依次递减，读起来像一份长短不一的数据表
    widths = [560, 470, 380, 300]
    heights = [92, 70, 70, 70]
    gap = 46
    # 内容总高 440，垂直居中到画布中线——差 24px 肉眼就能看出「图标往上飘」
    y = (SIZE - (sum(heights) + gap * (len(heights) - 1))) // 2
    for (w, h), color in zip(zip(widths, heights), BARS):
        x0 = (SIZE - w) // 2
        draw.rounded_rectangle((x0, y, x0 + w, y + h), radius=h // 2, fill=color)
        y += h + gap

    return canvas


def main() -> None:
    master = build_master()
    icns = ROOT / "tools" / "AppIcon.icns"

    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        # iconutil 只认这些固定文件名，少一个就报错
        for base in (16, 32, 128, 256, 512):
            for scale, suffix in ((1, ""), (2, "@2x")):
                px = base * scale
                name = f"icon_{base}x{base}{suffix}.png"
                master.resize((px, px), Image.LANCZOS).save(iconset / name)
        subprocess.run(
            ["iconutil", "-c", "icns", str(iconset), "-o", str(icns)], check=True
        )

    print(f"wrote {icns} ({icns.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
