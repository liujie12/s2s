"""把生成的 SVG 渲染为位图并与源图做像素级比对。

上一轮的失败教训：只验证了 SVG 语法、路径数量、与另一份副本的一致性，
却从未验证「渲染出来像不像鸭子」。本脚本因此做两件事：
1. 把 SVG 渲染成 PNG，供肉眼查看；
2. 与源图做 IoU（交并比）比对，用数字度量形状吻合程度。

渲染不引入新依赖：SVG 里只有 rect / circle / path(M,C,A,Z)，用自己实现的
光栅化器绘制——A 弧转为多段折线，C 曲线按 de Casteljau 细分，最后用扫描线
填充并按 evenodd 规则判定内外。
"""

import math
import os
import re
import sys

import cv2
import numpy as np

ASSETS = r"d:\developer\code\aicoding\s2s\prototype-figma\assets"
SOURCE = r"d:\developer\code\aicoding\s2s\prototype-figma\assets\source\ip-4b-source.png"
OUT_DIR = r"d:\developer\code\aicoding\s2s\prototype-figma\assets\render"


def flatten_cubic(p0, p1, p2, p3, steps=24):
    """把三次贝塞尔曲线细分为折线点列。

    :param p0: 起点 (x, y)
    :param p1: 第一控制点
    :param p2: 第二控制点
    :param p3: 终点
    :param steps: 细分段数，越大越平滑
    :return: 不含起点的点列表
    """
    pts = []
    for i in range(1, steps + 1):
        t = i / steps
        u = 1 - t
        x = (u ** 3 * p0[0] + 3 * u * u * t * p1[0]
             + 3 * u * t * t * p2[0] + t ** 3 * p3[0])
        y = (u ** 3 * p0[1] + 3 * u * u * t * p1[1]
             + 3 * u * t * t * p2[1] + t ** 3 * p3[1])
        pts.append((x, y))
    return pts


def flatten_arc(p0, rx, ry, large_arc, sweep, p1, steps=48):
    """把 SVG 的 A 弧命令转换为折线点列。

    实现 SVG 规范的端点参数化到圆心参数化换算（此处只用到 rx==ry 且
    x_axis_rotation==0 的圆弧，因此省略旋转项）。

    :param p0: 起点
    :param rx: x 半径
    :param ry: y 半径
    :param large_arc: 大弧标志
    :param sweep: 方向标志
    :param p1: 终点
    :param steps: 细分段数
    :return: 不含起点的点列表
    """
    x1, y1 = p0
    x2, y2 = p1
    if abs(x1 - x2) < 1e-9 and abs(y1 - y2) < 1e-9:
        return []

    dx2 = (x1 - x2) / 2.0
    dy2 = (y1 - y2) / 2.0
    # 半径过小时按规范等比放大到刚好容纳弦长
    lam = (dx2 * dx2) / (rx * rx) + (dy2 * dy2) / (ry * ry)
    if lam > 1:
        scale = math.sqrt(lam)
        rx *= scale
        ry *= scale

    num = rx * rx * ry * ry - rx * rx * dy2 * dy2 - ry * ry * dx2 * dx2
    den = rx * rx * dy2 * dy2 + ry * ry * dx2 * dx2
    coef = math.sqrt(max(0.0, num / den))
    if large_arc == sweep:
        coef = -coef
    cxp = coef * rx * dy2 / ry
    cyp = -coef * ry * dx2 / rx
    cx = cxp + (x1 + x2) / 2.0
    cy = cyp + (y1 + y2) / 2.0

    def angle(ux, uy, vx, vy):
        """求两向量夹角（带符号）。"""
        dot = ux * vx + uy * vy
        n = math.hypot(ux, uy) * math.hypot(vx, vy)
        a = math.acos(max(-1.0, min(1.0, dot / n)))
        return -a if (ux * vy - uy * vx) < 0 else a

    theta1 = angle(1, 0, (dx2 - cxp) / rx, (dy2 - cyp) / ry)
    dtheta = angle((dx2 - cxp) / rx, (dy2 - cyp) / ry,
                   (-dx2 - cxp) / rx, (-dy2 - cyp) / ry)
    if not sweep and dtheta > 0:
        dtheta -= 2 * math.pi
    elif sweep and dtheta < 0:
        dtheta += 2 * math.pi

    pts = []
    for i in range(1, steps + 1):
        t = theta1 + dtheta * i / steps
        pts.append((cx + rx * math.cos(t), cy + ry * math.sin(t)))
    return pts


TOKEN = re.compile(r"([MmCcAaZzLlHhVvQqTtSs])|(-?\d+\.?\d*(?:[eE][-+]?\d+)?)")


def flatten_quad(p0, p1, p2, steps=16):
    """把二次贝塞尔细分为折线点（不含起点）。

    :param p0: 起点
    :param p1: 控制点
    :param p2: 终点
    :param steps: 细分段数
    :return: [(x, y), ...]
    """
    pts = []
    for i in range(1, steps + 1):
        t = i / steps
        u = 1.0 - t
        pts.append((
            u * u * p0[0] + 2 * u * t * p1[0] + t * t * p2[0],
            u * u * p0[1] + 2 * u * t * p1[1] + t * t * p2[1],
        ))
    return pts


def parse_path(d):
    """把 path 的 d 属性解析为多条闭合折线（子路径）。

    支持 M/L/H/V/C/S/Q/T/A/Z 及其相对形式（小写）。相对指令与
    H/V/Q 是 Material Symbols 图标的常用写法，缺了它们会把指令字母
    当坐标读，静默产出乱形——故这里按 SVG 规范完整实现，不做子集。

    :param d: d 属性字符串
    :return: 子路径列表，每条是 [(x, y), ...]
    """
    tokens = []
    for m in TOKEN.finditer(d):
        tokens.append(m.group(1) if m.group(1) else float(m.group(2)))

    subpaths = []
    current = []
    cursor = (0.0, 0.0)
    start = (0.0, 0.0)
    # 上一段曲线的控制点，供 S/T 的平滑续接使用
    prev_cubic_c2 = None
    prev_quad_c = None
    i = 0
    cmd = None

    def flush():
        """把当前累积的折线收进结果（少于 3 点的退化子路径丢弃）。"""
        if len(current) >= 3:
            subpaths.append(list(current))

    while i < len(tokens):
        tok = tokens[i]
        if isinstance(tok, str):
            cmd = tok
            i += 1
            if cmd in "Zz":
                flush()
                current = []
                cursor = start
                prev_cubic_c2 = prev_quad_c = None
                continue
            if i >= len(tokens):
                break

        rel = cmd.islower()
        bx, by = cursor if rel else (0.0, 0.0)
        up = cmd.upper()

        if up == "M":
            x, y = bx + tokens[i], by + tokens[i + 1]
            i += 2
            flush()
            cursor = start = (x, y)
            current = [cursor]
            # 规范：M 之后的重复坐标对按 L 处理
            cmd = "l" if rel else "L"
            prev_cubic_c2 = prev_quad_c = None
        elif up == "L":
            cursor = (bx + tokens[i], by + tokens[i + 1])
            i += 2
            current.append(cursor)
            prev_cubic_c2 = prev_quad_c = None
        elif up == "H":
            cursor = (bx + tokens[i], cursor[1])
            i += 1
            current.append(cursor)
            prev_cubic_c2 = prev_quad_c = None
        elif up == "V":
            cursor = (cursor[0], by + tokens[i])
            i += 1
            current.append(cursor)
            prev_cubic_c2 = prev_quad_c = None
        elif up == "C":
            c1 = (bx + tokens[i], by + tokens[i + 1])
            c2 = (bx + tokens[i + 2], by + tokens[i + 3])
            end = (bx + tokens[i + 4], by + tokens[i + 5])
            i += 6
            current.extend(flatten_cubic(cursor, c1, c2, end))
            cursor, prev_cubic_c2, prev_quad_c = end, c2, None
        elif up == "S":
            # 第一控制点 = 上一段第二控制点对当前点的镜像
            c1 = cursor if prev_cubic_c2 is None else (
                2 * cursor[0] - prev_cubic_c2[0], 2 * cursor[1] - prev_cubic_c2[1])
            c2 = (bx + tokens[i], by + tokens[i + 1])
            end = (bx + tokens[i + 2], by + tokens[i + 3])
            i += 4
            current.extend(flatten_cubic(cursor, c1, c2, end))
            cursor, prev_cubic_c2, prev_quad_c = end, c2, None
        elif up == "Q":
            c = (bx + tokens[i], by + tokens[i + 1])
            end = (bx + tokens[i + 2], by + tokens[i + 3])
            i += 4
            current.extend(flatten_quad(cursor, c, end))
            cursor, prev_quad_c, prev_cubic_c2 = end, c, None
        elif up == "T":
            c = cursor if prev_quad_c is None else (
                2 * cursor[0] - prev_quad_c[0], 2 * cursor[1] - prev_quad_c[1])
            end = (bx + tokens[i], by + tokens[i + 1])
            i += 2
            current.extend(flatten_quad(cursor, c, end))
            cursor, prev_quad_c, prev_cubic_c2 = end, c, None
        elif up == "A":
            rx, ry = tokens[i], tokens[i + 1]
            large = int(tokens[i + 3])
            sweep = int(tokens[i + 4])
            end = (bx + tokens[i + 5], by + tokens[i + 6])
            i += 7
            current.extend(flatten_arc(cursor, rx, ry, large, sweep, end))
            cursor = end
            prev_cubic_c2 = prev_quad_c = None
        else:
            i += 1

    flush()
    return subpaths


def render_svg(svg_text, size):
    """把 SVG 文本渲染为 BGR 位图。

    只支持本项目素材用到的 rect / circle / path、fill / fill-rule / rx，
    以及 <g transform="translate(x y)"> 分组平移，足以验证生成结果，
    不追求通用性。非方形 viewBox 按长边归一化到 size，短边等比缩放，
    因此横版 / 竖版 logo 与启动页不会被拉伸或错位。

    :param svg_text: SVG 全文
    :param size: 输出位图长边像素
    :return: BGR ndarray，形状为 (round(vh*k), round(vw*k), 3)
    """
    vb = re.search(r'viewBox="0 0 (\d+\.?\d*) (\d+\.?\d*)"', svg_text)
    vw, vh = float(vb.group(1)), float(vb.group(2))
    k = size / max(vw, vh)
    out_w, out_h = int(round(vw * k)), int(round(vh * k))
    canvas = np.full((out_h, out_w, 3), 255, dtype=np.uint8)

    def to_bgr(hex_color):
        """#RRGGBB -> BGR 元组。"""
        h = hex_color.lstrip("#")
        return (int(h[4:6], 16), int(h[2:4], 16), int(h[0:2], 16))

    def num(attrs, key, default=0.0):
        """从属性串里取数值属性，缺省返回 default。"""
        m = re.search(r'\b%s="(-?\d+\.?\d*)"' % key, attrs)
        return float(m.group(1)) if m else default

    # 分组平移栈：<g transform="translate(x y)"> 入栈，</g> 出栈
    stack = [(0.0, 0.0)]

    # 按文档顺序遍历图元与分组标签，后画的覆盖先画的
    pattern = r"<(g|rect|circle|path)\b([^>]*?)(/?)>|</g>"
    for m in re.finditer(pattern, svg_text):
        if m.group(0) == "</g>":
            if len(stack) > 1:
                stack.pop()
            continue

        tag, attrs, selfclose = m.group(1), m.group(2), m.group(3)
        if tag == "g":
            t = re.search(r"translate\(\s*(-?\d+\.?\d*)[ ,]+(-?\d+\.?\d*)", attrs)
            dx, dy = (float(t.group(1)), float(t.group(2))) if t else (0.0, 0.0)
            ox, oy = stack[-1]
            stack.append((ox + dx, oy + dy))
            if selfclose:  # <g .../> 空组，立即出栈
                stack.pop()
            continue

        ox, oy = stack[-1]
        fill = re.search(r'fill="([^"]+)"', attrs)
        color = to_bgr(fill.group(1)) if fill else (0, 0, 0)

        if tag == "rect":
            x0 = (num(attrs, "x") + ox) * k
            y0 = (num(attrs, "y") + oy) * k
            w = num(attrs, "width") * k
            h = num(attrs, "height") * k
            rx_m = re.search(r'\brx="(-?\d+\.?\d*)"', attrs)
            if rx_m:
                r = float(rx_m.group(1)) * k
                # 圆角矩形：两个十字交叠矩形 + 四个角的圆
                cv2.rectangle(canvas, (int(x0 + r), int(y0)),
                              (int(x0 + w - r), int(y0 + h)), color, -1)
                cv2.rectangle(canvas, (int(x0), int(y0 + r)),
                              (int(x0 + w), int(y0 + h - r)), color, -1)
                for cxr, cyr in [(x0 + r, y0 + r), (x0 + w - r, y0 + r),
                                 (x0 + r, y0 + h - r), (x0 + w - r, y0 + h - r)]:
                    cv2.circle(canvas, (int(cxr), int(cyr)), int(r), color, -1)
            else:
                cv2.rectangle(canvas, (int(x0), int(y0)),
                              (int(x0 + w), int(y0 + h)), color, -1)

        elif tag == "circle":
            cx = (num(attrs, "cx") + ox) * k
            cy = (num(attrs, "cy") + oy) * k
            r = num(attrs, "r") * k
            cv2.circle(canvas, (int(round(cx)), int(round(cy))),
                       int(round(r)), color, -1, lineType=cv2.LINE_AA)

        else:
            d = re.search(r'd="([^"]+)"', attrs).group(1)
            subs = parse_path(d)
            # evenodd：把所有子路径一起交给 fillPoly，OpenCV 对重叠区按
            # 奇偶规则处理，正是所需语义
            polys = [np.array([[int(round((x + ox) * k)), int(round((y + oy) * k))]
                               for x, y in sub], dtype=np.int32) for sub in subs]
            layer = np.zeros((out_h, out_w), dtype=np.uint8)
            cv2.fillPoly(layer, polys, 255, lineType=cv2.LINE_AA)
            canvas[layer > 127] = color

    return canvas


def iou(mask_a, mask_b):
    """计算两个二值掩膜的交并比。"""
    inter = np.logical_and(mask_a, mask_b).sum()
    union = np.logical_or(mask_a, mask_b).sum()
    return inter / union if union else 0.0


if __name__ == "__main__":
    os.makedirs(OUT_DIR, exist_ok=True)
    files = [
        "duck-symbol-full.svg",
        "duck-symbol-compact.svg",
        "duck-symbol-mini.svg",
        "duck-symbol-inverse.svg",
        "duck-symbol-mono.svg",
        "app-icon-ios.svg",
    ]

    rendered = {}
    for name in files:
        with open(os.path.join(ASSETS, name), encoding="utf-8") as fh:
            svg = fh.read()
        img = render_svg(svg, 512)
        out = os.path.join(OUT_DIR, name.replace(".svg", ".png"))
        cv2.imwrite(out, img)
        rendered[name] = img
        print(f"rendered {name} -> {os.path.basename(out)}")

    # --- 与源图做 IoU 比对：比「白色部分」的形状 ---
    src = cv2.imread(SOURCE)
    src = cv2.resize(src, (512, 512), interpolation=cv2.INTER_AREA)
    src_gray = cv2.cvtColor(src, cv2.COLOR_BGR2GRAY)
    src_white = src_gray > 199

    full = rendered["duck-symbol-full.svg"]
    full_gray = cv2.cvtColor(full, cv2.COLOR_BGR2GRAY)
    full_white = full_gray > 199

    score = iou(src_white, full_white)
    print(f"\nIoU(full vs source, white regions) = {score:.4f}")

    # 只比中心区域（排除源图四角黑边的影响）
    mask_center = np.zeros((512, 512), dtype=bool)
    cv2.circle(mask_center.view(np.uint8), (256, 253), 205, 1, -1)
    mask_center = mask_center.view(np.uint8).astype(bool)
    score_center = iou(src_white & mask_center, full_white & mask_center)
    print(f"IoU(center disc region only)         = {score_center:.4f}")

    # 差异图：红=源图有我没有，绿=我有源图没有
    diff = np.zeros((512, 512, 3), dtype=np.uint8)
    diff[src_white & ~full_white] = (0, 0, 255)
    diff[full_white & ~src_white] = (0, 255, 0)
    diff[src_white & full_white] = (90, 90, 90)
    cv2.imwrite(os.path.join(OUT_DIR, "diff-vs-source.png"), diff)
    print("diff map -> diff-vs-source.png (red=missing, green=extra, gray=match)")

    # 小尺寸压测：mini 档在 24px 下鸭头是否还看得出
    mini = rendered["duck-symbol-mini.svg"]
    for px in [96, 40, 24]:
        small = cv2.resize(mini, (px, px), interpolation=cv2.INTER_AREA)
        big = cv2.resize(small, (px * 8, px * 8), interpolation=cv2.INTER_NEAREST)
        cv2.imwrite(os.path.join(OUT_DIR, f"mini-at-{px}px.png"), big)
    print("small-size stress: mini-at-96px.png / mini-at-40px.png / mini-at-24px.png")

    if score_center < 0.85:
        print(f"\nWARNING: center IoU {score_center:.4f} < 0.85, shape drifted from source")
        sys.exit(1)
    print(f"\nOK: center IoU {score_center:.4f} >= 0.85")
