# -*- coding: utf-8 -*-
"""生成「找」字嵌进放大鸭头内部的图标候选图。

用途：
    把 4B 定稿的鸭头轮廓放大作为底形，将「找」字以负形（主色）放进鸭头内部，
    输出若干候选位图供评审，并同时导出 Android 各密度资源。

依赖：
    Pillow（已安装 12.3.0）、Windows 自带微软雅黑（msyhbd.ttc）。
"""

import os
import re
from PIL import Image, ImageDraw, ImageFont

BRAND = (0x0B, 0x7C, 0x8C)
WHITE = (0xFF, 0xFF, 0xFF)
BRAND_DARK = (0x07, 0x5E, 0x6B)

# 4B 定稿鸭头路径（1024 画板，来自 prototype-figma/assets/source/ip-4b-duckhead-native.svg）
DUCK_HEAD_PATH = (
    "M418 388 C405.83 392.5 397.5 398.17 389 404 "
    "C380.5 409.83 373.83 415.67 367 423 "
    "C360.17 430.33 353.17 439.67 348 448 "
    "C342.83 456.33 339.33 459.67 336 473 "
    "C332.67 486.33 327.17 509.67 328 528 "
    "C328.83 546.33 333.67 565.83 341 583 "
    "C348.33 600.17 359.33 617 372 631 "
    "C384.67 645 399.67 657.33 417 667 "
    "C434.33 676.67 457.5 684.83 476 689 "
    "C494.5 693.17 515.67 692.17 528 692 "
    "C540.33 691.83 545.17 689.83 550 688 "
    "C554.83 686.17 554.67 683.33 557 681 "
    "C556.67 678.67 560.33 681.5 556 674 "
    "C551.67 666.5 536.33 645.83 531 636 "
    "C525.67 626.17 525 621.5 524 615 "
    "C523 608.5 523.33 603.17 525 597 "
    "C526.67 590.83 528.67 584 534 578 "
    "C539.33 572 543.17 565.67 557 561 "
    "C570.83 556.33 600.5 554.5 617 550 "
    "C633.5 545.5 645.33 540.17 656 534 "
    "C666.67 527.83 675.17 519 681 513 "
    "C686.83 507 689 502.5 691 498 "
    "C693 493.5 692.33 490 693 486 "
    "C689.67 483.67 691.5 480.17 683 479 "
    "C674.5 477.83 654.5 480.67 642 479 "
    "C629.5 477.33 616.67 473.17 608 469 "
    "C599.33 464.83 595.67 461.5 590 454 "
    "C584.33 446.5 579.33 432.17 574 424 "
    "C568.67 415.83 566.67 411.67 558 405 "
    "C549.33 398.33 533.17 388.67 522 384 "
    "C510.83 379.33 501 378.17 491 377 "
    "C481 375.83 474.17 375.17 462 377 "
    "C449.83 378.83 430.17 383.5 418 388 Z"
)

FONT_PATH = r"C:\Windows\Fonts\msyhbd.ttc"
SUPERSAMPLE = 4


def cubic_points(p0, p1, p2, p3, steps=18):
    """采样一条三次贝塞尔曲线，返回中间点列表（不含起点）。

    参数：
        p0/p1/p2/p3: 起点、两个控制点、终点，均为 (x, y) 元组
        steps: 采样段数，越大越平滑
    返回：
        [(x, y), ...] 曲线上的采样点
    """
    pts = []
    for i in range(1, steps + 1):
        t = i / steps
        u = 1 - t
        x = u**3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t**3 * p3[0]
        y = u**3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t**3 * p3[1]
        pts.append((x, y))
    return pts


def path_to_polygon(d):
    """把只含 M / C / Z 的 SVG path 转成闭合多边形点集。

    参数：
        d: SVG path 字符串
    返回：
        [(x, y), ...] 多边形顶点
    """
    tokens = re.findall(r"[MCZ]|-?\d+\.?\d*", d)
    pts = []
    cur = (0.0, 0.0)
    start = (0.0, 0.0)
    i = 0
    cmd = None
    while i < len(tokens):
        tok = tokens[i]
        if tok in ("M", "C", "Z"):
            cmd = tok
            i += 1
            continue
        if cmd == "M":
            cur = (float(tokens[i]), float(tokens[i + 1]))
            start = cur
            pts.append(cur)
            i += 2
            cmd = "L"
        elif cmd == "C":
            p1 = (float(tokens[i]), float(tokens[i + 1]))
            p2 = (float(tokens[i + 2]), float(tokens[i + 3]))
            p3 = (float(tokens[i + 4]), float(tokens[i + 5]))
            pts.extend(cubic_points(cur, p1, p2, p3))
            cur = p3
            i += 6
        elif cmd == "Z":
            i += 1
        else:
            i += 1
    return pts


def transform(points, scale, center, target):
    """把点集按缩放 + 平移变换到目标画板。

    参数：
        points: 原始点集
        scale: 缩放倍数
        center: 原始中心 (x, y)
        target: 变换后中心 (x, y)
    返回：
        变换后的点集
    """
    cx, cy = center
    tx, ty = target
    return [((x - cx) * scale + tx, (y - cy) * scale + ty) for x, y in points]


def point_in_polygon(x, y, poly):
    """判断点是否落在多边形内部（射线法）。

    参数：
        x: 点横坐标
        y: 点纵坐标
        poly: 多边形顶点列表
    返回：
        bool，True 表示在内部
    """
    inside = False
    n = len(poly)
    j = n - 1
    for i in range(n):
        xi, yi = poly[i]
        xj, yj = poly[j]
        if (yi > y) != (yj > y):
            xin = (xj - xi) * (y - yi) / (yj - yi) + xi
            if x < xin:
                inside = not inside
        j = i
    return inside


def dist_to_polygon(x, y, poly):
    """计算点到多边形边界的最短距离。

    参数：
        x: 点横坐标
        y: 点纵坐标
        poly: 多边形顶点列表
    返回：
        float，最短距离
    """
    best = 1e18
    n = len(poly)
    for i in range(n):
        x1, y1 = poly[i]
        x2, y2 = poly[(i + 1) % n]
        dx, dy = x2 - x1, y2 - y1
        seg2 = dx * dx + dy * dy
        if seg2 == 0:
            t = 0.0
        else:
            t = ((x - x1) * dx + (y - y1) * dy) / seg2
            t = max(0.0, min(1.0, t))
        px, py = x1 + t * dx, y1 + t * dy
        d = ((x - px) ** 2 + (y - py) ** 2) ** 0.5
        if d < best:
            best = d
    return best


def find_inscribed_square(poly, grid=150):
    """在鸭头内部找能容纳的最大正方形（以半边长度量）。

    参数：
        poly: 已变换到目标画板的鸭头多边形
        grid: 采样网格密度
    返回：
        (cx, cy, half)，中心坐标与可容纳正方形的半边长
    """
    xs = [p[0] for p in poly]
    ys = [p[1] for p in poly]
    x0, x1 = min(xs), max(xs)
    y0, y1 = min(ys), max(ys)
    best = (0.0, 0.0, 0.0)
    for i in range(grid):
        for j in range(grid):
            px = x0 + (x1 - x0) * (i + 0.5) / grid
            py = y0 + (y1 - y0) * (j + 0.5) / grid
            if not point_in_polygon(px, py, poly):
                continue
            d = dist_to_polygon(px, py, poly)
            if d > best[2]:
                best = (px, py, d)
    return best


def draw_variant(duck_poly, text_size, text_center, invert=False, ring=None, dark_shadow=0,
                 font_path=FONT_PATH):
    """渲染一个 1024 画板候选图。

    参数：
        duck_poly: 已变换到 1024 画板的鸭头多边形
        text_size: 「找」字字号
        text_center: 字中心 (x, y)
        invert: True 时白底 + 主色鸭头 + 白色字
        ring: 可选，(cx, cy, r, width) 白色圆环
        dark_shadow: 深色错位量，0 表示不加
        font_path: 字体文件路径
    返回：
        PIL.Image，尺寸 1024x1024
    """
    s = SUPERSAMPLE
    size = 1024 * s
    bg = WHITE if invert else BRAND
    duck_color = BRAND if invert else WHITE
    text_color = WHITE if invert else BRAND

    img = Image.new("RGB", (size, size), bg)
    draw = ImageDraw.Draw(img)

    if ring:
        cx, cy, r, w = ring
        draw.ellipse(
            [(cx - r) * s, (cy - r) * s, (cx + r) * s, (cy + r) * s],
            outline=duck_color,
            width=int(w * s),
        )

    poly = [(x * s, y * s) for x, y in duck_poly]
    draw.polygon(poly, fill=duck_color)

    font = ImageFont.truetype(font_path, int(text_size * s))
    tx, ty = text_center[0] * s, text_center[1] * s

    if dark_shadow:
        shadow_color = BRAND_DARK if not invert else (0xD5, 0xEC, 0xEF)
        draw.text((tx + dark_shadow * s, ty + dark_shadow * s), "找", font=font, fill=shadow_color, anchor="mm")

    draw.text((tx, ty), "找", font=font, fill=text_color, anchor="mm")

    return img.resize((1024, 1024), Image.LANCZOS)


def main():
    """生成候选图：先按内接方形定位「找」字，再渲染并导出对比图。

    参数：无
    返回：None
    """
    out_dir = os.path.dirname(os.path.abspath(__file__))
    raw = path_to_polygon(DUCK_HEAD_PATH)
    xs = [p[0] for p in raw]
    ys = [p[1] for p in raw]
    center = ((min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2)

    # 名称, 鸭头缩放, 鸭头中心, 字占内接方形的比例, 是否反相, 字体文件
    variants = [
        ("A", 2.60, (512, 518), 0.58, False, r"C:\Windows\Fonts\msyhbd.ttc"),
        ("B", 2.60, (512, 518), 0.70, False, r"C:\Windows\Fonts\msyhbd.ttc"),
        ("C", 2.60, (512, 518), 0.82, False, r"C:\Windows\Fonts\msyhbd.ttc"),
        ("D", 2.60, (512, 518), 0.70, True, r"C:\Windows\Fonts\msyhbd.ttc"),
    ]

    for name, scale, dcenter, ratio, invert, font_path in variants:
        poly = transform(raw, scale, center, dcenter)
        cx, cy, half = find_inscribed_square(poly)
        text_size = 2 * half * ratio
        img = draw_variant(poly, text_size, (cx, cy), font_path=font_path, invert=invert)
        img.save(os.path.join(out_dir, f"zhao-duck-{name}.png"))
        small = img.resize((24, 24), Image.LANCZOS).resize((240, 240), Image.NEAREST)
        small.save(os.path.join(out_dir, f"zhao-duck-{name}-24px.png"))
        print(name, "center", round(cx, 1), round(cy, 1), "half", round(half, 1), "font", round(text_size, 1))

    # 拼一张对比图，便于一眼比较
    tiles = []
    for name, *_ in variants:
        im = Image.open(os.path.join(out_dir, f"zhao-duck-{name}.png")).resize((320, 320), Image.LANCZOS)
        tiles.append(im)
    sheet = Image.new("RGB", (320 * 4 + 40 * 5, 360), (0xF7, 0xF7, 0xF8))
    for i, im in enumerate(tiles):
        sheet.paste(im, (40 + i * 360, 20))
    sheet.save(os.path.join(out_dir, "zhao-duck-compare.png"))
    print("done")


if __name__ == "__main__":
    main()
