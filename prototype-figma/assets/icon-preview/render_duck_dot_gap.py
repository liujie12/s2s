# -*- coding: utf-8 -*-
"""黄油体「找」+ 鸭头作点，且鸭头与笔画之间留主色间隙。

用途：
    在点的位置放置 4B 鸭头，并对鸭头轮廓做形态学膨胀，
    把膨胀区域涂成底色，形成隔离带，避免鸭头与「戈」的横笔粘连。
    输出三档间隙供评审。
"""

import os

from PIL import Image, ImageDraw, ImageFilter, ImageFont

from render_zhao_in_duck import BRAND, WHITE, DUCK_HEAD_PATH, path_to_polygon

SUPERSAMPLE = 2
CANVAS = 1024
FONT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fonts",
                    "ZCOOLQingKeHuangYou-Regular.ttf")

TEXT_SIZE = 620
TEXT_CENTER = (500.0, 540.0)
DOT_REL = (0.30, -0.32)
DUCK_SCALE = 0.34
X_OFFSET = 30                 # 字居中后再整体右移的像素（1024 尺度）


def dilate(mask, px):
    """用小核多次膨胀近似大范围膨胀，避免大核 MaxFilter 过慢。

    参数：
        mask: L 模式掩膜
        px: 膨胀像素数
    返回：
        膨胀后的掩膜
    """
    left = px
    while left > 0:
        step = 3 if left >= 3 else 1
        mask = mask.filter(ImageFilter.MaxFilter(step * 2 + 1))
        left -= step
    return mask


def render(gap, out_dir, out_name, duck_scale=DUCK_SCALE, text_size=TEXT_SIZE, squash=1.0):
    """渲染一版带隔离带的图标。

    参数：
        gap: 鸭头与笔画之间的间隙（1024 画板像素）
        out_dir: 输出目录
        out_name: 输出文件名前缀
        duck_scale: 鸭头缩放倍数
        text_size: 字号（同时决定整体图形大小与留白）
        squash: 字高压缩比例，1.0 为不压缩
    返回：
        None
    """
    s = SUPERSAMPLE
    size = CANVAS * s

    poly = path_to_polygon(DUCK_HEAD_PATH)
    xs = [p[0] for p in poly]
    ys = [p[1] for p in poly]
    duck_center = ((min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2)

    font = ImageFont.truetype(FONT, int(text_size * s))
    text_layer = Image.new("L", (size, size), 0)
    ImageDraw.Draw(text_layer).text(
        (TEXT_CENTER[0] * s, TEXT_CENTER[1] * s), "找", font=font, fill=255, anchor="mm")

    if squash != 1.0:
        new_h = max(1, int(size * squash))
        squeezed = text_layer.resize((size, new_h), Image.LANCZOS)
        text_layer = Image.new("L", (size, size), 0)
        text_layer.paste(squeezed, (0, int(TEXT_CENTER[1] * s - new_h / 2)))

    # 压缩后点的纵坐标随之变化
    dot_x = TEXT_CENTER[0] + DOT_REL[0] * text_size
    dot_y = TEXT_CENTER[1] + DOT_REL[1] * text_size * squash

    moved = [((x - duck_center[0]) * duck_scale + dot_x,
              (y - duck_center[1]) * duck_scale + dot_y) for x, y in poly]

    duck_mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(duck_mask).polygon([(x * s, y * s) for x, y in moved], fill=255)
    inflated = dilate(duck_mask, int(gap * s))

    mask = text_layer
    text_bbox = text_layer.getbbox()   # 居中基准只用「字」，不把鸭头算进去
    mask.paste(0, (0, 0), inflated)
    mask.paste(255, (0, 0), duck_mask)

    # 鸭眼
    eye_x = dot_x + (506.1 - duck_center[0]) * duck_scale
    eye_y = dot_y + (458.5 - duck_center[1]) * duck_scale
    eye_r = 20.27 * duck_scale
    ImageDraw.Draw(mask).ellipse(
        [(eye_x - eye_r) * s, (eye_y - eye_r) * s,
         (eye_x + eye_r) * s, (eye_y + eye_r) * s], fill=0)

    # 以「字」的包围盒为基准整体平移，保证字形居中（鸭头允许向右探出）
    centered = Image.new("L", (size, size), 0)
    if text_bbox:
        dx = (size - (text_bbox[2] - text_bbox[0])) // 2 - text_bbox[0] + int(X_OFFSET * s)
        dy = (size - (text_bbox[3] - text_bbox[1])) // 2 - text_bbox[1]
        centered.paste(mask, (dx, dy))

    img = Image.new("RGB", (size, size), BRAND)
    img.paste(Image.new("RGB", (size, size), WHITE), (0, 0), centered)

    out = img.resize((CANVAS, CANVAS), Image.LANCZOS)
    out.save(os.path.join(out_dir, f"{out_name}.png"))
    out.resize((24, 24), Image.LANCZOS).resize((240, 240), Image.NEAREST).save(
        os.path.join(out_dir, f"{out_name}-24px.png")
    )
    print(out_name, "gap", gap, "squash", squash)


def main():
    """间隙、字号、鸭头固定，比较三档字高压缩量。

    参数：无
    返回：None
    """
    out_dir = os.path.dirname(os.path.abspath(__file__))
    tiers = [
        ("cmp-gap-A", 20, 0.42, 520, 0.92, "压 0.92"),
        ("cmp-gap-B", 20, 0.42, 520, 0.85, "压 0.85"),
        ("cmp-gap-C", 20, 0.42, 520, 0.78, "压 0.78"),
    ]
    for name, gap, scale, tsize, squash, _label in tiers:
        render(gap, out_dir, name, duck_scale=scale, text_size=tsize, squash=squash)

    sheet = Image.new("RGB", (320 * len(tiers) + 40 * (len(tiers) + 1), 380), (0xF7, 0xF7, 0xF8))
    d = ImageDraw.Draw(sheet)
    label_font = ImageFont.truetype(os.path.join(os.environ["WINDIR"], "Fonts", "msyh.ttc"), 18)
    for i, (name, _g, _s, _z, _q, label) in enumerate(tiers):
        p = os.path.join(out_dir, f"{name}.png")
        x = 40 + i * 360
        sheet.paste(Image.open(p).resize((320, 320), Image.LANCZOS), (x, 20))
        d.text((x + 8, 348), label, font=label_font, fill=(40, 40, 40))
    sheet.save(os.path.join(out_dir, "cmp-gap.png"))
    print("done")


if __name__ == "__main__":
    main()
