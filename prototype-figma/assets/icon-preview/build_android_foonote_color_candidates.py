# -*- coding: utf-8 -*-
"""桌面图标「只换脚印色」候选渲染（2026-11-02 评审用）。

设计口径（用户原话）：找字保持白色填充不变，只改右上角脚印的颜色，
其他部位一律不动。本脚本复用 build_android_foonote 的几何与构图常量，
仅把 build_art() 拆成「找字掩膜（含隔离带挖空）」与「脚印掩膜」两层，
分别上色后再合成，保证候选渲染与正式出包几何完全一致。

输出（candidates-foonote-color/）：
  fp-<id>-legacy.png      512×512 圆角方块（teal 底，legacy 图标观感）
  fp-<id>-adaptive.png    512×512 圆形裁切（adaptive 图标在多数 ROM 的观感）
  overview-legacy.png     8 候选横排对比总览（圆角）
  overview-adaptive.png   8 候选横排对比总览（圆形）

注：本脚本只出评审图，不写 mipmap；定稿后才把 FP_COLOR 落进
build_android_foonote.py 正式重生成。
"""
import os

from PIL import Image, ImageChops, ImageDraw, ImageFont

from build_android_foonote import (
    ADAPTIVE_SAFE, BRAND, CANVAS, DOT_REL, FONT, GAP, SQUASH, SUPERSAMPLE,
    TEXT_CENTER, TEXT_SIZE, WHITE, X_OFFSET,
    FP_DOT_OFFSET_X, FP_DOT_OFFSET_Y,
    _draw_footprint_on_mask, dilate, foreground_layer, legacy_icon,
)

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "candidates-foonote-color")

# 候选色（id, 色名, RGB, 十六进制标注）；d1 为现状白对照
CANDIDATES = [
    ("d1", "现状白", (0xFF, 0xFF, 0xFF), "#FFFFFF"),
    ("d2", "深青",   (0x09, 0x5E, 0x6B), "#095E6B"),
    ("d3", "鸭黄",   (0xE8, 0xA8, 0x00), "#E8A800"),
    ("d4", "暖橙",   (0xF7, 0x67, 0x07), "#F76707"),
    ("d5", "橙红",   (0xFF, 0x6B, 0x35), "#FF6B35"),
    ("d6", "深炭",   (0x2F, 0x48, 0x58), "#2F4858"),
    ("d7", "藏青",   (0x1C, 0x4E, 0x80), "#1C4E80"),
    ("d8", "墨绿",   (0x2F, 0x6B, 0x4F), "#2F6B4F"),
]

DESKTOP_BG = (0xEC, 0xEF, 0xF1)   # 模拟 launcher 桌面浅灰底


def build_layers():
    """构建分离的找字/脚印掩膜（已居中、1024×1024）。

    与 build_android_foonote.build_art() 同一流程，唯一差异是不把脚印
    贴回找字掩膜，两层各自居中后返回。

    返回: (text_mask, fp_mask)，均为 "L" 模式 1024×1024。
    """
    s = SUPERSAMPLE
    size = CANVAS * s

    font = ImageFont.truetype(FONT, int(TEXT_SIZE * s))
    text_layer = Image.new("L", (size, size), 0)
    ImageDraw.Draw(text_layer).text(
        (TEXT_CENTER[0] * s, TEXT_CENTER[1] * s), "找",
        font=font, fill=255, anchor="mm")

    if SQUASH != 1.0:
        new_h = max(1, int(size * SQUASH))
        squeezed = text_layer.resize((size, new_h), Image.LANCZOS)
        text_layer = Image.new("L", (size, size), 0)
        text_layer.paste(squeezed, (0, int(TEXT_CENTER[1] * s - new_h / 2)))

    text_mask = text_layer
    text_bbox = text_layer.getbbox()

    dot_x = TEXT_CENTER[0] + DOT_REL[0] * TEXT_SIZE + FP_DOT_OFFSET_X
    dot_y = TEXT_CENTER[1] + DOT_REL[1] * TEXT_SIZE * SQUASH + FP_DOT_OFFSET_Y

    fp_mask = Image.new("L", (size, size), 0)
    _draw_footprint_on_mask(fp_mask, dot_x, dot_y, s)

    inflated = dilate(fp_mask, int(GAP * s))
    text_mask.paste(0, (0, 0), inflated)   # 隔离带挖空（找字层不含脚印）

    dx = dy = 0
    if text_bbox:
        dx = (size - (text_bbox[2] - text_bbox[0])) // 2 - text_bbox[0] + int(X_OFFSET * s)
        dy = (size - (text_bbox[3] - text_bbox[1])) // 2 - text_bbox[1]

    centered_text = Image.new("L", (size, size), 0)
    centered_fp = Image.new("L", (size, size), 0)
    centered_text.paste(text_mask, (dx, dy))
    centered_fp.paste(fp_mask, (dx, dy))

    return (centered_text.resize((CANVAS, CANVAS), Image.LANCZOS),
            centered_fp.resize((CANVAS, CANVAS), Image.LANCZOS))


def compose_art(text_mask, fp_mask, fp_color):
    """找字白 + 脚印指定色 → 1024×1024 RGBA 艺术层。

    参数:
        text_mask: 找字掩膜（"L"，含隔离带挖空）。
        fp_mask:   脚印掩膜（"L"，与找字同一居中平移）。
        fp_color:  脚印填充色 (r, g, b)。
    返回: PIL.Image（RGBA），alpha 为两掩膜并集。
    """
    art = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    white_img = Image.new("RGBA", (CANVAS, CANVAS), WHITE + (255,))
    fp_img = Image.new("RGBA", (CANVAS, CANVAS), fp_color + (255,))
    art = Image.composite(white_img, art, text_mask)
    art = Image.composite(fp_img, art, fp_mask)
    return art


def adaptive_circle_preview(art, size):
    """adaptive 图标在圆形裁切 ROM 下的观感模拟。

    参数:
        art:  compose_art() 产出的 1024 RGBA 艺术层。
        size: 输出边长（px）。
    返回: RGB 图（浅灰桌面底 + 圆形 teal 图标）。
    """
    fg = foreground_layer(art, CANVAS)
    base = Image.new("RGB", (CANVAS, CANVAS), BRAND)
    base.paste(fg, (0, 0), fg)
    base = base.resize((size, size), Image.LANCZOS)
    big = size * SUPERSAMPLE
    m = Image.new("L", (big, big), 0)
    ImageDraw.Draw(m).ellipse([0, 0, big - 1, big - 1], fill=255)
    m = m.resize((size, size), Image.LANCZOS)
    out = Image.new("RGB", (size, size), DESKTOP_BG)
    out.paste(base, (0, 0), m)
    return out


def _label_font(px):
    """取中文标注字体，找不到微软雅黑则退回 PIL 默认字体。"""
    try:
        return ImageFont.truetype("msyh.ttc", px)
    except OSError:
        return ImageFont.load_default()


def make_overview(items, kind, path):
    """拼 8 候选横排总览图。

    参数:
        items: [(icon_img, name, hex_label)]，icon_img 为 512 RGB。
        kind:  "legacy" 或 "adaptive"（仅用于标题）。
        path:  输出 PNG 路径。
    """
    n = len(items)
    cell, gap, pad, label_h, title_h = 192, 24, 32, 64, 56
    w = pad * 2 + n * cell + (n - 1) * gap
    h = title_h + pad + cell + label_h + pad
    sheet = Image.new("RGB", (w, h), DESKTOP_BG)
    d = ImageDraw.Draw(sheet)
    title_font = _label_font(28)
    name_font = _label_font(22)
    hex_font = _label_font(18)
    title = "桌面图标脚印换色候选（找字白色不变）· " + (
        "圆角方块观感" if kind == "legacy" else "圆形裁切观感")
    d.text((pad, 14), title, font=title_font, fill=(0x33, 0x33, 0x33))
    x = pad
    y = title_h + pad
    for icon, name, hex_label in items:
        sheet.paste(icon.resize((cell, cell), Image.LANCZOS), (x, y))
        d.text((x + cell // 2, y + cell + 10), name, font=name_font,
               fill=(0x33, 0x33, 0x33), anchor="ma")
        d.text((x + cell // 2, y + cell + 38), hex_label, font=hex_font,
               fill=(0x88, 0x88, 0x88), anchor="ma")
        x += cell + gap
    sheet.save(path, "PNG")


def main():
    """渲染全部候选单图与两张总览对比图。"""
    os.makedirs(OUT, exist_ok=True)
    print("[1] 构建找字/脚印分离掩膜（几何与正式出包一致）")
    text_mask, fp_mask = build_layers()

    print("[2] 逐候选色渲染 legacy / adaptive 预览")
    legacy_items, adaptive_items = [], []
    for cid, name, rgb, hex_label in CANDIDATES:
        art = compose_art(text_mask, fp_mask, rgb)
        legacy = legacy_icon(art, 512)
        adaptive = adaptive_circle_preview(art, 512)
        legacy_path = os.path.join(OUT, f"fp-{cid}-legacy.png")
        adaptive_path = os.path.join(OUT, f"fp-{cid}-adaptive.png")
        legacy.save(legacy_path, "PNG")
        adaptive.save(adaptive_path, "PNG")
        legacy_items.append((legacy, f"{cid} {name}", hex_label))
        adaptive_items.append((adaptive, f"{cid} {name}", hex_label))
        print(f"    {cid} {name} {hex_label}")

    print("[3] 拼总览对比图")
    overview_legacy = os.path.join(OUT, "overview-legacy.png")
    overview_adaptive = os.path.join(OUT, "overview-adaptive.png")
    make_overview(legacy_items, "legacy", overview_legacy)
    make_overview(adaptive_items, "adaptive", overview_adaptive)

    print(f"\n✅ 候选渲染完成，输出目录: {OUT}")


if __name__ == "__main__":
    main()
