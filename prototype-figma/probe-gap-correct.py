"""正确测量鸭头右侧凹口（喙与颈之间的开口）的宽度。

前一版用逐行扫描找「同一行内前景块之间的间隙」，测到的 9px 实际是喙尖
附近的锯齿噪声，不是真正的凹口。这里改用距离变换：凹口是背景区域，其
内部各点到最近前景的距离乘 2 即为该处的局部宽度，取凹口区域内的最大值
即为凹口最宽处，取其「颈口」处的宽度才是关键约束。

同时给出凹口的连通域面积与包围盒，便于确认测的是同一个区域。
"""

import cv2
import numpy as np

SRC = r"d:\developer\code\aicoding\s2s\prototype-figma\assets\source\ip-4b-duckhead-extract.png"
HEAD_W_IN_SRC = 693 - 328
CANVAS = 1024.0

img = cv2.imread(SRC, cv2.IMREAD_GRAYSCALE)
h, w = img.shape
fg = (img < 128).astype(np.uint8)

ys, xs = np.nonzero(fg)
bbox_w = xs.max() - xs.min() + 1
px_to_src = HEAD_W_IN_SRC / bbox_w
print(f"抠图 {w}x{h}  前景包围盒宽 {bbox_w}  抠图1px = 源图 {px_to_src:.4f}px")

# 背景连通域：外部背景 + 眼点 + 右侧凹口
bg = 1 - fg
n, labels, stats, cents = cv2.connectedComponentsWithStats(bg, connectivity=4)
print(f"\n背景连通域 {n} 个：")
for i in range(1, n):
    x, y, bw, bh, area = stats[i]
    touches = x <= 0 or y <= 0 or x + bw >= w or y + bh >= h
    print(f"  #{i}: bbox=({x},{y},{bw},{bh}) area={area} "
          f"touches_border={touches} center=({cents[i][0]:.0f},{cents[i][1]:.0f})")

# 凹口 = 与边界相连的背景中，位于图形右侧的那部分。
# 外部背景是一整块，凹口与它连通，因此改用凸包差集来定位凹口。
contours, _ = cv2.findContours(fg, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
outer = max(contours, key=cv2.contourArea)
hull = cv2.convexHull(outer)

filled = np.zeros((h, w), dtype=np.uint8)
cv2.drawContours(filled, [outer], -1, 1, -1)
hull_mask = np.zeros((h, w), dtype=np.uint8)
cv2.drawContours(hull_mask, [hull], -1, 1, -1)

# 凹陷区 = 凸包内但不属于图形的部分
concave = ((hull_mask == 1) & (filled == 0)).astype(np.uint8)
cn, clabels, cstats, ccents = cv2.connectedComponentsWithStats(concave, connectivity=8)
print(f"\n凹陷区连通域 {cn-1} 个（凸包内减去图形）：")
regions = []
for i in range(1, cn):
    x, y, bw, bh, area = cstats[i]
    if area < 50:
        continue
    regions.append((i, x, y, bw, bh, area))
    print(f"  #{i}: bbox=({x},{y},{bw},{bh}) area={area} center=({ccents[i][0]:.0f},{ccents[i][1]:.0f})")

if not regions:
    raise SystemExit("未找到凹陷区")

# 取面积最大的凹陷区（即喙颈开口）
main = max(regions, key=lambda r: r[5])
mi, mx, my, mbw, mbh, marea = main
print(f"\n主凹口 #{mi}: bbox=({mx},{my},{mbw},{mbh}) area={marea}")

region = (clabels == mi).astype(np.uint8)

# 距离变换测局部宽度：对图形做距离变换，凹口内点到最近前景的距离*2 = 局部宽度
dist = cv2.distanceTransform((1 - fg).astype(np.uint8), cv2.DIST_L2, 5)
region_dist = dist * region
max_w = region_dist.max() * 2
print(f"凹口最宽处（距离变换）= {max_w:.2f}px -> 源图 {max_w*px_to_src:.2f}px "
      f"-> 占比 {max_w*px_to_src/CANVAS*100:.3f}%")

# 「颈口」宽度：凹口在其开口边（最右侧）的纵向跨度
right_col = mx + mbw - 1
for probe in range(right_col, max(0, right_col - 30), -1):
    col = np.nonzero(region[:, probe])[0]
    if col.size > 0:
        span = col.max() - col.min() + 1
        print(f"凹口开口处 x={probe}: 纵向跨度 {span}px -> 源图 {span*px_to_src:.2f}px "
              f"-> 占比 {span*px_to_src/CANVAS*100:.3f}%")
        break

# 各显示尺寸下凹口最宽处的像素值
print("\n各尺寸下凹口最宽处：")
ratio = max_w * px_to_src / CANVAS
for px in [128, 96, 64, 48, 40, 24]:
    v = ratio * px
    print(f"  {px:>3}px -> {v:>6.2f}px  {'OK' if v >= 2 else 'VIOLATION'}")
