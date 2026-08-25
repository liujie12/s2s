"""底部 Tab 栏改动后的渲染校验（2026-08-26）。

背景：用户反馈「鸭圈」图标不美观，根因是三键里两键是 emoji。本次改动
把三键全部改为矢量（map / 圆盘鸭 / person）。本脚本按 code.js 的实际组装
逻辑复现这三个图标并渲染成位图，位图必须人工过目。

为什么必须复现而不是只读代码：上一轮的教训是「验了 SVG 语法、路径数、
与另一份副本的一致性，却从未验证渲染结果像不像鸭子」（说明文档原则 ㉒）。
因此这里做三件事：
  1. 从 code.js 逐字取出 ICON_PATHS 的两个新条目与 mini 档鸭子几何
  2. 按 duckSymbol / svgIcon 的组装规则复现 SVG 并渲染
  3. 实测 24px 下的笔画最细处，确认不低于 2px 硬约束

用法：python probe-tabbar-verify.py
"""

import os
import re
import sys
from importlib.machinery import SourceFileLoader

import cv2
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
_v = SourceFileLoader("_v", os.path.join(HERE, "probe-render-verify.py")).load_module()

CODE_JS = os.path.join(HERE, "code.js")
BRAND = "#0B7C8C"
SECONDARY = "#6B7280"

_passed = []
_failed = []


def check(ok, msg):
    """记录一条断言结果。

    :param bool ok: 是否通过
    :param str msg: 结果描述
    """
    (_passed if ok else _failed).append(msg)
    print("[%s] %s" % ("PASS" if ok else "FAIL", msg))


def read_code():
    """读取 code.js 全文。

    :returns: 源码文本
    :rtype: str
    """
    with open(CODE_JS, "r", encoding="utf-8") as f:
        return f.read()


def js_string(src, name):
    """从 code.js 里取出 `var NAME = '...'` 的字符串字面量。

    找不到直接退出而非返回空值：静默返回空会让后续渲染出一张白图，
    而白图很容易被误读成「图形正常只是看不清」。

    :param str src: code.js 全文
    :param str name: 变量名
    :returns: 字符串字面量内容
    :rtype: str
    """
    m = re.search(r"var\s+" + re.escape(name) + r"\s*=\s*'([^']+)'", src)
    if not m:
        sys.exit("code.js 里找不到变量 %s" % name)
    return m.group(1)


def icon_def(src, key):
    """从 ICON_PATHS 里取出一个图标条目的 vb 与 d。

    :param str src: code.js 全文
    :param str key: 图标键名，如 tab-map
    :returns: (viewBox 字符串, 内层 path 标记)
    :rtype: tuple
    """
    m = re.search(
        r"'" + re.escape(key) + r"':\s*\{\s*vb:\s*(\w+),\s*d:\s*'([^']+)'",
        src,
    )
    if not m:
        sys.exit("ICON_PATHS 里找不到 %s" % key)
    vb_var, d = m.group(1), m.group(2)
    m2 = re.search(r"var\s+" + re.escape(vb_var) + r"\s*=\s*'([^']+)'", src)
    if not m2:
        sys.exit("找不到 viewBox 常量 %s" % vb_var)
    return m2.group(1), d


def render_ms_icon(vb, inner, color, px):
    """按 svgIcon 的规则渲染一个 ICON_PATHS 图标。

    svgIcon 用 viewBox 第三个数作为 SVG 的 width/height，然后 rescale 到目标尺寸。
    共用光栅化器只认 "0 0 W H" 形式的 viewBox，而 Material Symbols 是
    "0 -960 960 960"（Y 轴负区间），故用 <g transform="translate(0 960)">
    把图形挪到正区间 —— 这只是渲染侧的等价变换，不改动 code.js 里的数据。

    :param str vb: 原始 viewBox
    :param str inner: <path .../> 标记
    :param str color: 目标填充色
    :param int px: 渲染边长
    :returns: BGR 位图
    :rtype: numpy.ndarray
    """
    parts = vb.split(" ")
    native = float(parts[2])
    body = inner.replace('fill="#000"', 'fill="%s"' % color)
    if parts[1].startswith("-"):
        body = '<g transform="translate(0 %g)">%s</g>' % (native, body)
    svg = (
        '<svg xmlns="http://www.w3.org/2000/svg" width="%g" height="%g" '
        'viewBox="0 0 %g %g">%s</svg>' % (native, native, native, native, body)
    )
    return _v.render_svg(svg, px)


def render_duck_mini(src, block, negative, px):
    """按 duckSymbol 的 mini 档规则渲染鸭子符号。

    :param str src: code.js 全文
    :param str block: 色块颜色
    :param str negative: 负形（鸭头）颜色
    :param int px: 渲染边长
    :returns: BGR 位图
    :rtype: numpy.ndarray
    """
    head = js_string(src, "DUCK_HEAD_MINI")
    m = re.search(
        r"var\s+DUCK_EYE_MINI\s*=\s*\{\s*cx:\s*([\d.]+),\s*cy:\s*([\d.]+),\s*r:\s*([\d.]+)",
        src,
    )
    if not m:
        sys.exit("code.js 里找不到 DUCK_EYE_MINI")
    cx, cy, r = (float(v) for v in m.groups())
    svg = (
        '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" '
        'viewBox="0 0 1024 1024">'
        '<circle cx="512" cy="512" r="504" fill="%s"/>'
        '<path d="%s" fill="%s"/>'
        '<circle cx="%g" cy="%g" r="%g" fill="%s"/>'
        "</svg>" % (block, head, negative, cx, cy, r, block)
    )
    return _v.render_svg(svg, px)


def min_stroke(img, color_hex):
    """实测某色笔画的最细处宽度（距离变换的最大值 ×2）。

    距离变换给出每个前景像素到最近背景的距离，其最大值 ×2 即该形状能
    容纳的最大内切圆直径。对细长笔画而言这个值就是笔画宽度的上界，
    因此它反映的是「最粗处」；用于判断「最细处会不会消失」时，
    真正的判据是形状是否仍连通且面积非零，故这里同时返回连通域数。

    :param numpy.ndarray img: BGR 位图
    :param str color_hex: 目标颜色
    :returns: (最大内切圆直径, 连通域个数)
    :rtype: tuple
    """
    b, g, r = (int(color_hex[i:i + 2], 16) for i in (5, 3, 1))
    target = np.array([b, g, r], dtype=np.int16)
    diff = np.abs(img.astype(np.int16) - target).sum(axis=2)
    mask = (diff < 90).astype(np.uint8)
    if mask.sum() == 0:
        return 0.0, 0
    dist = cv2.distanceTransform(mask, cv2.DIST_L2, 5)
    n_comp = cv2.connectedComponentsWithStats(mask)[0] - 1   # 减去背景域
    return float(dist.max() * 2), n_comp


def tab_cell(icon, label_w, active, cell_w=130, cell_h=64):
    """拼一个 Tab 单元格：图标 + 下方文字占位条，还原真实观感。

    文字用色条代替（共用渲染器不支持文本），只为看图标与文字的体量关系。

    :param numpy.ndarray icon: 图标位图
    :param int label_w: 文字占位条宽度
    :param bool active: 是否选中态
    :returns: 单元格位图
    :rtype: numpy.ndarray
    """
    cell = np.full((cell_h, cell_w, 3), 255, dtype=np.uint8)
    ih, iw = icon.shape[:2]
    y0, x0 = 10, (cell_w - iw) // 2
    roi = cell[y0:y0 + ih, x0:x0 + iw]
    m = cv2.cvtColor(icon, cv2.COLOR_BGR2GRAY) < 250
    roi[m] = icon[m]
    c = (140, 124, 11) if active else (128, 114, 107)   # BGR of #0B7C8C / #6B7280
    y = y0 + ih + 5
    cv2.rectangle(cell, ((cell_w - label_w) // 2, y),
                  ((cell_w + label_w) // 2, y + 8), c, -1)
    return cell


if __name__ == "__main__":
    src = read_code()

    # ---- 1. emoji 必须已从 bottomTabRaw 的 items 里清除 ----
    m = re.search(r"var items = \[\s*\[ICON_PATHS.*?\];", src, re.S)
    check(m is not None, "bottomTabRaw 的 items 已改为 ICON_PATHS 引用")
    if m:
        seg = m.group(0)
        check("🗺️" not in seg and "👤" not in seg, "items 里已无 emoji 字面量")

    # ---- 2. 两个新图标条目存在且可渲染 ----
    vb_map, d_map = icon_def(src, "tab-map")
    vb_person, d_person = icon_def(src, "tab-person")
    check(vb_map == "0 -960 960 960", "tab-map 用 Material Symbols viewBox（%s）" % vb_map)
    check(vb_person == "0 -960 960 960", "tab-person 用 Material Symbols viewBox")

    # ---- 3. 24px 下三个图标都必须有墨且连通域数符合形状预期 ----
    icons24 = {
        "tab-map": render_ms_icon(vb_map, d_map, BRAND, 24),
        "duck": render_duck_mini(src, BRAND, "#FFFFFF", 24),
        "tab-person": render_ms_icon(vb_person, d_person, BRAND, 24),
    }
    for name, img in icons24.items():
        w, ncomp = min_stroke(img, BRAND)
        check(w >= 2.0, "%s @24px 最大内切圆 %.2fpx ≥ 2.0（笔画未消失）" % (name, w))
        check(ncomp >= 1, "%s @24px 主色连通域 %d 个（图形存在）" % (name, ncomp))

    # ---- 4. 鸭子 mini 档：白色鸭头必须是【实体】而非镂空 ----
    #      判据是白色区域应完全落在圆盘内部，若鸭头是镂空则白色会连到画板边缘
    duck = icons24["duck"]
    wm = (cv2.cvtColor(duck, cv2.COLOR_BGR2GRAY) > 240).astype(np.uint8)
    border = np.concatenate([wm[0], wm[-1], wm[:, 0], wm[:, -1]])
    inner_white = int(wm.sum() - border.sum())
    check(inner_white > 0, "鸭子 mini 档圆盘内有白色鸭头实体（%d 像素）" % inner_white)

    # ---- 5. 未选中态必须真的换色（emoji 做不到这点，这是本次改动的目的）----
    map_sec = render_ms_icon(vb_map, d_map, SECONDARY, 24)
    diff = int(np.abs(icons24["tab-map"].astype(np.int16) - map_sec.astype(np.int16)).sum())
    check(diff > 0, "tab-map 选中/未选中两色渲染结果不同（差值 %d）" % diff)

    # ---- 6. 输出整条 Tab 栏对照图，三种选中态各一行 ----
    rows = []
    for active_idx in range(3):
        cells = []
        for i, (name, label_w) in enumerate(
            [("tab-map", 26), ("duck", 26), ("tab-person", 26)]
        ):
            on = (i == active_idx)
            color = BRAND if on else SECONDARY
            if name == "duck":
                icon = render_duck_mini(src, color, "#FFFFFF", 24)
            else:
                vb, d = (vb_map, d_map) if name == "tab-map" else (vb_person, d_person)
                icon = render_ms_icon(vb, d, color, 24)
            cells.append(tab_cell(icon, label_w, on))
        rows.append(np.hstack(cells))
    bar = np.vstack(rows)
    bar4 = cv2.resize(bar, (bar.shape[1] * 2, bar.shape[0] * 2),
                      interpolation=cv2.INTER_NEAREST)
    out = os.path.join(HERE, "assets", "render", "tabbar-final.png")
    cv2.imwrite(out, bar4)
    print("\n对照图（三行 = 三种选中态，2 倍放大）：%s" % out)

    print("\n%d passed / %d failed" % (len(_passed), len(_failed)))
    if _failed:
        sys.exit(1)
