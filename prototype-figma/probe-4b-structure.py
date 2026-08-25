"""量取 4B 源图的整体构成几何：中心白盘、两道白环、鸭头与眼点。

源图的圆盘与两道环本应是完美同心圆，矢量化会把位图锯齿忠实记录成抖动曲线。
因此这里直接测量它们的圆心与半径，后续用解析圆重建；只有鸭头这个有机形
才保留矢量化路径。所有结果同时给出「相对 1024 画板」的归一化值。
"""

import cv2
import numpy as np

SRC = r"d:\developer\code\aicoding\s2s\prototype-figma\assets\source\ip-4b-source.png"

img = cv2.imread(SRC)
h, w = img.shape[:2]
gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
# 白色为前景（喙/环/盘都是白的）
white = (gray > 199).astype(np.uint8) * 255

print(f"canvas: {w} x {h}")

# --- 沿水平中线扫描，白色区段的边界即为各圆环的内外半径 ---
# 鸭头位于中心偏下，取一条避开鸭头的扫描线：用图形垂直中心上方一点
def scan_row(y):
    """返回该行上白色区段的 [起, 止] 列表。"""
    row = white[y] > 0
    segs = []
    start = None
    for x in range(w):
        if row[x] and start is None:
            start = x
        elif not row[x] and start is not None:
            segs.append((start, x - 1))
            start = None
    if start is not None:
        segs.append((start, w - 1))
    return segs


# 先找整体白色结构的垂直中心
ys, xs = np.nonzero(white)
cy_all = (ys.min() + ys.max()) / 2
cx_all = (xs.min() + xs.max()) / 2
print(f"white bbox: x=[{xs.min()},{xs.max()}] y=[{ys.min()},{ys.max()}]")
print(f"white center: ({cx_all:.1f}, {cy_all:.1f})")

for y in [int(cy_all), 140, 200, 300]:
    segs = scan_row(y)
    print(f"\nrow y={y}: {len(segs)} white segments")
    for s in segs:
        print(f"   [{s[0]:4d}, {s[1]:4d}]  width={s[1]-s[0]+1:3d}  "
              f"dist_from_cx={abs((s[0]+s[1])/2 - cx_all):.1f}")

# --- 用层级轮廓分离各结构 ---
contours, hierarchy = cv2.findContours(white, cv2.RETR_TREE, cv2.CHAIN_APPROX_NONE)
flat = hierarchy[0]


def depth_of(i):
    """计算轮廓嵌套深度。"""
    d = 0
    p = int(flat[i][3])
    while p != -1:
        d += 1
        p = int(flat[p][3])
    return d


print("\n--- contours (area >= 500) ---")
rows = []
for i, c in enumerate(contours):
    area = abs(cv2.contourArea(c))
    if area < 500:
        continue
    (ccx, ccy), cr = cv2.minEnclosingCircle(c)
    peri = cv2.arcLength(c, True)
    # 圆度：4*pi*A/P^2，越接近 1 越圆
    circ = 4 * np.pi * area / (peri * peri) if peri > 0 else 0
    rows.append((i, depth_of(i), area, ccx, ccy, cr, circ))

for i, d, area, ccx, ccy, cr, circ in sorted(rows, key=lambda r: -r[2]):
    print(f"  #{i:2d} depth={d} area={area:9.0f} center=({ccx:6.1f},{ccy:6.1f}) "
          f"r={cr:6.2f} circularity={circ:.3f} r/1024={cr/1024:.4f}")
