# -*- coding: utf-8 -*-
"""输出最终定稿效果的图标预览（不写入 Android 工程）。

用途：
    按「黄油体找字 + 鸭头作点、间隙 20、鸭头 0.42」的定稿参数，
    生成 1024 主图，并派生圆角方形、圆形遮罩与多尺寸真实大小对照，
    供确认后再决定是否落地。
"""

import os

from PIL import Image, ImageDraw, ImageFont

from render_duck_dot_gap import render, CANVAS

GAP = 20
DUCK_SCALE = 0.42
TEXT_SIZE = 520
SQUASH = 0.85
CORNER_RATIO = 0.224


def rounded(img, size, ratio=CORNER_RATIO):
    """把方形图裁成圆角方形。

    参数：
        img: 源图
        size: 输出边长
        ratio: 圆角半径占边长比例
    返回：
        PIL.Image，RGB
    """
    src = img.resize((size, size), Image.LANCZOS)
    mask = Image.new("L", (size * 4, size * 4), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, size * 4 - 1, size * 4 - 1], radius=int(size * 4 * ratio), fill=255)
    mask = mask.resize((size, size), Image.LANCZOS)
    out = Image.new("RGB", (size, size), (0xF7, 0xF7, 0xF8))
    out.paste(src, (0, 0), mask)
    return out


def circular(img, size):
    """把方形图裁成圆形。

    参数：
        img: 源图
        size: 输出边长
    返回：
        PIL.Image，RGB
    """
    src = img.resize((size, size), Image.LANCZOS)
    mask = Image.new("L", (size * 4, size * 4), 0)
    ImageDraw.Draw(mask).ellipse([0, 0, size * 4 - 1, size * 4 - 1], fill=255)
    mask = mask.resize((size, size), Image.LANCZOS)
    out = Image.new("RGB", (size, size), (0xF7, 0xF7, 0xF8))
    out.paste(src, (0, 0), mask)
    return out


def main():
    """生成全部预览文件。

    参数：无
    返回：None
    """
    out_dir = os.path.dirname(os.path.abspath(__file__))
    render(GAP, out_dir, "final-1024", duck_scale=DUCK_SCALE, text_size=TEXT_SIZE, squash=SQUASH)

    src = Image.open(os.path.join(out_dir, "final-1024.png")).convert("RGB")
    rounded(src, 512).save(os.path.join(out_dir, "final-rounded.png"))
    circular(src, 512).save(os.path.join(out_dir, "final-circle.png"))

    # 多尺寸真实大小对照
    sizes = [192, 144, 96, 72, 48, 32, 24]
    pad = 28
    width = sum(sizes) + pad * (len(sizes) + 1)
    height = max(sizes) + pad * 2 + 30
    sheet = Image.new("RGB", (width, height), (0xF7, 0xF7, 0xF8))
    d = ImageDraw.Draw(sheet)
    label_font = ImageFont.truetype(os.path.join(os.environ["WINDIR"], "Fonts", "msyh.ttc"), 14)
    x = pad
    for s in sizes:
        icon = rounded(src, s)
        y = pad + (max(sizes) - s) // 2
        sheet.paste(icon, (x, y))
        d.text((x, pad + max(sizes) + 8), f"{s}px", font=label_font, fill=(80, 80, 80))
        x += s + pad
    sheet.save(os.path.join(out_dir, "final-multi-size.png"))
    print("done")


if __name__ == "__main__":
    main()
