"""按 4B 源图实测几何，组装规范化的 SVG 素材族。

组装原则：
- 两道同心环 + 中心白盘在源图中本应是完美圆（实测圆度 0.89，偏差来自位图
  锯齿），因此用解析圆重建，不用矢量化的抖动曲线；
- 鸭头是有机形，无法用解析几何表达，保留 MCP 矢量化的贝塞尔路径；
- 眼点实测圆度 0.9487，同样用解析圆重建；
- 所有半径按源图实测值除以 1024 得到比例，再乘目标画板边长，因此改画板尺寸
  不会破坏比例关系。

实测基准（源图 1024x1024，见 probe-4b-structure.py 输出）：
  外环外缘 r=395.84  外环内缘 r=361.87
  内环外缘 r=305.84  内环内缘 r=273.54
  中心白盘 r=227.08  圆心 (511.3, 506.0)
  鸭头包围盒在源图中的位置 x=[328,693] y=[377,692]
  眼点 圆心(506.1, 458.5) r=20.27
"""

import json
import os
import re

# --- 源图实测基准（单位：源图 1024 画板的像素） ---
SRC_CANVAS = 1024.0
CENTER = (511.3, 506.0)
R_OUTER_RING_OUT = 395.84
R_OUTER_RING_IN = 361.87
R_INNER_RING_OUT = 305.84
R_INNER_RING_IN = 273.54
R_DISC = 227.08
EYE_CENTER = (506.1, 458.5)
EYE_R = 20.27
# mini 档最小适用尺寸从 40px 降到 24px（底部 Tab 的实际用法），眼点须按 24px
# 复核 PRD §1.4.1.2 的「负形最窄处 >= 2px」：随鸭头同一变换得到的 r=40.83
# 在 24px 下只有 1.91px，故取 2px 反算的下限。PRD 允许「加粗」但不允许
# 「改成描边或换形」，因此只抬半径，位置与造型不动。
EYE_R_MINI_FLOOR = 2.0 / 24.0 * SRC_CANVAS / 2.0  # = 42.67，24px 下恰为 2.00px

# 鸭头矢量路径（MCP 描出，坐标系为 382x332 的抠图产物）
DUCK_HEAD_PATH = (
    "M98 19 C85.83 23.5 77.5 29.17 69 35 C60.5 40.83 53.83 46.67 47 54 "
    "C40.17 61.33 33.17 70.67 28 79 C22.83 87.33 19.33 90.67 16 104 "
    "C12.67 117.33 7.17 140.67 8 159 C8.83 177.33 13.67 196.83 21 214 "
    "C28.33 231.17 39.33 248 52 262 C64.67 276 79.67 288.33 97 298 "
    "C114.33 307.67 137.5 315.83 156 320 C174.5 324.17 195.67 323.17 208 323 "
    "C220.33 322.83 225.17 320.83 230 319 C234.83 317.17 234.67 314.33 237 312 "
    "C236.67 309.67 240.33 312.5 236 305 C231.67 297.5 216.33 276.83 211 267 "
    "C205.67 257.17 205 252.5 204 246 C203 239.5 203.33 234.17 205 228 "
    "C206.67 221.83 208.67 215 214 209 C219.33 203 223.17 196.67 237 192 "
    "C250.83 187.33 280.5 185.5 297 181 C313.5 176.5 325.33 171.17 336 165 "
    "C346.67 158.83 355.17 150 361 144 C366.83 138 369 133.5 371 129 "
    "C373 124.5 372.33 121 373 117 C369.67 114.67 371.5 111.17 363 110 "
    "C354.5 108.83 334.5 111.67 322 110 C309.5 108.33 296.67 104.17 288 100 "
    "C279.33 95.83 275.67 92.5 270 85 C264.33 77.5 259.33 63.17 254 55 "
    "C248.67 46.83 246.67 42.67 238 36 C229.33 29.33 213.17 19.67 202 15 "
    "C190.83 10.33 181 9.17 171 8 C161 6.83 154.17 6.17 142 8 "
    "C129.83 9.83 110.17 14.5 98 19 Z"
)
# 抠图时 pad=8，鸭头在抠图坐标系中的包围盒
HEAD_LOCAL_BBOX = (8.0, 8.0, 366.0, 316.0)  # x, y, w, h
# 该包围盒对应源图 1024 画板中的位置
HEAD_SRC_ORIGIN = (328.0, 377.0)

OUT_DIR = r"d:\developer\code\aicoding\s2s\prototype-figma\assets"
BRAND = "#0B7C8C"
WHITE = "#FFFFFF"


def fmt(v):
    """格式化坐标，保留两位小数并去掉尾随零。"""
    s = f"{v:.2f}".rstrip("0").rstrip(".")
    return s or "0"


def transform_head(canvas):
    """把鸭头路径从抠图坐标系变换到目标画板坐标系。

    源图中鸭头位于 HEAD_SRC_ORIGIN 处，先把抠图坐标平移到源图坐标，
    再按 canvas/1024 整体缩放，从而保持鸭头与环、盘的相对位置不变。

    :param canvas: 目标画板边长
    :return: 变换后的路径字符串
    """
    k = canvas / SRC_CANVAS
    # 抠图坐标 -> 源图坐标：减去局部 bbox 原点，加上源图中的位置
    dx = HEAD_SRC_ORIGIN[0] - HEAD_LOCAL_BBOX[0]
    dy = HEAD_SRC_ORIGIN[1] - HEAD_LOCAL_BBOX[1]

    def repl(match):
        """对路径中的每个坐标对做仿射变换。"""
        x = float(match.group(1))
        y = float(match.group(2))
        return f"{fmt((x + dx) * k)} {fmt((y + dy) * k)}"

    # 路径只含 M/C/Z，坐标成对出现
    return re.sub(r"(-?\d+\.?\d*)\s+(-?\d+\.?\d*)", repl, DUCK_HEAD_PATH)


def transform_head_scaled(canvas, ratio):
    """把鸭头变换到画板中央并等比放大到占画板指定比例。

    mini 档专用（2026-08-26）。为什么 mini 档需要另一套变换：原 mini 档沿用
    「圆角块 + 白盘 + 盘内镂空鸭头」四层结构，24px 下白盘直径仅约 10px，
    鸭头要在这 10px 内表达喙与颈，喙尖必先消失 —— 用户实机反馈的成因。
    改法是去掉外层圆角块、圆盘铺满画板、鸭头由镂空反相为实体，
    使鸭头笔画拿到自己的像素（与 android-foreground 同一思路）。

    这不算「另画新形」（PRD §1.4.1.2 禁止）：路径数据与 transform_head 同一条，
    只是换了缩放中心与倍率，做的是层次减法而非重绘。

    包围盒由实测得来（probe-tabicon-geom.py 渲染掩码后取非零区域），
    而不是按路径数字取极值 —— 贝塞尔控制点常落在轮廓外侧，
    按数字算会得到偏大的包围盒，进而算出偏小的缩放倍率。

    :param canvas: 目标画板边长
    :param ratio: 鸭头长边占画板的比例
    :return: (变换后的路径字符串, 眼点 (cx, cy, r))
    """
    # 鸭头在 1024 源图坐标系下的实测包围盒
    bx, by, bw, bh = 328.0, 376.0, 366.0, 317.0
    k = canvas * ratio / max(bw, bh)
    tx = canvas / 2.0 - (bx + bw / 2.0) * k
    ty = canvas / 2.0 - (by + bh / 2.0) * k

    # 抠图坐标 -> 源图坐标
    dx = HEAD_SRC_ORIGIN[0] - HEAD_LOCAL_BBOX[0]
    dy = HEAD_SRC_ORIGIN[1] - HEAD_LOCAL_BBOX[1]

    def repl(match):
        """先平移到源图坐标系，再按 (k, tx, ty) 做居中缩放。"""
        x = (float(match.group(1)) + dx) * k + tx
        y = (float(match.group(2)) + dy) * k + ty
        return f"{fmt(x)} {fmt(y)}"

    path = re.sub(r"(-?\d+\.?\d*)\s+(-?\d+\.?\d*)", repl, DUCK_HEAD_PATH)
    eye = (
        EYE_CENTER[0] * k + tx,
        EYE_CENTER[1] * k + ty,
        EYE_R * k,
    )
    return path, eye


def build_mini_symbol(canvas=1024, ratio=0.72):
    """组装微缩档符号：主色圆盘铺满画板 + 白色实体鸭头 + 主色眼点。

    为什么不沿用 build_symbol(canvas, 0, BRAND)：那套是「圆角块 + 白盘 +
    盘内镂空鸭头」四层结构，白盘直径只占画板 44%，24px 下折算约 10px，
    鸭头要在这 10px 内表达喙与颈，喙尖必先糊掉 —— 用户实机反馈的成因。

    三处改动都是层次减法，不是重绘（PRD §1.4.1.2 禁止另画新形，路径数据
    与 transform_head 同一条）：
    1. 去掉外层圆角块，圆盘直接铺满画板，鸭头的可用直径从 44% 抬到 98%；
    2. 鸭头由镂空反相为白色实体 —— 镂空透出的是底色，前景层不能靠镂空
       表达形状，反相后笔画才拿到自己的像素（与 build_android_foreground 同思路）；
    3. 眼点随之改为主色 —— 鸭头已是白色，白眼点会与鸭头融为一体。

    :param canvas: 画板边长
    :param ratio: 鸭头长边占画板的比例
    :return: SVG 全文
    """
    path, eye = transform_head_scaled(canvas, ratio)
    # 眼点半径取「随鸭头变换所得」与「24px 下 2px 底线」的较大者
    r_eye = max(eye[2], EYE_R_MINI_FLOOR * canvas / SRC_CANVAS)
    half = canvas / 2.0
    # 圆盘半径留 canvas*0.78% 余量，避免边缘抗锯齿被裁切
    r_disc = half - canvas * 0.0078
    return "\n".join([
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{canvas:g}" '
        f'height="{canvas:g}" viewBox="0 0 {canvas:g} {canvas:g}">',
        f'  <circle cx="{fmt(half)}" cy="{fmt(half)}" r="{fmt(r_disc)}" '
        f'fill="{BRAND}"/>',
        f'  <path d="{path}" fill="{WHITE}"/>',
        f'  <circle cx="{fmt(eye[0])}" cy="{fmt(eye[1])}" r="{fmt(r_eye)}" '
        f'fill="{BRAND}"/>',
        "</svg>",
    ])


def ring(canvas, r_out, r_in):
    """生成环形的 evenodd 双圆子路径。

    用两个反向圆弧构成环：外圆顺时针，内圆逆时针，配合 fill-rule="evenodd"
    形成中空。半径按 canvas/1024 缩放。

    :param canvas: 目标画板边长
    :param r_out: 源图坐标系下的外缘半径
    :param r_in: 源图坐标系下的内缘半径
    :return: 环形路径字符串
    """
    k = canvas / SRC_CANVAS
    cx = CENTER[0] * k
    cy = CENTER[1] * k
    ro = r_out * k
    ri = r_in * k

    def circle_path(r):
        """用两段 A 弧画整圆。"""
        return (
            f"M{fmt(cx - r)} {fmt(cy)} "
            f"A{fmt(r)} {fmt(r)} 0 1 0 {fmt(cx + r)} {fmt(cy)} "
            f"A{fmt(r)} {fmt(r)} 0 1 0 {fmt(cx - r)} {fmt(cy)} Z"
        )

    return circle_path(ro) + " " + circle_path(ri)


def disc_with_duck(canvas, arcs=2, eye_r=None, fg=WHITE, eye_fill=None):
    """生成「中心盘 + 挖空鸭头 + 眼点」的图层组，可选叠加同心环。

    盘与鸭头合成一个 evenodd path：盘为外子路径，鸭头为内子路径，因此鸭头
    呈镂空、透出其下方的底色。眼点是独立的实心圆，叠在鸭头之上，颜色须与
    盘一致（它在视觉上属于「盘」这一层，只是被鸭头包围）。

    :param canvas: 目标画板边长
    :param arcs: 叠加的同心环数量，0/1/2 对应三个降级档位
    :param eye_r: 眼点半径（源图坐标系）；None 用默认 EYE_R
    :param fg: 盘与环的填充色。反白版须传品牌色，否则白底白图不可见
    :param eye_fill: 眼点填充色；None 时同 fg
    :return: SVG 内部元素的字符串列表
    """
    k = canvas / SRC_CANVAS
    cx = CENTER[0] * k
    cy = CENTER[1] * k
    rd = R_DISC * k
    r_eye = EYE_R if eye_r is None else eye_r
    eye_color = fg if eye_fill is None else eye_fill
    parts = []

    if arcs >= 2:
        parts.append(
            f'  <path d="{ring(canvas, R_OUTER_RING_OUT, R_OUTER_RING_IN)}" '
            f'fill="{fg}" fill-rule="evenodd"/>'
        )
    if arcs >= 1:
        parts.append(
            f'  <path d="{ring(canvas, R_INNER_RING_OUT, R_INNER_RING_IN)}" '
            f'fill="{fg}" fill-rule="evenodd"/>'
        )

    disc = (
        f"M{fmt(cx - rd)} {fmt(cy)} "
        f"A{fmt(rd)} {fmt(rd)} 0 1 0 {fmt(cx + rd)} {fmt(cy)} "
        f"A{fmt(rd)} {fmt(rd)} 0 1 0 {fmt(cx - rd)} {fmt(cy)} Z"
    )
    parts.append(
        f'  <path d="{disc} {transform_head(canvas)}" '
        f'fill="{fg}" fill-rule="evenodd"/>'
    )
    parts.append(
        f'  <circle cx="{fmt(EYE_CENTER[0] * k)}" cy="{fmt(EYE_CENTER[1] * k)}" '
        f'r="{fmt(r_eye * k)}" fill="{eye_color}"/>'
    )
    return parts


def build_symbol(canvas, arcs, bg, rounded=True, eye_r=None, fg=WHITE):
    """组装完整符号 SVG。

    :param canvas: 画板边长
    :param arcs: 同心环数量 0/1/2
    :param bg: 背景色；None 表示不画背景（透明）
    :param rounded: 是否给背景加 22.4% 圆角
    :param eye_r: 眼点半径（源图坐标系）；None 用默认值
    :param fg: 盘与环的填充色。bg 为浅色时必须改为品牌色，否则图形不可见
    :return: SVG 全文
    """
    lines = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{canvas:g}" '
        f'height="{canvas:g}" viewBox="0 0 {canvas:g} {canvas:g}">'
    ]
    if bg:
        rx = f' rx="{fmt(canvas * 0.224)}"' if rounded else ""
        lines.append(
            f'  <rect width="{canvas:g}" height="{canvas:g}"{rx} fill="{bg}"/>'
        )
    lines.extend(disc_with_duck(canvas, arcs, eye_r, fg))
    lines.append("</svg>")
    return "\n".join(lines)


def build_mono(canvas, arcs):
    """组装单色版：透明背景，图形用品牌色实心（鸭头为品牌色，非镂空）。

    单色版用于需要在任意底色上使用的场合，因此不能依赖背景透出，
    改为鸭头本身着色、盘与环省略。

    :param canvas: 画板边长
    :param arcs: 同心环数量
    :return: SVG 全文
    """
    k = canvas / SRC_CANVAS
    lines = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{canvas:g}" '
        f'height="{canvas:g}" viewBox="0 0 {canvas:g} {canvas:g}">'
    ]
    if arcs >= 2:
        lines.append(
            f'  <path d="{ring(canvas, R_OUTER_RING_OUT, R_OUTER_RING_IN)}" '
            f'fill="{BRAND}" fill-rule="evenodd"/>'
        )
    if arcs >= 1:
        lines.append(
            f'  <path d="{ring(canvas, R_INNER_RING_OUT, R_INNER_RING_IN)}" '
            f'fill="{BRAND}" fill-rule="evenodd"/>'
        )
    # 单色版鸭头着色，眼点挖空（用背景透出）
    lines.append(
        f'  <path d="{transform_head(canvas)}" fill="{BRAND}"/>'
    )
    lines.append(
        f'  <circle cx="{fmt(EYE_CENTER[0] * k)}" cy="{fmt(EYE_CENTER[1] * k)}" '
        f'r="{fmt(EYE_R * k)}" fill="#FFFFFF"/>'
    )
    lines.append("</svg>")
    return "\n".join(lines)


def build_lockup(vertical=False):
    """组装图文组合 logo（符号 + 文字）。

    符号用 full 档（两环），文字为占位矩形块——真实字形须由设计师用品牌字体
    排版后转曲，此处不伪造字形，只锁定符号与文字的相对尺寸与间距关系。

    :param vertical: True 为竖版（符号在上文字在下），False 为横版
    :return: SVG 全文
    """
    sym = 240.0  # 符号占位边长
    gap = sym * 0.25  # 符号与文字的间距 = 符号的 25%
    text_h = sym * 0.30  # 文字高度 = 符号的 30%
    text_w = text_h * 4.2  # 四字中文的近似宽高比

    if vertical:
        w = max(sym, text_w)
        h = sym + gap + text_h
        sym_x = (w - sym) / 2
        txt_x = (w - text_w) / 2
        txt_y = sym + gap
        sym_y = 0.0
    else:
        w = sym + gap + text_w
        h = sym
        sym_x = 0.0
        sym_y = 0.0
        txt_x = sym + gap
        txt_y = (h - text_h) / 2

    k = sym / SRC_CANVAS
    lines = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w:g}" height="{h:g}" '
        f'viewBox="0 0 {w:g} {h:g}">'
    ]
    # 符号整体作为一个 group 平移到位
    lines.append(f'  <g transform="translate({fmt(sym_x)} {fmt(sym_y)})">')
    lines.append(
        f'    <rect width="{sym:g}" height="{sym:g}" '
        f'rx="{fmt(sym * 0.224)}" fill="{BRAND}"/>'
    )
    for part in disc_with_duck(sym, 2):
        lines.append("  " + part)
    lines.append("  </g>")
    # 文字占位：注明须由设计师替换为转曲字形
    lines.append(
        f'  <rect x="{fmt(txt_x)}" y="{fmt(txt_y)}" width="{fmt(text_w)}" '
        f'height="{fmt(text_h)}" rx="{fmt(text_h * 0.12)}" fill="{BRAND}" '
        f'opacity="0.18"/>'
    )
    lines.append(
        f'  <!-- 文字占位：设计师须用品牌字体排版「顺手邻里」并转曲后替换本 rect，'
        f'保持高度 {fmt(text_h)} 与符号间距 {fmt(gap)} 不变 -->'
    )
    lines.append("</svg>")
    return "\n".join(lines)


def build_splash(w=390, h=844):
    """组装启动页：品牌色满屏 + 居中符号。

    符号尺寸取屏幕宽度的 34%，位置在垂直方向偏上（40% 处），为下方
    的加载指示与版权信息留出空间。不含任何文案，文案由运行时渲染。

    :param w: 屏幕宽
    :param h: 屏幕高
    :return: SVG 全文
    """
    sym = w * 0.34
    sym_x = (w - sym) / 2
    sym_y = h * 0.40 - sym / 2

    lines = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w:g}" height="{h:g}" '
        f'viewBox="0 0 {w:g} {h:g}">',
        f'  <rect width="{w:g}" height="{h:g}" fill="{BRAND}"/>',
        f'  <g transform="translate({fmt(sym_x)} {fmt(sym_y)})">',
    ]
    # 启动页符号不加圆角底板（整屏已是品牌色），直接画白色盘环与鸭头
    for part in disc_with_duck(sym, 2):
        lines.append("  " + part)
    lines.append("  </g>")
    lines.append("</svg>")
    return "\n".join(lines)


def build_empty_state(size=240):
    """组装空状态插画：低透明度的品牌色符号。

    仅图形不含文案——文案随场景变化（无搜索结果／无收藏／无发布等），
    由调用方在插画下方另行渲染。

    :param size: 画板边长
    :return: SVG 全文
    """
    lines = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{size:g}" '
        f'height="{size:g}" viewBox="0 0 {size:g} {size:g}">',
        f'  <g opacity="0.28">',
    ]
    k = size / SRC_CANVAS
    # 空状态用品牌色实心鸭头 + 品牌色环，不用白色（背景是浅色页面）
    lines.append(
        f'    <path d="{ring(size, R_OUTER_RING_OUT, R_OUTER_RING_IN)}" '
        f'fill="{BRAND}" fill-rule="evenodd"/>'
    )
    lines.append(
        f'    <path d="{ring(size, R_INNER_RING_OUT, R_INNER_RING_IN)}" '
        f'fill="{BRAND}" fill-rule="evenodd"/>'
    )
    lines.append(f'    <path d="{transform_head(size)}" fill="{BRAND}"/>')
    lines.append(
        f'    <circle cx="{fmt(EYE_CENTER[0] * k)}" cy="{fmt(EYE_CENTER[1] * k)}" '
        f'r="{fmt(EYE_R * k)}" fill="#FFFFFF"/>'
    )
    lines.append("  </g>")
    lines.append("  <!-- 空状态插画只含图形，文案由调用方按场景渲染 -->")
    lines.append("</svg>")
    return "\n".join(lines)


def build_android_foreground(canvas=1024):
    """组装 Android 自适应图标前景层。

    Android 把前景层叠在背景层之上，因此前景层不能沿用「镂空鸭头透出底色」
    的做法——镂空处透出的是背景层的品牌色，与鸭头本身该有的品牌色相同，
    等于鸭头不可见。这里改为：白色盘环 + 品牌色实心鸭头 + 白色眼点，
    三者自身即构成完整对比，不依赖背景层。

    安全区为画板中心的 66%（系统遮罩可能裁掉外围），故符号缩至 66% 居中。

    :param canvas: 画板边长
    :return: SVG 全文
    """
    safe = 0.66
    inner = canvas * safe
    off = (canvas - inner) / 2
    k = inner / SRC_CANVAS
    lines = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{canvas:g}" '
        f'height="{canvas:g}" viewBox="0 0 {canvas:g} {canvas:g}">',
        f'  <!-- Android 自适应图标前景层：安全区 {safe*100:.0f}%，'
        f'符号缩至 {inner:g}px 居中，任意遮罩下均不被裁到。'
        f'鸭头用实心品牌色而非镂空，因为镂空会透出背景层的同色 -->',
        f'  <g transform="translate({fmt(off)} {fmt(off)})">',
    ]
    # 白色盘与环
    lines.append(
        f'    <path d="{ring(inner, R_OUTER_RING_OUT, R_OUTER_RING_IN)}" '
        f'fill="{WHITE}" fill-rule="evenodd"/>'
    )
    lines.append(
        f'    <path d="{ring(inner, R_INNER_RING_OUT, R_INNER_RING_IN)}" '
        f'fill="{WHITE}" fill-rule="evenodd"/>'
    )
    cx = CENTER[0] * k
    cy = CENTER[1] * k
    rd = R_DISC * k
    lines.append(
        f'    <path d="M{fmt(cx - rd)} {fmt(cy)} '
        f'A{fmt(rd)} {fmt(rd)} 0 1 0 {fmt(cx + rd)} {fmt(cy)} '
        f'A{fmt(rd)} {fmt(rd)} 0 1 0 {fmt(cx - rd)} {fmt(cy)} Z" fill="{WHITE}"/>'
    )
    # 品牌色实心鸭头压在白盘上
    lines.append(f'    <path d="{transform_head(inner)}" fill="{BRAND}"/>')
    lines.append(
        f'    <circle cx="{fmt(EYE_CENTER[0] * k)}" cy="{fmt(EYE_CENTER[1] * k)}" '
        f'r="{fmt(EYE_R * k)}" fill="{WHITE}"/>'
    )
    lines.append("  </g>")
    lines.append("</svg>")
    return "\n".join(lines)


def build_android_background(canvas=1024):
    """组装 Android 自适应图标背景层：纯品牌色满屏。

    背景层不加圆角，由系统遮罩决定最终形状。

    :param canvas: 画板边长
    :return: SVG 全文
    """
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{canvas:g}" '
        f'height="{canvas:g}" viewBox="0 0 {canvas:g} {canvas:g}">\n'
        f'  <rect width="{canvas:g}" height="{canvas:g}" fill="{BRAND}"/>\n'
        f"</svg>"
    )


def write(name, content):
    """写入 SVG 文件并返回字节数。"""
    path = os.path.join(OUT_DIR, name)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(content)
    return len(content.encode("utf-8"))


if __name__ == "__main__":
    manifest = {}
    # 三个降级档位（PRD §1.4.1.2，最小适用尺寸经实测抬高为 96/64/40）：
    #   full    >= 96px  两环
    #   compact >= 64px  一环
    #   mini    >= 40px  无环，眼点放大到 5% 以过 2px 硬约束
    manifest["duck-symbol-full.svg"] = write(
        "duck-symbol-full.svg", build_symbol(1024, 2, BRAND)
    )
    manifest["duck-symbol-compact.svg"] = write(
        "duck-symbol-compact.svg", build_symbol(1024, 1, BRAND)
    )
    manifest["duck-symbol-mini.svg"] = write(
        "duck-symbol-mini.svg", build_mini_symbol(1024)
    )
    # 反白版：白底 + 品牌色图形。前景必须显式传品牌色，否则白底白图全不可见
    manifest["duck-symbol-inverse.svg"] = write(
        "duck-symbol-inverse.svg", build_symbol(1024, 2, WHITE, fg=BRAND)
    )
    # 单色版：透明底
    manifest["duck-symbol-mono.svg"] = write(
        "duck-symbol-mono.svg", build_mono(1024, 2)
    )
    # 图文组合
    manifest["logo-horizontal.svg"] = write("logo-horizontal.svg", build_lockup(False))
    manifest["logo-vertical.svg"] = write("logo-vertical.svg", build_lockup(True))
    # 启动页与空状态
    manifest["splash.svg"] = write("splash.svg", build_splash())
    manifest["empty-state.svg"] = write("empty-state.svg", build_empty_state())
    # App 图标：iOS 不预加圆角（系统自行遮罩）
    manifest["app-icon-ios.svg"] = write(
        "app-icon-ios.svg", build_symbol(1024, 2, BRAND, rounded=False)
    )
    manifest["app-icon-android-background.svg"] = write(
        "app-icon-android-background.svg", build_android_background()
    )
    manifest["app-icon-android-foreground.svg"] = write(
        "app-icon-android-foreground.svg", build_android_foreground()
    )

    print(json.dumps(manifest, ensure_ascii=False, indent=2))
    print(f"\nwrote {len(manifest)} files to {OUT_DIR}")
