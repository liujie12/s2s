"""Tab 图标候选的几何实测与渲染校验（2026-08-26）。

为什么需要这个脚本：tabicon-preview.html 里 disc / head 两个鸭子候选都需要把
「鸭头」这一段子路径重新定位到画板中央并放大。缩放系数与平移量若凭目测填写，
就会重犯之前「用错的方法测量然后相信输出数字」的错误。因此这里：

  1. 从真源 assets/duck-symbol-full.svg 取出 DISC_HEAD，程序切分出鸭头子路径
  2. 用共用光栅化器实测鸭头包围盒（渲染成掩码后取非零区域，而非解析路径数字，
     因为贝塞尔控制点可能落在轮廓之外，按数字取极值会得到偏大的包围盒）
  3. 按实测值算出居中铺满所需的 scale 与 translate
  4. 渲染三个候选在 24 / 48 / 96px 下的位图，逐张过目

用法：python probe-tabicon-geom.py
"""

import os
import sys
from importlib.machinery import SourceFileLoader

import cv2
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
_v = SourceFileLoader("_v", os.path.join(HERE, "probe-render-verify.py")).load_module()

BRAND = "#0B7C8C"
CANVAS = 1024.0


def read_disc_head():
    """从真源 SVG 里取出「盘 + 镂空鸭头」那一条 path 的 d 属性。

    不从 code.js 取，理由：PRD §1.4.1.3 定 assets/*.svg 为唯一真源，
    code.js 只是副本；一切几何推导都应回到真源。

    为什么读 full 档而不是 mini 档：2026-08-26 底部 Tab 改造后，mini 档已由
    「圆角块 + 白盘（盘内镂空鸭头）」改为「主色圆盘 circle + 白色实体鸭头 path
    + 主色眼点 circle」三层结构，不再含复合路径。full 档仍保留原「盘 + 镂空鸭头」
    复合路径，且两档鸭头几何本就同源（同一 DUCK_HEAD_PATH），换读 full 档
    得到的实测值与本脚本历史输出完全一致。

    :returns: d 属性字符串
    :rtype: str
    """
    path = os.path.join(HERE, "assets", "duck-symbol-full.svg")
    with open(path, "r", encoding="utf-8") as f:
        svg = f.read()
    # full 档有三条 path：两条环 + 「盘 + 鸭头」复合路径
    import re
    ds = re.findall(r'<path[^>]*\bd="([^"]+)"', svg)
    if not ds:
        sys.exit("真源里找不到 path，assets/duck-symbol-full.svg 结构变了")
    # 取含两段子路径（盘 + 鸭头）的那一条：环只有圆弧，唯有鸭头段用大量 C
    for d in ds:
        if d.count(" M") >= 1 and d.count("C") > 10:
            return d
    sys.exit("真源里找不到「盘 + 鸭头」复合路径")


def split_head(disc_head):
    """把「盘 + 鸭头」复合路径切出鸭头那一段子路径。

    :param str disc_head: 含两段子路径的 d 属性
    :returns: 仅鸭头的 d 属性
    :rtype: str
    """
    parts = disc_head.split(" M")
    if len(parts) != 2:
        sys.exit("复合路径的子路径数不是 2，实际 %d" % len(parts))
    return "M" + parts[1]


def mask_of(d, size, vb=CANVAS):
    """把单条路径渲染成布尔掩码，用于实测包围盒。

    :param str d: 路径 d 属性
    :param int size: 渲染边长
    :param float vb: viewBox 边长
    :returns: True 表示有墨的像素
    :rtype: numpy.ndarray
    """
    svg = (
        '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" '
        'viewBox="0 0 %g %g"><path d="%s" fill="#000000"/></svg>'
        % (size, size, vb, vb, d)
    )
    img = _v.render_svg(svg, size)
    return cv2.cvtColor(img, cv2.COLOR_BGR2GRAY) < 128


def measure_bbox(d, probe_px=1024):
    """实测路径的包围盒（画板坐标系）。

    用渲染掩码而非解析路径数字：贝塞尔控制点常落在轮廓外侧，
    按数字取极值会得到偏大的包围盒，进而算出偏小的缩放系数。

    :param str d: 路径 d 属性
    :param int probe_px: 探测分辨率
    :returns: (x, y, w, h) 画板坐标
    :rtype: tuple
    """
    m = mask_of(d, probe_px)
    ys, xs = np.nonzero(m)
    if len(xs) == 0:
        sys.exit("路径渲染为空，无法实测包围盒")
    k = CANVAS / probe_px
    x0, x1 = xs.min() * k, (xs.max() + 1) * k
    y0, y1 = ys.min() * k, (ys.max() + 1) * k
    return x0, y0, x1 - x0, y1 - y0


def fit_transform(bbox, target=0.92):
    """算出把包围盒等比居中铺满画板所需的 scale 与 translate。

    :param tuple bbox: (x, y, w, h)
    :param float target: 目标占画板比例，留白 = 1 - target
    :returns: (scale, tx, ty)，对应 SVG "translate(tx ty) scale(scale)"
    :rtype: tuple
    """
    x, y, w, h = bbox
    k = CANVAS * target / max(w, h)
    tx = CANVAS / 2.0 - (x + w / 2.0) * k
    ty = CANVAS / 2.0 - (y + h / 2.0) * k
    return k, tx, ty


def transform_path(d, k, tx, ty):
    """把仿射变换（等比缩放 + 平移）烧进路径坐标，不依赖 SVG transform 属性。

    为什么不用 <g transform>：Figma 的 createNodeFromSvg 对 transform 的支持
    未见于官方文档保证（已知它会剥离 defs / 渐变 / 蒙版），而坐标烧进 d 属性
    是纯几何数据，任何解析器都必然一致。共用光栅化器同样只认 translate，
    烧进坐标可让探针与最终产物走完全相同的数据。

    仅支持绝对 M / L / C / A / Z —— 鸭头路径只用到 M / C / Z，函数入口处断言，
    出现其他指令直接退出而非静默按错误规则处理。

    :param str d: 原路径 d 属性
    :param float k: 等比缩放系数
    :param float tx: X 平移量（变换后坐标系）
    :param float ty: Y 平移量
    :returns: 变换后的 d 属性
    :rtype: str
    """
    import re
    toks = re.findall(r"([MLCAZmlcaz])|(-?\d+\.?\d*)", d)
    out = []
    i = 0
    cmd = None
    nums = []

    def emit():
        """把已累积的一段指令按其坐标语义变换后追加到输出。"""
        if cmd is None:
            return
        if cmd == "Z":
            out.append("Z")
            return
        if cmd in ("M", "L", "C"):
            # 全部是成对的 (x, y)
            vals = []
            for j in range(0, len(nums), 2):
                vals.append("%.2f" % (nums[j] * k + tx))
                vals.append("%.2f" % (nums[j + 1] * k + ty))
            out.append(cmd + " " + " ".join(vals))
            return
        if cmd == "A":
            # A rx ry rot large sweep x y —— 半径随缩放，旋转角与 flag 不变
            vals = []
            for j in range(0, len(nums), 7):
                vals += ["%.2f" % (nums[j] * k), "%.2f" % (nums[j + 1] * k),
                         "%g" % nums[j + 2], "%g" % nums[j + 3], "%g" % nums[j + 4],
                         "%.2f" % (nums[j + 5] * k + tx), "%.2f" % (nums[j + 6] * k + ty)]
            out.append("A " + " ".join(vals))
            return
        sys.exit("transform_path 不支持指令 %s" % cmd)

    for letter, num in toks:
        if letter:
            emit()
            if letter.islower():
                sys.exit("transform_path 不支持相对指令 %s" % letter)
            cmd, nums = letter, []
        else:
            nums.append(float(num))
    emit()
    return " ".join(out)


def svg_mini(disc_head, eye_r=25.6):
    """改造前的 mini 档基线：圆角主色块 + 白盘（盘内镂空鸭头）+ 白眼点。

    保留它是为了对照 —— 2026-08-26 后 mini 档已定稿为 svg_disc 的结构，
    这一条只用于复现「为什么当初判定它在 24px 下不可辨」。
    """
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" '
        'viewBox="0 0 1024 1024">'
        '<rect x="0" y="0" width="1024" height="1024" rx="229.38" fill="%s"/>'
        '<path d="%s" fill="#FFFFFF" fill-rule="evenodd"/>'
        '<circle cx="506.1" cy="458.5" r="%g" fill="#FFFFFF"/>'
        "</svg>" % (BRAND, disc_head, eye_r)
    )


def svg_disc(head_t, ex, ey, eye_r):
    """候选 A：主色实心圆盘 + 白色实体鸭头（鸭头由镂空改为实体）。

    :param str head_t: 已烧进变换的鸭头路径
    :param float ex: 变换后的眼点圆心 X
    :param float ey: 变换后的眼点圆心 Y
    :param float eye_r: 变换后的眼点半径
    """
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" '
        'viewBox="0 0 1024 1024">'
        '<circle cx="512" cy="512" r="504" fill="%s"/>'
        '<path d="%s" fill="#FFFFFF"/>'
        '<circle cx="%.2f" cy="%.2f" r="%.2f" fill="%s"/>'
        "</svg>" % (BRAND, head_t, ex, ey, eye_r, BRAND)
    )


def svg_head(head_t, ex, ey, eye_r):
    """候选 B：纯鸭头剪影，无容器，鸭头铺满画板。"""
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" '
        'viewBox="0 0 1024 1024">'
        '<path d="%s" fill="%s"/>'
        '<circle cx="%.2f" cy="%.2f" r="%.2f" fill="#FFFFFF"/>'
        "</svg>" % (head_t, BRAND, ex, ey, eye_r)
    )


def ink_ratio(svg, px):
    """算指定尺寸下的墨水占比，用于比较三候选谁在小尺寸下更实。

    :param str svg: SVG 文本
    :param int px: 渲染边长
    :returns: 非白像素占比
    :rtype: float
    """
    img = _v.render_svg(svg, px)
    g = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    return float((g < 250).sum()) / (px * px)


def contact_sheet(rows, out_path, zoom=8):
    """把候选在多尺寸下的渲染拼成一张对照图，小尺寸放大以看像素。

    :param list rows: [(标题, svg, [尺寸...])]
    :param str out_path: 输出 PNG 路径
    :param int zoom: 小尺寸放大倍数（INTER_NEAREST，看真实像素）
    """
    cells = []
    for _, svg, sizes in rows:
        row = []
        for s in sizes:
            img = _v.render_svg(svg, s)
            f = max(1, int(round(192.0 / s)))
            big = cv2.resize(img, (s * f, s * f), interpolation=cv2.INTER_NEAREST)
            pad = np.full((200, 200, 3), 245, dtype=np.uint8)
            h, w = big.shape[:2]
            y0, x0 = (200 - h) // 2, (200 - w) // 2
            pad[y0:y0 + h, x0:x0 + w] = big
            row.append(pad)
        cells.append(np.hstack(row))
    sheet = np.vstack(cells)
    cv2.imwrite(out_path, sheet)
    return sheet.shape


if __name__ == "__main__":
    disc_head = read_disc_head()
    head = split_head(disc_head)

    bbox = measure_bbox(head)
    print("鸭头包围盒实测 x=%.1f y=%.1f w=%.1f h=%.1f" % bbox)

    EYE = (506.1, 458.5, 20.27)   # 真源实测眼点（画板坐标）

    # 候选 B（纯剪影）铺满：占画板 92%，留 4% 边距防贴边
    kB, txB, tyB = fit_transform(bbox, target=0.92)
    # 候选 A（圆盘内）：鸭头占画板 72%，为圆盘留出可见环带
    kA, txA, tyA = fit_transform(bbox, target=0.72)
    print("剪影版变换 scale=%.4f translate=%.2f %.2f" % (kB, txB, tyB))
    print("圆盘版变换 scale=%.4f translate=%.2f %.2f" % (kA, txA, tyA))

    headA = transform_path(head, kA, txA, tyA)
    headB = transform_path(head, kB, txB, tyB)
    eyeA = (EYE[0] * kA + txA, EYE[1] * kA + tyA, EYE[2] * kA)
    eyeB = (EYE[0] * kB + txB, EYE[1] * kB + tyB, EYE[2] * kB)

    s_mini = svg_mini(disc_head)
    s_disc = svg_disc(headA, *eyeA)
    s_head = svg_head(headB, *eyeB)

    # 变换后必须复测包围盒确认真的铺满了 —— 只看 scale 数字不算验证
    for tag, d, want in (("disc", headA, 0.72), ("head", headB, 0.92)):
        bb = measure_bbox(d)
        got = max(bb[2], bb[3]) / CANVAS
        flag = "OK" if abs(got - want) < 0.02 else "FAIL"
        print("[%s] %s 变换后占比 %.3f（目标 %.2f）" % (flag, tag, got, want))

    print("\n24px 墨水占比：mini=%.3f  disc=%.3f  head=%.3f"
          % (ink_ratio(s_mini, 24), ink_ratio(s_disc, 24), ink_ratio(s_head, 24)))

    out = os.path.join(HERE, "assets", "render", "tabicon-duck-variants.png")
    shape = contact_sheet(
        [("mini", s_mini, [24, 48, 96]),
         ("disc", s_disc, [24, 48, 96]),
         ("head", s_head, [24, 48, 96])],
        out,
    )
    print("对照图 %s  %s" % (out, shape))

    # 实测参数直接打印。不再写 _tabicon-geom.json：定稿几何已固化进
    # build-4b-assets.py 的 transform_head_scaled 与 code.js 的 DUCK_*_MINI，
    # 留一个中间文件只会多出一份需要同步的副本。
    print("\n鸭头包围盒 %s" % [round(v, 2) for v in bbox])
    print("disc 眼点 %s" % [round(v, 2) for v in eyeA])
    print("head 眼点 %s" % [round(v, 2) for v in eyeB])
