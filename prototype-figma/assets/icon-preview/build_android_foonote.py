# -*- coding: utf-8 -*-
"""按「黄油体找字 + 脚印作点」方案生成 Android 桌面图标。

替换自 build_android_icons.py：
  - 鸭头 DUCK_HEAD_PATH → 脚印三趾 + 掌（F-01 形态，右斜 +14°）
  - 其余参数完全不动（字体、字高压缩、隔离带 GAP 等）
  - 脚印中心对齐原鸭头中心 dot_x/dot_y（656, 398.56），
    缩放 2.62 使高度 131px ≈ 原鸭头视觉占位，旋转 +14°

2026-11-02：脚印填充色独立为 FP_COLOR（用户裁定 D5 橙红 #FF6B35），
找字固定白色不变；build_art() 相应拆为找字/脚印两层掩膜分别上色。
"""
import os, math

from PIL import Image, ImageDraw, ImageFilter, ImageFont

from render_zhao_in_duck import path_to_polygon

# —— 品牌色 ——
BRAND = (0x0B, 0x7C, 0x8C)
WHITE = (0xFF, 0xFF, 0xFF)
# 脚印填充色（2026-11-02 用户裁定 D5 橙红 #FF6B35；找字固定 WHITE 不变）
FP_COLOR = (0xFF, 0x6B, 0x35)

# —— 构图参数（与原脚本一致，不动）——
HERE = os.path.dirname(os.path.abspath(__file__))
FONT = os.path.join(HERE, "fonts", "ZCOOLQingKeHuangYou-Regular.ttf")
TEXT_SIZE = 520
TEXT_CENTER = (500.0, 540.0)
DOT_REL = (0.30, -0.32)
GAP = 20
SQUASH = 0.85
X_OFFSET = 30

SUPERSAMPLE = 2
CANVAS = 1024
CORNER_RATIO = 0.224
ADAPTIVE_SAFE = 0.56

RES = os.path.abspath(os.path.join(HERE, "..", "..", "..",
                                   "android", "app", "src", "main", "res"))

DENSITIES = [
    ("mdpi", 48, 108),
    ("hdpi", 72, 162),
    ("xhdpi", 96, 216),
    ("xxhdpi", 144, 324),
    ("xxxhdpi", 192, 432),
]

# —— 脚印参数（F-01，fp0 viewBox 0 0 108 108）——
# 精确对齐原鸭头占位：原鸭头合成后 bbox 约 101×88，fp0 bbox 约 44×65
# → FP_SCALE = 88 / 65 ≈ 1.35（1:1 等高对齐）
FP_CENTER = (54.0, 45.0)
FP_SCALE  = 1.70              # 继续放大：1.55→1.70
FP_ROTATE_DEG = 23.0          # 更斜：20→23
# 脚印位置微调（合成画板坐标系原点在 (0,0)，向右 +X、向下 +Y）
FP_DOT_OFFSET_X = 12.0        # 向右挪 12px
FP_DOT_OFFSET_Y = -18.0       # 继续上移：-10→-18

# 三趾（fp0 局部）
FP_TOES = [
    # (cx, cy, rx, ry, rot_deg)
    (40, 35, 7.2, 9.8, -15),   # 左趾
    (54, 30.5, 7.6, 10.6, 0),  # 中趾
    (68, 35, 7.2, 9.8, 15),    # 右趾
]

# 掌 path（fp0 局部，采样成 polygon）
# M37 57 C37 50.5 44.5 48.5 54 48.5 S71 50.5 71 57
# C71 62.5 67.5 66.5 64 72 C60.5 78 59.5 84 54 84
# S47.5 78 44 72 C40.5 66.5 37 62.5 37 57 Z
FP_PALM_PATH_D = (
    "M37 57 C37 50.5 44.5 48.5 54 48.5 S71 50.5 71 57 "
    "C71 62.5 67.5 66.5 64 72 C60.5 78 59.5 84 54 84 "
    "S47.5 78 44 72 C40.5 66.5 37 62.5 37 57 Z"
)


# ============================================================
# 工具函数
# ============================================================

def _sample_bezier(pts, steps=12):
    """把一串贝塞尔控制点采样成 polygon 点。"""
    result = []
    for i in range(0, len(pts) - 3, 3):
        p0, p1, p2, p3 = pts[i], pts[i + 1], pts[i + 2], pts[i + 3]
        for t in range(steps + 1):
            t = t / steps
            mt = 1 - t
            x = (mt ** 3 * p0[0] + 3 * mt ** 2 * t * p1[0]
                 + 3 * mt * t ** 2 * p2[0] + t ** 3 * p3[0])
            y = (mt ** 3 * p0[1] + 3 * mt ** 2 * t * p1[1]
                 + 3 * mt * t ** 2 * p2[1] + t ** 3 * p3[1])
            result.append((x, y))
    return result


def _parse_svg_path_commands(d):
    """解析简化 SVG path，返回 (cmd, pts) 列表。"""
    import re
    tokens = re.findall(r'[MLCQZmlcqz]|[-+]?\d*\.?\d+(?:[eE][-+]?\d+)?', d)
    segs = []
    i = 0
    cx, cy = 0.0, 0.0
    cmd = None
    while i < len(tokens):
        t = tokens[i]
        if t in 'MLCQZmlcqz':
            cmd = t; i += 1
        pts = []
        if cmd in 'Mm':
            n = 2
        elif cmd in 'Ll':
            n = 2
        elif cmd in 'Cc':
            n = 6
        elif cmd in 'Qq':
            n = 4
        elif cmd in 'Zz':
            n = 0
        for _ in range(n):
            pts.append(float(tokens[i])); i += 1
        if cmd == 'Z' or cmd == 'z':
            continue
        if len(pts) >= 2:
            cx, cy = pts[-2], pts[-1]
        segs.append((cmd.lower(), pts))
    return segs


def _path_to_polygon(d, steps=10):
    """把 SVG path 采样成闭合 polygon 点列。"""
    segs = _parse_svg_path_commands(d)
    points = []
    cx, cy = 0.0, 0.0
    first = None
    for cmd, pts in segs:
        if cmd == 'm':
            if points:
                cx += pts[0]; cy += pts[1]
            else:
                cx, cy = pts[0], pts[1]
                first = (cx, cy)
            points.append((cx, cy))
        elif cmd == 'l':
            cx += pts[0]; cy += pts[1]
            points.append((cx, cy))
        elif cmd == 'c':
            bez = [(cx, cy)] + [(pts[i], pts[i + 1]) for i in range(0, 6, 2)]
            for p in _sample_bezier(bez, steps):
                points.append(p)
            cx, cy = pts[4], pts[5]
        elif cmd == 'z':
            if first:
                points.append(first)
    return points


# ============================================================
# 绘制脚印（直接在 supersample 合成画板上用变换矩阵）
# ============================================================

def _fp0_to_canvas(dot_x, dot_y, s=SUPERSAMPLE):
    """返回 fp0 局部坐标 → 合成画板 supersample 坐标的变换函数。

    变换链（和 SVG 版完全一致）：
      fp0 → translate(-center) → rotate(+14°) → scale(FP_SCALE) → translate(dot_x, dot_y) → ×s

    注意：PIL y 轴向下，rotate 用 +14°（逆时针），
          但数学上 rotate(-θ) = rotate(+180-θ)...
          让我用和 SVG 完全相同的变换顺序。
    SVG 变换：translate(dot) rotate(+14) scale(FP_SCALE) translate(-center)
    → 对 fp0 点 p 先 translate(-center) 变成 p-c
    → 然后 scale(FP_SCALE)
    → 然后 rotate(+14°)
    → 然后 translate(dot)

    数学顺序：T(dot) · R(+14°) · S(FP_SCALE) · T(-center) · p
    """
    s2 = math.sin(math.radians(FP_ROTATE_DEG))
    c2 = math.cos(math.radians(FP_ROTATE_DEG))
    cx, cy = FP_CENTER

    def transform(fx, fy):
        dx = fx - cx
        dy = fy - cy
        # scale
        sx = dx * FP_SCALE
        sy = dy * FP_SCALE
        # rotate +14°（SVG 坐标 y 向下，所以用 +sin/cos）
        rx = sx * c2 - sy * s2
        ry = sx * s2 + sy * c2
        # translate + supersample
        return (rx + dot_x) * s, (ry + dot_y) * s

    return transform


def _draw_footprint_on_mask(fp_mask, dot_x, dot_y, s=SUPERSAMPLE):
    """在 supersample 合成画板上直接绘制脚印多边形。"""
    transform = _fp0_to_canvas(dot_x, dot_y, s)
    d = ImageDraw.Draw(fp_mask)

    # 三趾 ellipse → polygon（采样 48 点 + 趾内自旋转）
    for cxi, cyi, rxi, ryi, toe_rot in FP_TOES:
        c_sin = math.sin(math.radians(toe_rot))
        c_cos = math.cos(math.radians(toe_rot))
        pts = []
        for i in range(48):
            a = 2 * math.pi * i / 48
            ex = cxi + rxi * math.cos(a)
            ey = cyi + ryi * math.sin(a)
            # 趾内自转
            rdx = ex - cxi; rdy = ey - cyi
            rx = rdx * c_cos - rdy * c_sin
            ry = rdx * c_sin + rdy * c_cos
            cx, cy = transform(cxi + rx, cyi + ry)
            pts.append((cx, cy))
        if len(pts) >= 3:
            d.polygon(pts, fill=255)

    # 掌形 polygon
    palm_pts = _palm_polygon_fp0()
    palm_canvas = [transform(p[0], p[1]) for p in palm_pts]
    if len(palm_canvas) >= 3:
        d.polygon(palm_canvas, fill=255)


def _palm_polygon_fp0():
    """手工采样 fp0 掌形 path 成 polygon。

    Path: M37 57 C37 50.5 44.5 48.5 54 48.5 S71 50.5 71 57
          C71 62.5 67.5 66.5 64 72 C60.5 78 59.5 84 54 84
          S47.5 78 44 72 C40.5 66.5 37 62.5 37 57 Z
    手工采样控制点近似贝塞尔曲线。
    """
    pts = []
    # 第一段: M37 57 → C37 50.5 44.5 48.5 54 48.5
    pts.append((37, 57))
    pts.extend(_sample_bezier(
        [(37, 57), (37, 50.5), (44.5, 48.5), (54, 48.5)], steps=12))
    # 第二段: S71 50.5 71 57 → C54+2*(54-44.5), 48.5+2*(48.5-48.5) = C63.5 48.5 71 50.5 71 57
    pts.extend(_sample_bezier(
        [(54, 48.5), (63.5, 48.5), (71, 50.5), (71, 57)], steps=12))
    # 第三段: C71 62.5 67.5 66.5 64 72
    pts.extend(_sample_bezier(
        [(71, 57), (71, 62.5), (67.5, 66.5), (64, 72)], steps=12))
    # 第四段: C60.5 78 59.5 84 54 84
    pts.extend(_sample_bezier(
        [(64, 72), (60.5, 78), (59.5, 84), (54, 84)], steps=12))
    # 第五段: S47.5 78 44 72 → C54-2*(54-59.5), 84+2*(84-84) = C48.5 84 47.5 78 44 72
    pts.extend(_sample_bezier(
        [(54, 84), (48.5, 84), (47.5, 78), (44, 72)], steps=12))
    # 第六段: C40.5 66.5 37 62.5 37 57 Z
    pts.extend(_sample_bezier(
        [(44, 72), (40.5, 66.5), (37, 62.5), (37, 57)], steps=12))
    pts.append((37, 57))  # 闭合
    return pts


# ============================================================
# 膨胀（与原脚本一致）
# ============================================================

def dilate(mask, px):
    left = px
    while left > 0:
        step = 3 if left >= 3 else 1
        mask = mask.filter(ImageFilter.MaxFilter(step * 2 + 1))
        left -= step
    return mask


# ============================================================
# 核心：构建「找字 + 脚印点」合成图形
# ============================================================

def build_art():
    """构建 1024 透明底的白色图形（黄油体找字 + 脚印作点）。"""
    s = SUPERSAMPLE
    size = CANVAS * s

    font = ImageFont.truetype(FONT, int(TEXT_SIZE * s))
    text_layer = Image.new("L", (size, size), 0)
    ImageDraw.Draw(text_layer).text(
        (TEXT_CENTER[0] * s, TEXT_CENTER[1] * s), "找",
        font=font, fill=255, anchor="mm")

    if SQUASH != 1.0:
        new_h = max(1, int(size * SQUASH))
        squeezed = text_layer.resize((size, new_h), Image.LANCZOS)
        text_layer = Image.new("L", (size, size), 0)
        text_layer.paste(squeezed, (0, int(TEXT_CENTER[1] * s - new_h / 2)))

    mask = text_layer
    text_bbox = text_layer.getbbox()

    dot_x = TEXT_CENTER[0] + DOT_REL[0] * TEXT_SIZE + FP_DOT_OFFSET_X
    dot_y = TEXT_CENTER[1] + DOT_REL[1] * TEXT_SIZE * SQUASH + FP_DOT_OFFSET_Y

    # 脚印掩膜（局部画布→rotate→scale→paste）
    fp_mask = Image.new("L", (size, size), 0)
    _draw_footprint_on_mask(fp_mask, dot_x, dot_y, s)

    # 隔离带（和原鸭头脚本一样膨胀 GAP 像素）
    inflated = dilate(fp_mask, int(GAP * s))
    mask.paste(0, (0, 0), inflated)      # 隔离带挖空（找字层不含脚印）

    # 居中（和原脚本一致：以字的 bbox 为基准平移；两层共用同一平移）
    centered_text = Image.new("L", (size, size), 0)
    centered_fp = Image.new("L", (size, size), 0)
    if text_bbox:
        dx = (size - (text_bbox[2] - text_bbox[0])) // 2 - text_bbox[0] + int(X_OFFSET * s)
        dy = (size - (text_bbox[3] - text_bbox[1])) // 2 - text_bbox[1]
        centered_text.paste(mask, (dx, dy))
        centered_fp.paste(fp_mask, (dx, dy))

    centered_text = centered_text.resize((CANVAS, CANVAS), Image.LANCZOS)
    centered_fp = centered_fp.resize((CANVAS, CANVAS), Image.LANCZOS)
    art = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    art = Image.composite(Image.new("RGBA", (CANVAS, CANVAS), WHITE + (255,)),
                          art, centered_text)
    art = Image.composite(Image.new("RGBA", (CANVAS, CANVAS), FP_COLOR + (255,)),
                          art, centered_fp)
    return art


# —— 以下辅助函数与原脚本完全一致 ——

def rounded_mask(size, radius_ratio=CORNER_RATIO):
    s = SUPERSAMPLE
    big = size * s
    m = Image.new("L", (big, big), 0)
    ImageDraw.Draw(m).rounded_rectangle(
        [0, 0, big - 1, big - 1], radius=int(big * radius_ratio), fill=255)
    return m.resize((size, size), Image.LANCZOS)


def legacy_icon(art, size):
    base = Image.new("RGB", (CANVAS, CANVAS), BRAND)
    base.paste(art, (0, 0), art)
    base = base.resize((size, size), Image.LANCZOS)
    out = Image.new("RGB", (size, size), BRAND)
    out.paste(base, (0, 0), rounded_mask(size))
    return out


def foreground_layer(art, size):
    bbox = art.getbbox()
    cropped = art.crop(bbox) if bbox else art
    inner = int(CANVAS * ADAPTIVE_SAFE)
    ratio = min(inner / cropped.width, inner / cropped.height)
    target = (max(1, int(cropped.width * ratio)), max(1, int(cropped.height * ratio)))
    scaled = cropped.resize(target, Image.LANCZOS)
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    offset = ((CANVAS - target[0]) // 2, (CANVAS - target[1]) // 2)
    canvas.paste(scaled, offset, scaled)
    return canvas.resize((size, size), Image.LANCZOS)


# ============================================================
# 入口
# ============================================================

def main():
    print("[1] 构建艺术层：黄油体找字 + 脚印作点")
    art = build_art()
    art_path = os.path.join(HERE, "_art_foonote.png")
    art.save(art_path, "PNG")
    print(f"    合成图形已导出: {art_path}")

    print("[2] 生成各密度 Android 图标")
    for density, legacy_size, fg_size in DENSITIES:
        folder = os.path.join(RES, f"mipmap-{density}")
        os.makedirs(folder, exist_ok=True)
        legacy_icon(art, legacy_size).save(os.path.join(folder, "ic_launcher.png"))
        foreground_layer(art, fg_size).save(os.path.join(folder, "ic_launcher_foreground.png"))
        print(f"    {density}: legacy {legacy_size}×{legacy_size}  fg {fg_size}×{fg_size}")

    # adaptive 描述
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

    # 预览图
    fg = foreground_layer(art, CANVAS)
    composed = Image.new("RGB", (CANVAS, CANVAS), BRAND)
    composed.paste(fg, (0, 0), fg)
    legacy_icon(art, 512).save(os.path.join(HERE, "preview-legacy-foonote.png"))
    print("\n✅ Android 桌面图标全部重新生成！")
    print(f"   合成图形: {art_path}")
    print(f"   Legacy 预览: {os.path.join(HERE, 'preview-legacy-foonote.png')}")


if __name__ == "__main__":
    main()
