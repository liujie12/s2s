# -*- coding: utf-8 -*-
"""按选定的「黄油体找字 + 鸭头作点」方案生成 Android 图标资源。

用途：
    生成 legacy 方形图标（带 22.4% 圆角）与自适应图标前景层，
    覆盖写入 android/app/src/main/res/mipmap-* 目录。

依赖：
    Pillow、fonts/ZCOOLQingKeHuangYou-Regular.ttf、4B 鸭头路径。

    字体不入库（8MB 公开字体，见 .gitignore）：从 Google Fonts 下载
    「ZCOOL QingKe HuangYou / 站酷庆科黄油体」后放到 fonts/ 下；
    文件名须保持 ZCOOLQingKeHuangYou-Regular.ttf，否则 Pillow 打不开。
"""

import os

from PIL import Image, ImageDraw, ImageFilter, ImageFont

from render_zhao_in_duck import DUCK_HEAD_PATH, path_to_polygon

# 品牌色
BRAND = (0x0B, 0x7C, 0x8C)
WHITE = (0xFF, 0xFF, 0xFF)

# 构图参数（与 cmp-dotduck-B 一致）
FONT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fonts",
                    "ZCOOLQingKeHuangYou-Regular.ttf")
TEXT_SIZE = 520
TEXT_CENTER = (500.0, 540.0)
DOT_REL = (0.30, -0.32)
DUCK_SCALE = 0.42
GAP = 20                      # 鸭头与笔画之间的隔离带宽度
SQUASH = 0.85                 # 字高压缩比例，让笔画更接近道路形态
X_OFFSET = 30                 # 字居中后再整体右移的像素（1024 尺度）

SUPERSAMPLE = 2
CANVAS = 1024
CORNER_RATIO = 0.224          # 色块圆角 = 边长 × 22.4%
ADAPTIVE_SAFE = 0.56          # Android 自适应图标前景内容占比（留白更大）

RES = os.path.abspath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "..", "..", "android", "app", "src", "main", "res"))

DENSITIES = [
    ("mdpi", 48, 108),
    ("hdpi", 72, 162),
    ("xhdpi", 96, 216),
    ("xxhdpi", 144, 324),
    ("xxxhdpi", 192, 432),
]


def dilate(mask, px):
    """用小核多次膨胀近似大范围膨胀，避免大核 MaxFilter 的性能问题。

    参数：
        mask: L 模式掩膜
        px: 需要向外膨胀的像素数
    返回：
        膨胀后的掩膜
    """
    left = px
    while left > 0:
        step = 3 if left >= 3 else 1        # MaxFilter(7) 约等于膨胀 3px
        mask = mask.filter(ImageFilter.MaxFilter(step * 2 + 1))
        left -= step
    return mask


def build_art():
    """构建 1024 透明底的白色图形（含隔离带与镂空鸭眼）。

    参数：无
    返回：
        PIL.Image，RGBA，图形为纯白，隔离带与鸭眼处 alpha=0
    """
    s = SUPERSAMPLE
    size = CANVAS * s

    poly = path_to_polygon(DUCK_HEAD_PATH)
    xs = [p[0] for p in poly]
    ys = [p[1] for p in poly]
    duck_center = ((min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2)

    dot_x = TEXT_CENTER[0] + DOT_REL[0] * TEXT_SIZE
    dot_y = TEXT_CENTER[1] + DOT_REL[1] * TEXT_SIZE * SQUASH

    font = ImageFont.truetype(FONT, int(TEXT_SIZE * s))
    text_layer = Image.new("L", (size, size), 0)
    ImageDraw.Draw(text_layer).text(
        (TEXT_CENTER[0] * s, TEXT_CENTER[1] * s), "找", font=font, fill=255, anchor="mm")

    if SQUASH != 1.0:
        new_h = max(1, int(size * SQUASH))
        squeezed = text_layer.resize((size, new_h), Image.LANCZOS)
        text_layer = Image.new("L", (size, size), 0)
        text_layer.paste(squeezed, (0, int(TEXT_CENTER[1] * s - new_h / 2)))

    mask = text_layer
    text_bbox = text_layer.getbbox()   # 居中基准只用「字」，不把鸭头算进去

    moved = [((x - duck_center[0]) * DUCK_SCALE + dot_x,
              (y - duck_center[1]) * DUCK_SCALE + dot_y) for x, y in poly]

    # 鸭头掩膜与膨胀后的隔离带
    duck_mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(duck_mask).polygon([(x * s, y * s) for x, y in moved], fill=255)
    inflated = dilate(duck_mask, int(GAP * s))

    mask.paste(0, (0, 0), inflated)      # 隔离带挖空
    mask.paste(255, (0, 0), duck_mask)   # 再放上鸭头

    # 鸭眼镂空，使前景层透出背景色，换背景色时仍然成立
    eye_x = dot_x + (506.1 - duck_center[0]) * DUCK_SCALE
    eye_y = dot_y + (458.5 - duck_center[1]) * DUCK_SCALE
    eye_r = 20.27 * DUCK_SCALE
    ImageDraw.Draw(mask).ellipse(
        [(eye_x - eye_r) * s, (eye_y - eye_r) * s,
         (eye_x + eye_r) * s, (eye_y + eye_r) * s], fill=0)

    # 以「字」的包围盒为基准整体平移，保证字形居中（鸭头允许向右探出）
    centered = Image.new("L", (size, size), 0)
    if text_bbox:
        dx = (size - (text_bbox[2] - text_bbox[0])) // 2 - text_bbox[0] + int(X_OFFSET * s)
        dy = (size - (text_bbox[3] - text_bbox[1])) // 2 - text_bbox[1]
        centered.paste(mask, (dx, dy))

    centered = centered.resize((CANVAS, CANVAS), Image.LANCZOS)
    art = Image.new("RGBA", (CANVAS, CANVAS), (255, 255, 255, 0))
    art.paste((255, 255, 255), (0, 0), centered)
    art.putalpha(centered)
    return art


def rounded_mask(size, radius_ratio=CORNER_RATIO):
    """生成圆角方形遮罩。

    参数：
        size: 目标边长
        radius_ratio: 圆角半径占边长的比例
    返回：
        PIL.Image，L 模式遮罩
    """
    s = SUPERSAMPLE
    big = size * s
    m = Image.new("L", (big, big), 0)
    ImageDraw.Draw(m).rounded_rectangle(
        [0, 0, big - 1, big - 1], radius=int(big * radius_ratio), fill=255)
    return m.resize((size, size), Image.LANCZOS)


def legacy_icon(art, size):
    """合成带圆角的 legacy 图标。

    参数：
        art: 1024 RGBA 图形
        size: 输出边长
    返回：
        PIL.Image，RGB
    """
    base = Image.new("RGB", (CANVAS, CANVAS), BRAND)
    base.paste(art, (0, 0), art)
    base = base.resize((size, size), Image.LANCZOS)
    out = Image.new("RGB", (size, size), BRAND)
    out.paste(base, (0, 0), rounded_mask(size))
    return out


def foreground_layer(art, size):
    """生成自适应图标前景层（透明底、图形占满 66% 安全区）。

    参数：
        art: 1024 RGBA 图形
        size: 输出边长
    返回：
        PIL.Image，RGBA
    """
    bbox = art.getbbox()
    cropped = art.crop(bbox) if bbox else art
    inner = int(CANVAS * ADAPTIVE_SAFE)
    # 按最长边等比缩放到安全区内，保证图形本身占满 66%
    ratio = min(inner / cropped.width, inner / cropped.height)
    target = (max(1, int(cropped.width * ratio)), max(1, int(cropped.height * ratio)))
    scaled = cropped.resize(target, Image.LANCZOS)
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    offset = ((CANVAS - target[0]) // 2, (CANVAS - target[1]) // 2)
    canvas.paste(scaled, offset, scaled)
    return canvas.resize((size, size), Image.LANCZOS)


def main():
    """生成全部密度资源并写入 Android 工程。

    参数：无
    返回：None
    """
    art = build_art()
    for density, legacy_size, fg_size in DENSITIES:
        folder = os.path.join(RES, f"mipmap-{density}")
        os.makedirs(folder, exist_ok=True)
        legacy_icon(art, legacy_size).save(os.path.join(folder, "ic_launcher.png"))
        foreground_layer(art, fg_size).save(os.path.join(folder, "ic_launcher_foreground.png"))
        print(density, "legacy", legacy_size, "fg", fg_size)

    # 自适应图标描述
    anydpi = os.path.join(RES, "mipmap-anydpi-v26")
    os.makedirs(anydpi, exist_ok=True)
    with open(os.path.join(anydpi, "ic_launcher.xml"), "w", encoding="utf-8") as f:
        f.write(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
            '    <background android:drawable="@color/ic_launcher_background" />\n'
            '    <foreground android:drawable="@mipmap/ic_launcher_foreground" />\n'
            '</adaptive-icon>\n'
        )

    values = os.path.join(RES, "values")
    os.makedirs(values, exist_ok=True)
    with open(os.path.join(values, "colors.xml"), "w", encoding="utf-8") as f:
        f.write(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<resources>\n'
            '    <color name="ic_launcher_background">#0B7C8C</color>\n'
            '</resources>\n'
        )

    # 导出两张预览：圆形遮罩下的自适应图标 + 方形 legacy 图标
    preview_dir = os.path.dirname(os.path.abspath(__file__))
    fg = foreground_layer(art, CANVAS)
    composed = Image.new("RGB", (CANVAS, CANVAS), BRAND)
    composed.paste(fg, (0, 0), fg)
    circle = Image.new("L", (CANVAS, CANVAS), 0)
    ImageDraw.Draw(circle).ellipse([0, 0, CANVAS - 1, CANVAS - 1], fill=255)
    rounded = Image.new("RGB", (CANVAS, CANVAS), (0xF7, 0xF7, 0xF8))
    rounded.paste(composed, (0, 0), circle)
    rounded.resize((512, 512), Image.LANCZOS).save(os.path.join(preview_dir, "preview-adaptive-circle.png"))

    legacy_icon(art, 512).save(os.path.join(preview_dir, "preview-legacy.png"))
    print("done")


if __name__ == "__main__":
    main()
