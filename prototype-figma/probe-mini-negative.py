"""复审「镂空鸭头」能否在 24px 下成立（2026-08-26 第二轮，用户偏好驱动）。

背景：用户看 tabicon-preview.html 时表示更喜欢「镂空」观感，但截图里他看的是
48/96px 的格子，而这枚图标实际渲染在 24px。第一轮我以「24px 下喙形难辨」淘汰
了镂空版，本脚本要复核那次淘汰是否下得太早。

关键怀疑：压死鸭头的未必是「镂空」这个手法，而是旧结构里**白盘只占画板 44%**
（24px 下仅约 10px，鸭头还要挤在这 10px 内）。若把镂空盘放大到铺满画板，
鸭头能拿到的像素与实体版完全相同 —— 那么「好看」与「可辨」就不冲突。

因此逐档实测白盘占比 44% / 72% / 88% / 96% 四种镂空版，与已定稿的实体版对照：
1. 鸭头负形（白色区域）的最大内切圆直径 —— 笔画会不会消失
2. 负形连通域个数 —— 喙与头是否断开
3. 眼点是否还看得见（眼点在镂空版里是主色，落在白鸭头内）
4. 渲染 24px 实图供肉眼定夺

用法：python probe-mini-negative.py
"""

import os
import sys
from importlib.machinery import SourceFileLoader

import cv2
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
_v = SourceFileLoader("_v", os.path.join(HERE, "probe-render-verify.py")).load_module()
_b = SourceFileLoader("_b", os.path.join(HERE, "build-4b-assets.py")).load_module()

BRAND = "#0B7C8C"
WHITE = "#FFFFFF"
CANVAS = 1024.0


def svg_hollow(ratio):
    """镂空版：主色圆盘铺满画板，鸭头以负形（白色）挖出，眼点为主色。

    与已定稿的实体版是同一套几何、同一条 DUCK_HEAD_PATH，差别只在「谁是墨、
    谁是底」—— 两者的鸭头轮廓像素完全重合，因此可以直接比可辨性。

    圆盘用两段 A 弧闭合成整圆，与鸭头拼成 evenodd 复合路径，从而把鸭头真正
    挖空（而非叠一个白鸭头上去）—— 这才是用户截图里的观感。

    :param float ratio: 鸭头长边占画板的比例（决定鸭头在盘内多大）
    :returns: SVG 文本
    :rtype: str
    """
    path, eye = _b.transform_head_scaled(CANVAS, ratio)
    half = CANVAS / 2.0
    r = half - CANVAS * 0.0078
    # 圆盘用两段 A 弧闭合成整圆，与鸭头拼成 evenodd 复合路径 -> 鸭头被挖空
    disc = (f"M{half - r:g} {half:g} "
            f"A{r:g} {r:g} 0 1 0 {half + r:g} {half:g} "
            f"A{r:g} {r:g} 0 1 0 {half - r:g} {half:g} Z")
    return "\n".join([
        f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" '
        f'viewBox="0 0 {CANVAS:g} {CANVAS:g}">',
        f'  <path d="{disc} {path}" fill="{BRAND}" fill-rule="evenodd"/>',
        f'  <circle cx="{eye[0]:.2f}" cy="{eye[1]:.2f}" r="{eye[2]:.2f}" fill="{BRAND}"/>',
        "</svg>",
    ])


def svg_solid():
    """已定稿的实体版，直接取真源文件，避免与真源脱钩。"""
    with open(os.path.join(HERE, "assets", "duck-symbol-mini.svg"),
              "r", encoding="utf-8") as f:
        return f.read()


def measure(svg, px=24):
    """实测指定尺寸下鸭头笔画的可辨性。

    鸭头在镂空版里是「非主色区」（白色负形），在实体版里是「白色实心」，
    两者都取「白色且落在圆盘内」的像素作为鸭头 —— 用同一套判据才可比。

    :param str svg: SVG 文本
    :param int px: 渲染边长
    :returns: (最大内切圆直径, 连通域个数, 鸭头像素数)
    :rtype: tuple
    """
    img = _v.render_svg(svg, px)
    g = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    # 白色 = 鸭头负形；限定在圆盘内，否则圆盘外的透明区（渲染为白）会被算进来
    gy, gx = np.ogrid[:px, :px]
    c = px / 2.0
    inside = ((gx - c) ** 2 + (gy - c) ** 2) <= (0.47 * px) ** 2
    mask = ((g > 200) & inside).astype(np.uint8)
    if mask.sum() == 0:
        return 0.0, 0, 0
    dist = cv2.distanceTransform(mask, cv2.DIST_L2, 3)
    n, _ = cv2.connectedComponents(mask)
    return float(dist.max()) * 2.0, n - 1, int(mask.sum())


def svg_painted(ratio):
    """染色版：主色圆盘 + 白色实体鸭头 + 主色眼点（现行 code.js 的结构）。

    与 svg_hollow 的区别只在「鸭头那块白是怎么来的」：这里是显式填白，
    那里是挖空透底。前者不依赖底色，放在任何背景上都成立 —— code.js 里
    这块白由 negative 角色绑定 color/surface，因此现行版在视觉上本就是
    「挖空」的观感。本函数用于实测两者是否真的逐像素等价。

    :param float ratio: 鸭头长边占画板的比例
    :returns: SVG 文本
    :rtype: str
    """
    path, eye = _b.transform_head_scaled(CANVAS, ratio)
    half = CANVAS / 2.0
    r = half - CANVAS * 0.0078
    return "\n".join([
        f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" '
        f'viewBox="0 0 {CANVAS:g} {CANVAS:g}">',
        f'  <circle cx="{half:g}" cy="{half:g}" r="{r:g}" fill="{BRAND}"/>',
        f'  <path d="{path}" fill="{WHITE}"/>',
        f'  <circle cx="{eye[0]:.2f}" cy="{eye[1]:.2f}" r="{eye[2]:.2f}" fill="{BRAND}"/>',
        "</svg>",
    ])


def head_clearance(ratio, px=512):
    """实测鸭头边缘到圆盘边缘的最小间距，确认放大后主色环带没被吃掉。

    只看 span 比例不够：鸭头是有机形，长边铺到 88% 时对角方向可能已顶到
    圆盘弧线。因此渲染后逐像素求「白色鸭头像素到圆心的最大距离」，
    与圆盘半径相比。

    :param float ratio: 鸭头长边占画板的比例
    :param int px: 探测分辨率
    :returns: (最小环带宽度占画板比例, 鸭头最远点占圆盘半径比例)
    :rtype: tuple
    """
    img = _v.render_svg(svg_painted(ratio), px)
    g = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    c = (px - 1) / 2.0
    r_disc = (0.5 - 0.0078) * px
    ys, xs = np.nonzero(g > 200)
    # 排除圆盘之外的透明区（渲染器把透明画成白）
    d = np.sqrt((xs - c) ** 2 + (ys - c) ** 2)
    inside = d <= r_disc * 0.995
    if not inside.any():
        sys.exit("鸭头渲染为空")
    d_max = d[inside].max()
    band = (r_disc - d_max) / px
    return band, d_max / r_disc


def sheet_24(rows, out_path, zoom=12):
    """只渲染 24px 的对照图，放大后并排。

    为什么不再给 48/96px 格：上一版对照图三档并列，48/96px 的观感把 24px 的
    缺陷盖住了 —— 我据此推荐了 88%，用户据此选了它，两边都看走眼。这枚图标
    只用在 24px，对照图就只该给 24px。放大用 INTER_NEAREST，看真实像素。

    :param list rows: [(标题, svg)]
    :param str out_path: 输出 PNG 路径
    :param int zoom: 放大倍数
    """
    cells = []
    for _, svg in rows:
        img = _v.render_svg(svg, 24)
        big = cv2.resize(img, (24 * zoom, 24 * zoom), interpolation=cv2.INTER_NEAREST)
        pad = np.full((24 * zoom + 16, 24 * zoom + 16, 3), 240, dtype=np.uint8)
        pad[8:-8, 8:-8] = big
        cells.append(pad)
    cv2.imwrite(out_path, np.hstack(cells))


if __name__ == "__main__":
    print("%-22s %10s %8s %8s" % ("版本", "24px笔画", "连通域", "像素数"))
    for tag, svg in ([("solid 72% (已定稿)", svg_solid())]
                     + [(f"hollow {int(r * 100)}%", svg_hollow(r))
                        for r in (0.44, 0.72, 0.88, 0.96)]):
        d, n, area = measure(svg, 24)
        flag = "OK  " if d >= 2.0 and n >= 1 else "FAIL"
        print("%-22s %8.2fpx %8d %8d  %s" % (tag, d, n, area, flag))

    # 挖空版与染色版是否逐像素等价 —— 若等价，则「改成挖空」这件事无需动结构
    print("\n挖空 vs 染色（同一 ratio，逐像素 IoU）：")
    for r in (0.72, 0.88):
        a = cv2.cvtColor(_v.render_svg(svg_hollow(r), 512), cv2.COLOR_BGR2GRAY) > 200
        b = cv2.cvtColor(_v.render_svg(svg_painted(r), 512), cv2.COLOR_BGR2GRAY) > 200
        iou = (a & b).sum() / float((a | b).sum())
        print("  ratio=%.2f  IoU=%.4f  差异像素=%d" % (r, iou, int((a ^ b).sum())))

    # 放大后主色环带还剩多少 —— 只看 span 不够，鸭头是有机形，对角可能已顶边。
    # 环带是「按钮体量感」的载体，24px 下若不足 1px 就会断续，图标看着像贴纸。
    # 判据取 1.5px：小于 1px 必断续，取 1.5px 留出抗锯齿余量。
    print("\n鸭头到圆盘边缘的余量（环带 = 按钮体量感，24px 下需 >= 1.5px）：")
    ok_ratios = []
    for r in (0.72, 0.76, 0.80, 0.84, 0.88, 0.96):
        band, occupy = head_clearance(r)
        px24 = band * 24
        flag = "OK  " if px24 >= 1.5 else "WARN"
        if px24 >= 1.5:
            ok_ratios.append(r)
        print("  ratio=%.2f  环带最窄 %.3f 画板（24px 下 %.2fpx）  占圆盘 %.3f  %s"
              % (r, band, px24, occupy, flag))
    print("  环带达标的最大 ratio = %.2f" % max(ok_ratios))

    out = os.path.join(HERE, "assets", "render", "mini-hollow-24px.png")
    sheet_24([(f"{int(r * 100)}%", svg_hollow(r))
              for r in (0.72, 0.76, 0.80, 0.84, 0.88)], out)
    print("\n24px 对照图（左起 72/76/80/84/88 百分比）：%s" % out)

