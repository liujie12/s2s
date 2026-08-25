"""校验 code.js 内联的鸭子符号几何与 assets 真源是否一致，并渲染三档位看图。

本脚本存在的理由：code.js 与 assets/duck-symbol-*.svg 是【双份副本】
（Figma 插件沙箱不能读文件，几何必须内联）。上一轮的失败正是两份副本
都写着同一条我自己编的路径，互相印证等于没验。因此这里做两件事：
  1. 逐字比对 code.js 内联路径与 assets 真源（真源可追溯到用户批准的位图）
  2. 按 code.js 的组装逻辑复现三档位 SVG 并渲染成 PNG，位图必须人工过目
"""

import os
import re
import sys

import cv2
from importlib.machinery import SourceFileLoader

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "assets")
OUT_DIR = os.path.join(ASSETS, "render")
CODE_JS = os.path.join(HERE, "code.js")

_verify = SourceFileLoader(
    "probe_render_verify", os.path.join(HERE, "probe-render-verify.py")
).load_module()
render_svg = _verify.render_svg

FAILED = []


def check(label, ok, detail=""):
    """记录一条断言结果并打印。

    :param label: 检查项名称（ASCII，避免终端中文乱码）
    :param ok: 是否通过
    :param detail: 附加实测值
    """
    tag = "PASS" if ok else "FAIL"
    if not ok:
        FAILED.append(label)
    print(f"{tag}  {label}" + (f"  [{detail}]" if detail else ""))


def js_string(src, name):
    """从 JS 源码里取出 var NAME = '...'; 的字符串字面量。

    :param src: JS 全文
    :param name: 变量名
    :return: 字面量内容
    :raises SystemExit: 变量不存在时直接终止，避免后续比对拿 None 静默通过
    """
    m = re.search(r"var\s+%s\s*=\s*'([^']*)'" % re.escape(name), src)
    if not m:
        sys.exit(f"code.js 里找不到变量 {name}")
    return m.group(1)


def js_object(src, name):
    """从 JS 源码里取出 var NAME = { cx: .., cy: .., r: .. }; 的三个数值。

    :param src: JS 全文
    :param name: 变量名
    :return: (cx, cy, r) 三个字符串（保留原始写法便于逐字比对）
    :raises SystemExit: 结构不符时终止，避免拿 None 静默通过
    """
    m = re.search(
        r"var\s+%s\s*=\s*\{\s*cx:\s*([\d.]+),\s*cy:\s*([\d.]+),\s*r:\s*([\d.]+)\s*\}"
        % re.escape(name),
        src,
    )
    if not m:
        sys.exit(f"code.js 里 {name} 结构不符，期望 {{ cx, cy, r }}")
    return m.group(1, 2, 3)


def js_number(src, name):
    """从 JS 源码里取出 var NAME = 数字; 的字面量。"""
    m = re.search(r"var\s+%s\s*=\s*([\d.]+)\s*;" % re.escape(name), src)
    if not m:
        sys.exit(f"code.js 里找不到数值变量 {name}")
    return m.group(1)


def svg_paths(path):
    """取出 SVG 里所有 path 的 d 属性。"""
    with open(path, encoding="utf-8") as fh:
        return re.findall(r'<path d="([^"]+)"', fh.read())


def svg_circles(path):
    """取出 SVG 里所有 circle 的 (cx, cy, r) 与 fill。"""
    with open(path, encoding="utf-8") as fh:
        return re.findall(
            r'<circle cx="([\d.]+)" cy="([\d.]+)" r="([\d.]+)" fill="(#[0-9A-Fa-f]+)"',
            fh.read(),
        )


if __name__ == "__main__":
    os.makedirs(OUT_DIR, exist_ok=True)
    with open(CODE_JS, encoding="utf-8") as fh:
        js = fh.read()

    # --- 1. 内联几何与真源逐字一致 ---
    src_ring_out, src_ring_in, src_disc = svg_paths(
        os.path.join(ASSETS, "duck-symbol-full.svg")
    )
    pairs = [
        ("DUCK_RING_OUTER", src_ring_out),
        ("DUCK_RING_INNER", src_ring_in),
        ("DUCK_DISC_HEAD", src_disc),
    ]
    for name, expect in pairs:
        got = js_string(js, name)
        check(
            f"{name} identical to asset",
            got == expect,
            f"js {len(got)} chars vs asset {len(expect)} chars",
        )

    # 眼点在 assets 里是 <circle>，在 code.js 里是 DUCK_EYE 对象
    with open(os.path.join(ASSETS, "duck-symbol-full.svg"), encoding="utf-8") as fh:
        c = re.search(r'<circle cx="([\d.]+)" cy="([\d.]+)" r="([\d.]+)"', fh.read())
    check(
        "DUCK_EYE matches asset circle",
        js_object(js, "DUCK_EYE") == c.group(1, 2, 3),
        f"js {js_object(js, 'DUCK_EYE')} vs asset {c.group(1, 2, 3)}",
    )

    # --- 1b. mini 档几何与真源逐字一致 ---
    # mini 档不再与另两档共用几何（2026-08-26）：旧结构是「圆角块 + 白盘 +
    # 盘内镂空鸭头」，白盘只占画板 44%，24px 下鸭头喙尖必糊。新结构是
    # 「主色圆盘铺满 + 白色实体鸭头 + 主色眼点」，鸭头另有一套居中放大的坐标，
    # 故这里单独对 assets/duck-symbol-mini.svg 比对。
    mini_head = svg_paths(os.path.join(ASSETS, "duck-symbol-mini.svg"))
    check("mini asset has exactly 1 path", len(mini_head) == 1, str(len(mini_head)))
    got_head = js_string(js, "DUCK_HEAD_MINI")
    check(
        "DUCK_HEAD_MINI identical to asset",
        got_head == mini_head[0],
        f"js {len(got_head)} chars vs asset {len(mini_head[0])} chars",
    )

    mini_circles = svg_circles(os.path.join(ASSETS, "duck-symbol-mini.svg"))
    check("mini asset has exactly 2 circles", len(mini_circles) == 2, str(len(mini_circles)))
    disc_c, eye_c = mini_circles
    check(
        "DUCK_DISC_MINI_R matches asset disc",
        js_number(js, "DUCK_DISC_MINI_R") == disc_c[2],
        f"js {js_number(js, 'DUCK_DISC_MINI_R')} vs asset {disc_c[2]}",
    )
    check(
        "DUCK_EYE_MINI matches asset circle",
        js_object(js, "DUCK_EYE_MINI") == eye_c[:3],
        f"js {js_object(js, 'DUCK_EYE_MINI')} vs asset {eye_c[:3]}",
    )
    # 反相校验：鸭头必须是白色实体、眼点必须是主色。前景层不能靠镂空表达形状
    # （镂空透出的是底色），且鸭头已是白色时白眼点会与鸭头融为一体。
    check("mini asset duck head is solid white",
          'fill="#FFFFFF"' in open(
              os.path.join(ASSETS, "duck-symbol-mini.svg"), encoding="utf-8"
          ).read().split("<path")[1].split("/>")[0])
    check("mini asset eye is brand color", eye_c[3].upper() == "#0B7C8C", eye_c[3])

    # --- 2. 档位阈值与真源档位文件一致 ---
    # code.js: >=96 两环 / >=64 一环 / 其余 走 mini 独立结构
    tier_src = re.search(
        r"var tier = \(s >= 96\).*?roles\.push\(negative, negative\);", js, re.S
    )
    check("tier thresholds are 96 / 64", tier_src is not None
          and "s >= 96" in tier_src.group(0) and "s >= 64" in tier_src.group(0))
    check("mini tier uses its own geometry",
          tier_src is not None
          and "DUCK_HEAD_MINI" in tier_src.group(0)
          and "DUCK_EYE_MINI" in tier_src.group(0)
          and "DUCK_DISC_MINI_R" in tier_src.group(0))

    # --- 3. 按 code.js 的组装逻辑复现三档位并渲染 ---
    BRAND, WHITE = "#0B7C8C", "#FFFFFF"
    HEAD = '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" ' \
           'viewBox="0 0 1024 1024">'
    tiers = {
        "full": [src_ring_out, src_ring_in],
        "compact": [src_ring_in],
        "mini": None,   # None 表示走独立结构，不是「零个环」
    }
    for tier, rings in tiers.items():
        if rings is None:
            # 复现 code.js 的 mini 分支：主色圆盘 + 白色实体鸭头 + 主色眼点
            svg = (
                HEAD
                + f'<circle cx="512" cy="512" r="{js_number(js, "DUCK_DISC_MINI_R")}" '
                  f'fill="{BRAND}"/>'
                + f'<path d="{got_head}" fill="{WHITE}"/>'
                + '<circle cx="{0}" cy="{1}" r="{2}" fill="{3}"/>'.format(
                    *js_object(js, "DUCK_EYE_MINI"), BRAND)
                + "</svg>"
            )
        else:
            parts = [
                HEAD,
                f'<rect x="0" y="0" width="1024" height="1024" rx="229.38" fill="{BRAND}"/>',
            ]
            for r in rings:
                parts.append(f'<path d="{r}" fill="{WHITE}" fill-rule="evenodd"/>')
            parts.append(f'<path d="{src_disc}" fill="{WHITE}" fill-rule="evenodd"/>')
            parts.append(
                f'<circle cx="{c.group(1)}" cy="{c.group(2)}" r="{c.group(3)}" '
                f'fill="{WHITE}"/>'
            )
            parts.append("</svg>")
            svg = "".join(parts)

        img = render_svg(svg, 512)
        out = os.path.join(OUT_DIR, f"codejs-{tier}.png")
        cv2.imwrite(out, img)

        # 与同档位真源素材比对形状：这一步防止「组装逻辑」本身出错
        asset_img = render_svg(
            open(os.path.join(ASSETS, f"duck-symbol-{tier}.svg"), encoding="utf-8").read(),
            512,
        )
        a = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY) > 199
        b = cv2.cvtColor(asset_img, cv2.COLOR_BGR2GRAY) > 199
        score = _verify.iou(a, b)
        check(f"codejs {tier} matches asset (IoU>=0.99)", score >= 0.99, f"IoU={score:.4f}")

    print(f"\n{len(tiers)} tier renders -> {OUT_DIR}\\codejs-*.png")
    print(f"\n{'ALL PASS' if not FAILED else str(len(FAILED)) + ' FAILED: ' + ', '.join(FAILED)}")
    sys.exit(1 if FAILED else 0)
