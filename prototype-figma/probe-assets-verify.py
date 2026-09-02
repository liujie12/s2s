"""渲染全部 12 个素材并做几何与视觉校验。

本脚本存在的理由：上一轮交付失败正是因为「只验数据不看图」——验了 SVG 语法、
路径数、与另一份副本的一致性，却从未验证渲染结果像不像鸭子。因此这里同时做
数值校验与位图输出，位图必须人工过目。

校验项：
1. 全部素材可解析且渲染非空；
2. full 档与源图中心区 IoU >= 0.85（形状未漂移）；
3. 三档位在其最小适用尺寸下，眼点与环宽均 >= 2px（PRD §1.4.1.2）；
4. mini 档眼点确已放大（与 full 档半径不同）；
5. Android 前景层图形完整落在 66% 安全区内；
6. 拼合一张总览图便于一次看完。
"""

import os
import re
import sys

try:
    import cv2
    import numpy as np
except ModuleNotFoundError as exc:
    # 裸抛 ModuleNotFoundError 看不出该装什么，也看不出「装不上时还能怎么验」。
    # PRD §1.4.1.2 把本探针的实测值引为权威依据，故这里必须指明替代核验路径，
    # 否则依赖一缺，那些阈值就成了无人能复核的历史数字。
    print('[缺依赖] ' + str(exc))
    print('装：pip install -r prototype-figma/requirements-assets.txt')
    print('若 cairosvg 因 GTK 原生库装不上：SVG 里的几何常量可直接读文本核算，')
    print('例如 mini 档眼点 24px 折算 = r × 2 ÷ 1024 × 24（duck-symbol-mini.svg）。')
    sys.exit(2)

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from importlib.machinery import SourceFileLoader

# 复用渲染器，避免重复实现 SVG 光栅化
_verify = SourceFileLoader(
    "render_verify",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "probe-render-verify.py"),
).load_module()
render_svg = _verify.render_svg
iou = _verify.iou

ASSETS = r"d:\developer\code\aicoding\s2s\prototype-figma\assets"
SOURCE = os.path.join(ASSETS, "source", "ip-4b-source.png")
OUT_DIR = os.path.join(ASSETS, "render")

FILES = [
    "duck-symbol-full.svg",
    "duck-symbol-compact.svg",
    "duck-symbol-mini.svg",
    "duck-symbol-inverse.svg",
    "duck-symbol-mono.svg",
    "logo-horizontal.svg",
    "logo-vertical.svg",
    "splash.svg",
    "empty-state.svg",
    "app-icon-ios.svg",
    "app-icon-android-background.svg",
    "app-icon-android-foreground.svg",
]

passed, failed = [], []


def check(label, ok, detail=""):
    """记录一项校验结果。"""
    (passed if ok else failed).append(f"{label} | {detail}")
    print(("PASS  " if ok else "FAIL  ") + label + (f"  [{detail}]" if detail else ""))


os.makedirs(OUT_DIR, exist_ok=True)

# --- 1. 全部渲染 ---
rendered = {}
for name in FILES:
    path = os.path.join(ASSETS, name)
    with open(path, encoding="utf-8") as fh:
        svg = fh.read()
    # 渲染器按长边归一化到 512，非方形素材自动等比，无需再裁
    size = 512
    img = render_svg(svg, size)
    out = os.path.join(OUT_DIR, name.replace(".svg", ".png"))
    cv2.imwrite(out, img)
    rendered[name] = img
    nonwhite = int((cv2.cvtColor(img, cv2.COLOR_BGR2GRAY) < 250).sum())
    check(f"render {name}", nonwhite > 1000, f"{nonwhite} non-white px")

# --- 2. full 档与源图形状比对 ---
src = cv2.resize(cv2.imread(SOURCE), (512, 512), interpolation=cv2.INTER_AREA)
src_white = cv2.cvtColor(src, cv2.COLOR_BGR2GRAY) > 199
full_white = cv2.cvtColor(rendered["duck-symbol-full.svg"], cv2.COLOR_BGR2GRAY) > 199
center = np.zeros((512, 512), dtype=np.uint8)
cv2.circle(center, (256, 253), 205, 1, -1)
cm = center.astype(bool)
score = iou(src_white & cm, full_white & cm)
check("full vs source center IoU >= 0.85", score >= 0.85, f"IoU={score:.4f}")

# --- 3. 各档位在最小适用尺寸下的 2px 硬约束 ---
SRC_CANVAS = 1024.0
EYE_R = 20.27
# mini 档眼点半径不是「把 EYE_R 调大」，而是鸭头居中放大到占画板 72% 后
# 眼点随同一仿射变换所得，再抬到 24px 下 2px 的底线（build-4b-assets.py）。
EYE_R_MINI = 42.67
RING_W = 395.84 - 361.87
RING_GAP = 361.87 - 305.84

for label, min_px, arcs, eye_r in [
    ("full", 96, 2, EYE_R),
    ("compact", 64, 1, EYE_R),
    # mini 档最小适用尺寸是 24px（底部 Tab 实际用法），不是 40px
    ("mini", 24, 0, EYE_R_MINI),
]:
    k = min_px / SRC_CANVAS
    eye_px = eye_r * 2 * k
    check(f"{label}@{min_px}px eye >= 2px", eye_px >= 2.0, f"{eye_px:.2f}px")
    if arcs >= 1:
        rw = RING_W * k
        rg = RING_GAP * k
        check(f"{label}@{min_px}px ring width >= 2px", rw >= 2.0, f"{rw:.2f}px")
        check(f"{label}@{min_px}px ring gap >= 2px", rg >= 2.0, f"{rg:.2f}px")

# --- 4. mini 档结构：鸭头实体放大 + 眼点满足 24px 底线 ---
# 这一节原来写成「mini 眼点 r > full 眼点 r * 1.2」，正则取的是文件里第一个
# <circle> —— mini 档改版后第一个 circle 是铺满画板的圆盘（r=504），
# 断言拿圆盘半径跟眼点比，永远通过，是个假通过。改为按结构逐项验。
with open(os.path.join(ASSETS, "duck-symbol-mini.svg"), encoding="utf-8") as fh:
    mini_svg = fh.read()
mini_circles = re.findall(
    r'<circle cx="([\d.]+)" cy="([\d.]+)" r="([\d.]+)" fill="(#[0-9A-Fa-f]+)"', mini_svg
)
check("mini has disc + eye (2 circles)", len(mini_circles) == 2, str(len(mini_circles)))
if len(mini_circles) == 2:
    disc_c, eye_c = mini_circles
    # 圆盘须铺满画板：直径 >= 画板 97%，否则鸭头拿不到足够像素（改版的初衷）
    disc_ratio = float(disc_c[2]) * 2 / SRC_CANVAS
    check("mini disc fills canvas (>=97%)", disc_ratio >= 0.97, f"{disc_ratio:.3f}")
    # 眼点在 24px 下须 >= 2px
    eye_px_24 = float(eye_c[2]) * 2 * 24 / SRC_CANVAS
    check("mini@24px eye >= 2px (measured)", eye_px_24 >= 2.0, f"{eye_px_24:.2f}px")
    # 眼点须是主色：鸭头已反相为白色实体，白眼点会与鸭头融为一体
    check("mini eye is brand color", eye_c[3].upper() == "#0B7C8C", eye_c[3])
# 鸭头须是白色实体（非镂空）：前景层镂空透出的是底色，形状会消失
mini_paths = re.findall(r'<path d="([^"]+)" fill="(#[0-9A-Fa-f]+)"', mini_svg)
check("mini duck head is solid white", len(mini_paths) == 1
      and mini_paths[0][1].upper() == "#FFFFFF",
      f"{len(mini_paths)} paths")
# 鸭头须占画板 80% 上下：用渲染掩码实测而非读路径数字。
# 掩码须限定在圆盘内 —— 圆盘之外是透明区，渲染器把透明画成白，
# 不排除的话四角会被算进白色区域，量出来的永远是满画板。
# 基准从 72% 抬到 80%（2026-08-26，用户要求鸭头更醒目）。注意：span 只是
# 结果，真正卡住上限的是下一条环带宽度断言 —— 别只看 span 就往上抬。
mini_img = rendered["duck-symbol-mini.svg"]
head_mask = cv2.inRange(mini_img, np.array([245, 245, 245]), np.array([255, 255, 255]))
gy, gx = np.ogrid[:512, :512]
inside_disc = (gx - 256) ** 2 + (gy - 256) ** 2 <= (0.97 * 256) ** 2
head_in_disc = head_mask & inside_disc.astype(np.uint8)
hys, hxs = np.nonzero(head_in_disc)
if hxs.size:
    span = max(hxs.max() - hxs.min(), hys.max() - hys.min()) / 512.0
    check("mini head spans ~80% of canvas", 0.76 <= span <= 0.84, f"{span:.3f}")
else:
    check("mini head spans ~80% of canvas", False, "empty white region")
# 主色环带宽度：鸭头最远点到圆盘边缘的余量。这是 ratio 的真正上限约束 ——
# 环带是「这是一枚按钮」的体量感载体，24px 下不足 1px 会断续，实测
# 0.80 → 1.90px（达标）、0.84 → 1.42px、0.88 → 0.93px（喙尖捅破圆盘）。
# 上一轮只测了笔画粗细没测这里，才误判 88% 可行，故固化成守门人。
if hxs.size:
    r_disc = float(mini_circles[0][2]) * 512 / SRC_CANVAS if mini_circles else 252.0
    dist = np.sqrt((hxs - 256.0) ** 2 + (hys - 256.0) ** 2)
    inside = dist <= r_disc * 0.995   # 排除圆盘外抗锯齿溢出的白像素
    band_px_24 = (r_disc - dist[inside].max()) / 512.0 * 24.0
    check("mini@24px brand ring >= 1.5px", band_px_24 >= 1.5, f"{band_px_24:.2f}px")

# --- 5. 环数校验：full=2 / compact=1 / mini=0 ---
for name, want in [("duck-symbol-full.svg", 2), ("duck-symbol-compact.svg", 1),
                   ("duck-symbol-mini.svg", 0)]:
    with open(os.path.join(ASSETS, name), encoding="utf-8") as fh:
        txt = fh.read()
    # 环是 evenodd 的双圆 path，含 4 段 A 弧；盘+鸭头那个 path 只含 2 段 A
    ring_paths = sum(1 for m in re.finditer(r'<path d="([^"]+)"', txt)
                     if m.group(1).count("A") == 4)
    check(f"{name} ring count == {want}", ring_paths == want, f"got {ring_paths}")

# --- 6. Android 前景层落在 66% 安全区内 ---
fg = rendered["app-icon-android-foreground.svg"]
fg_gray = cv2.cvtColor(fg, cv2.COLOR_BGR2GRAY)
# 前景层背景透明 -> 渲染为白；图形为白色盘环 + 品牌色鸭头，取非纯白为图形
fg_mask = fg_gray < 250
ys, xs = np.nonzero(fg_mask)
if xs.size:
    margin = 512 * (1 - 0.66) / 2
    inside = (xs.min() >= margin - 3 and ys.min() >= margin - 3
              and xs.max() <= 512 - margin + 3 and ys.max() <= 512 - margin + 3)
    check("android fg inside 66% safe area", inside,
          f"bbox=({xs.min()},{ys.min()},{xs.max()},{ys.max()}) margin={margin:.0f}")
else:
    check("android fg inside 66% safe area", False, "empty render")

# --- 7. iOS 图标不含预设圆角 ---
with open(os.path.join(ASSETS, "app-icon-ios.svg"), encoding="utf-8") as fh:
    ios = fh.read()
check("ios icon has no rx (system masks)", 'rx=' not in ios)

# --- 8. 小尺寸压测图 ---
for label, name in [("full", "duck-symbol-full.svg"),
                    ("compact", "duck-symbol-compact.svg"),
                    ("mini", "duck-symbol-mini.svg")]:
    img = rendered[name]
    for px in [96, 64, 40, 24]:
        small = cv2.resize(img, (px, px), interpolation=cv2.INTER_AREA)
        big = cv2.resize(small, (px * 6, px * 6), interpolation=cv2.INTER_NEAREST)
        cv2.imwrite(os.path.join(OUT_DIR, f"stress-{label}-{px}px.png"), big)

# --- 9. 总览拼图 ---
cell = 200
cols = 4
rows = (len(FILES) + cols - 1) // cols
sheet = np.full((rows * (cell + 26), cols * cell, 3), 245, dtype=np.uint8)
for i, name in enumerate(FILES):
    r, c = divmod(i, cols)
    img = rendered[name]
    ih, iw = img.shape[:2]
    scale = min(cell / iw, cell / ih)
    nw, nh = int(iw * scale), int(ih * scale)
    small = cv2.resize(img, (nw, nh), interpolation=cv2.INTER_AREA)
    y0 = r * (cell + 26)
    x0 = c * cell + (cell - nw) // 2
    sheet[y0:y0 + nh, x0:x0 + nw] = small
    cv2.putText(sheet, name.replace(".svg", "").replace("duck-symbol-", "")[:24],
                (c * cell + 4, y0 + cell + 17), cv2.FONT_HERSHEY_SIMPLEX, 0.38,
                (40, 40, 40), 1, cv2.LINE_AA)
cv2.imwrite(os.path.join(OUT_DIR, "contact-sheet.png"), sheet)
print(f"\ncontact sheet -> {os.path.join(OUT_DIR, 'contact-sheet.png')}")

print(f"\n{len(passed)} passed, {len(failed)} failed")
if failed:
    for f in failed:
        print("  FAILED:", f)
    sys.exit(1)
