﻿"""渲染 Tab 图标候选对照图，供人工挑选。

不凭图标名猜形状 —— Material Symbols 同名图标在 fill1 变体下的实际笔画
只有渲染出来才知道 24px 下会不会粘连。本脚本把候选按真实消费尺寸
（24px 图标 + 底部 Tab 实际布局）渲染成 PNG，直接看。

实测淘汰记录（见 PRD §10.2）：
- travel_explore：24px 下放大镜与地球经纬线粘连成不可辨色块；
- account_circle：24px 下内部头像与圆底边缘粘连。
"""

import os

import cv2
import numpy as np
from importlib.machinery import SourceFileLoader

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "assets", "render")

_v = SourceFileLoader(
    "probe_render_verify", os.path.join(HERE, "probe-render-verify.py")
).load_module()

BRAND = "#0B7C8C"
SECONDARY = "#6B7280"
MS_VB = "0 -960 960 960"

# Material Symbols Outlined 官方路径（fill1 / 24px），取自
# https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/{name}/fill1/24px.svg
# 直接内联而不读外部 JSON：脚本要能独立复跑，临时文件会被清掉。
ICONS = {
    "map": "m600-120-240-84-186 72q-20 8-37-4.5T120-170v-560q0-13 7.5-23t20.5-15l212-72 240 84 186-72q20-8 37 4.5t17 33.5v560q0 13-7.5 23T812-192l-212 72Zm-40-98v-468l-160-56v468l160 56Z",
    "explore_nearby": "M491.5-243q5.5-3 8.5-9l4-9q26-48 65-82t69-79q15-23 23.5-50t8.5-56q0-79-55-135t-133-57q-77-1-133 53t-59 131q-2 32 6.5 61t25.5 53q30 45 70 78.5t64 82.5l4 9q3 6 8.5 9t11.5 3q6 0 11.5-3Zm-68-230.5Q400-497 400-530t23.5-56.5Q447-610 480-610t56.5 23.5Q560-563 560-530t-23.5 56.5Q513-450 480-450t-56.5-23.5ZM480-80q-83 0-156-31.5T197-197q-54-54-85.5-127T80-480q0-83 31.5-156T197-763q54-54 127-85.5T480-880q83 0 156 31.5T763-763q54 54 85.5 127T880-480q0 83-31.5 156T763-197q-54 54-127 85.5T480-80Z",
    "pin_drop": "M480-200Q339-304 269.5-402T200-594q0-125 78-205.5T480-880q124 0 202 80.5T760-594q0 94-69.5 192T480-200Zm0-320q33 0 56.5-23.5T560-600q0-33-23.5-56.5T480-680q-33 0-56.5 23.5T400-600q0 33 23.5 56.5T480-520ZM200-80v-80h560v80H200Z",
    "travel_explore": "M480-80q-83 0-156-31.5T197-197q-54-54-85.5-127T80-480q0-83 31.5-156T197-763q54-54 127-85.5T480-880q146 0 255.5 91.5T872-559h-82q-19-73-68.5-130.5T600-776v16q0 33-23.5 56.5T520-680h-80v80q0 17-11.5 28.5T400-560h-80v80h80v120h-40L168-552q-3 18-5.5 36t-2.5 36q0 131 92 225t228 95v80Zm364-20L716-228q-21 12-45 20t-51 8q-75 0-127.5-52.5T440-380q0-75 52.5-127.5T620-560q75 0 127.5 52.5T800-380q0 27-8 51t-20 45l128 128-56 56ZM691-309q29-29 29-71t-29-71q-29-29-71-29t-71 29q-29 29-29 71t29 71q29 29 71 29t71-29Z",
    "person": "M367-527q-47-47-47-113t47-113q47-47 113-47t113 47q47 47 47 113t-47 113q-47 47-113 47t-113-47ZM160-160v-112q0-34 17.5-62.5T224-378q62-31 126-46.5T480-440q66 0 130 15.5T736-378q29 15 46.5 43.5T800-272v112H160Z",
    "account_circle": "M234-276q51-39 114-61.5T480-360q69 0 132 22.5T726-276q35-41 54.5-93T800-480q0-133-93.5-226.5T480-800q-133 0-226.5 93.5T160-480q0 59 19.5 111t54.5 93Zm146.5-204.5Q340-521 340-580t40.5-99.5Q421-720 480-720t99.5 40.5Q620-639 620-580t-40.5 99.5Q539-440 480-440t-99.5-40.5ZM480-80q-83 0-156-31.5T197-197q-54-54-85.5-127T80-480q0-83 31.5-156T197-763q54-54 127-85.5T480-880q83 0 156 31.5T763-763q54 54 85.5 127T880-480q0 83-31.5 156T763-197q-54 54-127 85.5T480-80Z",
}


def icon_png(d, color, px):
    """把 Material Symbols 路径渲染成指定边长的位图。

    MS 坐标系是 "0 -960 960 960"（Y 轴负区间），而 render_svg 只认
    "0 0 W H"，故用 <g transform="translate(0 960)"> 挪到正区间。
    这只是渲染侧的等价变换，不改动路径数字本身。

    :param d: path 的 d 属性
    :param color: 填充色 #RRGGBB
    :param px: 输出边长
    :return: BGR ndarray
    """
    svg = (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="960" height="960" '
        f'viewBox="0 0 960 960">'
        f'<g transform="translate(0 960)"><path d="{d}" fill="{color}"/></g>'
        f"</svg>"
    )
    return _v.render_svg(svg, px)


def tab_cell(icon_img, label_px, active):
    """拼一个 Tab 单元格：图标 + 下方文字占位条，还原真实观感。

    文字用色条代替（渲染器不支持文本），只为看图标与文字的体量关系。

    :param icon_img: 已渲染的图标位图
    :param label_px: 文字占位条宽度
    :param active: 是否高亮态
    :return: BGR ndarray，130x64 的单元格
    """
    cell = np.full((64, 130, 3), 255, dtype=np.uint8)
    ih = icon_img.shape[0]
    y0, x0 = 10, (130 - ih) // 2
    roi = cell[y0:y0 + ih, x0:x0 + ih]
    # 图标位图白底，只把非白像素贴过去
    mask = cv2.cvtColor(icon_img, cv2.COLOR_BGR2GRAY) < 250
    roi[mask] = icon_img[mask]
    c = (140, 124, 11) if active else (128, 114, 107)
    cv2.rectangle(cell, ((130 - label_px) // 2, ih + 14),
                  ((130 + label_px) // 2, ih + 22), c, -1)
    return cell


if __name__ == "__main__":
    duck = open(os.path.join(HERE, "assets", "duck-symbol-mini.svg"), encoding="utf-8").read()

    left = ["map", "explore_nearby", "pin_drop", "travel_explore"]
    right = ["person", "account_circle"]

    # --- 单图标放大对照：看 24px 与 48px 下的笔画质量 ---
    for px in (24, 48):
        tiles = []
        for n in left + right:
            img = icon_png(ICONS[n], BRAND, px)
            pad = np.full((px + 20, px + 20, 3), 255, dtype=np.uint8)
            pad[10:10 + px, 10:10 + px] = img
            tiles.append(cv2.resize(pad, ((px + 20) * 4, (px + 20) * 4),
                                    interpolation=cv2.INTER_NEAREST))
        cv2.imwrite(os.path.join(OUT, f"tabicon-candidates-{px}px.png"),
                    np.hstack(tiles))
        print(f"tabicon-candidates-{px}px.png  ({len(tiles)} icons)")

    # --- 整条 Tab 栏对照：每个左键候选配一行，含真实中键鸭子 ---
    duck_img = _v.render_svg(duck, 24)
    rows = []
    for n in left:
        bar = np.full((64, 390, 3), 255, dtype=np.uint8)
        bar[0:1, :] = (235, 231, 229)  # 顶部分割线
        bar[:, 0:130] = tab_cell(icon_png(ICONS[n], BRAND, 24), 32, True)
        bar[:, 130:260] = tab_cell(duck_img, 32, False)
        bar[:, 260:390] = tab_cell(icon_png(ICONS["person"], SECONDARY, 24), 32, False)
        rows.append(cv2.resize(bar, (390 * 2, 64 * 2), interpolation=cv2.INTER_NEAREST))
    cv2.imwrite(os.path.join(OUT, "tabbar-candidates.png"), np.vstack(rows))
    print(f"tabbar-candidates.png  ({len(rows)} rows: {', '.join(left)})")
