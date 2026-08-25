"""从抠出的鸭头位图中量取几何基准，供构建规范化 SVG 使用。

矢量化输出忠实记录了位图锯齿，眼点因此变成数十段抖动曲线。本脚本直接从
位图测量眼点的圆心与半径（改用解析圆替代拟合曲线），并测量鸭头外轮廓的
包围盒、喙尖位置、颈部最低点，用于后续按 PRD 几何基准归一化。
"""

import cv2
import numpy as np

SRC = r"d:\developer\code\aicoding\s2s\prototype-figma\assets\source\ip-4b-duckhead-extract.png"

img = cv2.imread(SRC, cv2.IMREAD_GRAYSCALE)
h, w = img.shape
# 抠图产物为「黑图形 + 白底」，取暗部为前景
mask = (img < 128).astype(np.uint8) * 255

contours, hierarchy = cv2.findContours(mask, cv2.RETR_TREE, cv2.CHAIN_APPROX_NONE)
flat = hierarchy[0]

outer = None
hole = None
for i, c in enumerate(contours):
    if int(flat[i][3]) == -1:
        outer = c
    else:
        hole = c

print(f"source size: {w} x {h}")

ox, oy, ow, oh = cv2.boundingRect(outer)
print(f"outer bbox: x={ox} y={oy} w={ow} h={oh}")
print(f"outer area: {cv2.contourArea(outer):.0f}")

# 眼点：用最小外接圆测量，圆度用 面积/(pi r^2) 校验
(ex, ey), er = cv2.minEnclosingCircle(hole)
hole_area = cv2.contourArea(hole)
circularity = hole_area / (np.pi * er * er)
print(f"eye circle: cx={ex:.2f} cy={ey:.2f} r={er:.2f}")
print(f"eye area={hole_area:.0f} circularity={circularity:.4f}")

# 眼点相对外轮廓包围盒的归一化位置，便于换算到 1024 画板
print(f"eye rel to outer bbox: rx={(ex-ox)/ow:.4f} ry={(ey-oy)/oh:.4f} r_ratio={er/max(ow,oh):.4f}")

pts = outer.reshape(-1, 2)
# 喙尖 = 最右点；颈部最低点 = 最下点
rightmost = pts[pts[:, 0].argmax()]
bottommost = pts[pts[:, 1].argmax()]
leftmost = pts[pts[:, 0].argmin()]
topmost = pts[pts[:, 1].argmin()]
print(f"rightmost (beak tip): {rightmost}")
print(f"bottommost (neck):    {bottommost}")
print(f"leftmost:             {leftmost}")
print(f"topmost:              {topmost}")

# 头部主圆：对包围盒左侧 60% 区域内的轮廓点拟合圆心半径
head_pts = pts[pts[:, 0] < ox + ow * 0.55]
(hx, hy), hr = cv2.minEnclosingCircle(head_pts.reshape(-1, 1, 2))
print(f"head circle (left 55%): cx={hx:.2f} cy={hy:.2f} r={hr:.2f}")
print(f"head r / outer w = {hr/ow:.4f}")

# 量喙的上下缘：在喙尖内侧若干列上，取该列前景的最上与最下行
print("\nbeak vertical extent by column (x from tip going left):")
tip_x = int(rightmost[0])
for dx in [2, 10, 20, 35, 50, 70, 95, 120]:
    col_x = tip_x - dx
    if col_x < 0 or col_x >= w:
        continue
    col = np.nonzero(mask[:, col_x])[0]
    if col.size == 0:
        print(f"  x={col_x} (tip-{dx}): empty")
        continue
    print(f"  x={col_x} (tip-{dx}): top={col.min()} bottom={col.max()} thickness={col.max()-col.min()+1}")
