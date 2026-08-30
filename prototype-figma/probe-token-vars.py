"""校验数值型 Design Token 已完整入 Figma Variables 并真正接到构造器上。

本脚本存在的理由：Token 落地的失败方式是「静默」的。bindNum() 在取不到变量时
按设计静默返回 false —— 画面完全正确，只是字段没绑变量。也就是说绑定率归零时
截图看不出任何异常，人工验收必然放过。唯一能守住它的是离线静态检查。

它守的是三条不同的线，缺一条都会漏：
1. 完备度 —— PRD §1.4.4/§1.4.5 的 17 项数值规格是否都进了 ensureNumberVariables；
2. 一致性 —— code.js 三张真源表的值是否与 PRD 表格逐项相等（防单侧改动）；
3. 接入 —— box()/text() 是否真的调了绑定器（防「变量建了但没人用」）。

外加反向用例：逐项造假确认断言真会失败，防止写出永远通过的空断言
（这是条目 [47] 里 `mini eye enlarged vs full` 假通过的教训，原则 ㉙）。

跑完即删，不留产物 —— 中间文件只会多一份要同步的副本。
"""

import os
import re
import sys

BASE = os.path.dirname(os.path.abspath(__file__))
CODE = os.path.join(BASE, "code.js")
PRD = os.path.join(os.path.dirname(BASE), "docs", "PRD.md")

passed, failed = [], []


def check(label, ok, detail=""):
    """记录一项校验结果。

    Args:
        label: 校验项名称
        ok: 是否通过
        detail: 附加说明（实测值 / 失败原因）
    Returns:
        None
    """
    (passed if ok else failed).append(f"{label} | {detail}")
    print(("PASS  " if ok else "FAIL  ") + label + (f"  [{detail}]" if detail else ""))


def strip_comments(text):
    """剥掉 JS 行注释与块注释，保留换行以不打乱行号感。

    为什么必须剥：注释里刻意保留着「原先写的是什么」的历史记录（如 card()
    里记着旧值 md），直接搜全文会把改动理由误判为残留代码。这是条目 [46]
    踩过的坑（原则 ㉑）。

    为什么不能用正则 `/\\*.*?\\*/`：code.js 的行注释里出现了 `size/*`
    （指代 size/ 前缀下的全部变量），那个 `/*` 会被正则当成块注释开头，
    一路吃到后面 JSDoc 的 `*/`，把 bindNum 绑定行和函数收尾大括号一起吞掉
    —— 表现就是 text() 的函数体永远配不平。同理字符串里的 `://` 也会被
    行注释正则误伤。故改为单遍状态机：只有处在代码态（不在字符串、不在
    注释内）时，`//` 与 `/*` 才被识别为注释起点。

    Args:
        text: JS 源码
    Returns:
        str: 去注释后的源码（注释位置留空，换行保留）
    """
    out = []
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        # 字符串字面量：整段原样保留，内部的 // 和 /* 不算注释
        if ch in "'\"`":
            quote = ch
            out.append(ch)
            i += 1
            while i < n:
                out.append(text[i])
                if text[i] == "\\":          # 转义：连吃下一个字符
                    if i + 1 < n:
                        out.append(text[i + 1])
                    i += 2
                    continue
                if text[i] == quote:
                    i += 1
                    break
                i += 1
            continue
        # 行注释：吃到行尾，换行本身留下
        if ch == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                i += 1
            continue
        # 块注释：吃到 */，内部换行补回以保持行结构
        if ch == "/" and i + 1 < n and text[i + 1] == "*":
            end = text.find("*/", i + 2)
            end = n if end < 0 else end + 2
            out.append("\n" * text.count("\n", i, end))
            i = end
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def func_body(text, signature):
    """按大括号配平取出一个顶层函数的函数体。

    为什么不用正则 `\\{(.*?)\\n\\}`：那种写法在函数体内出现顶格 `}` 时会提前
    截断，也可能因非贪婪跨到下一个函数 —— 本探针第一次跑就因此把 text() 的
    绑定行判为缺失（实际存在）。这属于「断言的取值路径失效」，正是原则 ㉙
    要防的形态：结构一变，正则取到的就不再是目标。改为配平计数后与结构无关。

    Args:
        text: 已去注释的源码
        signature: 函数签名前缀，如 "function text(content, scale, colorRole)"
    Returns:
        str: 函数体源码；未找到时返回空串
    """
    start = text.find(signature)
    if start < 0:
        return ""
    brace = text.find("{", start)
    if brace < 0:
        return ""
    depth = 0
    for i in range(brace, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[brace + 1 : i]
    return ""


with open(CODE, encoding="utf-8") as fh:
    raw = fh.read()
code = strip_comments(raw)

with open(PRD, encoding="utf-8") as fh:
    prd = fh.read()

# ============================================================
# 一、真源表解析：从 code.js 读出三张表的实际取值
# ============================================================


def parse_scale(name):
    """从 code.js 解析形如 `var X = { a: 1, b: 2 };` 的单层数值表。

    Args:
        name: 变量名，如 "SPACING"
    Returns:
        dict[str, int]: 键到数值的映射
    """
    m = re.search(r"var\s+" + name + r"\s*=\s*\{(.*?)\};", code, re.S)
    assert m, f"未找到真源表 {name}"
    return {k: int(v) for k, v in re.findall(r"([A-Za-z0-9_]+)\s*:\s*(\d+)", m.group(1))}


spacing = parse_scale("SPACING")
radius = parse_scale("RADIUS")

m_type = re.search(r"var\s+TYPE_SCALE\s*=\s*\{(.*?)\n\};", code, re.S)
assert m_type, "未找到真源表 TYPE_SCALE"
type_scale = {
    k: int(v)
    for k, v in re.findall(r"([a-z0-9]+):\s*\{\s*size:\s*(\d+)", m_type.group(1))
}

check("parse TYPE_SCALE", len(type_scale) == 6, f"{len(type_scale)} 阶 {sorted(type_scale.values())}")
check("parse SPACING", len(spacing) == 6, f"{len(spacing)} 阶 {sorted(spacing.values())}")
check("parse RADIUS", len(radius) == 5, f"{len(radius)} 阶 {sorted(radius.values())}")

# ============================================================
# 二、与 PRD 逐项比对（防单侧改动）
# ============================================================

# PRD §1.4.4 字阶表：| H1 超大标题 | 24 sp | ...
prd_sizes = set(int(x) for x in re.findall(r"\|\s*(\d+)\s*sp\s*\|", prd))
check(
    "PRD §1.4.4 字阶与 code.js 一致",
    set(type_scale.values()) == prd_sizes,
    f"code={sorted(type_scale.values())} prd={sorted(prd_sizes)}",
)

# PRD §1.4.5 间距与圆角表：| xs | 4 px | ... 与 | R-sm | 4 px | ...
prd_spacing = {}
prd_radius = {}
for name, val in re.findall(r"\|\s*(R-[a-z]+|xs|sm|md|lg|xl|2xl)\s*\|\s*(\d+) px\s*\|", prd):
    if name.startswith("R-"):
        prd_radius[name[2:]] = int(val)
    else:
        prd_spacing["xxl" if name == "2xl" else name] = int(val)

check(
    "PRD §1.4.5 间距阶与 code.js 一致",
    spacing == prd_spacing,
    f"code={spacing} prd={prd_spacing}",
)
check(
    "PRD §1.4.5 圆角阶与 code.js 一致",
    radius == prd_radius,
    f"code={radius} prd={prd_radius}",
)

# ============================================================
# 三、完备度：17 项是否都会被写成 FLOAT 变量
# ============================================================

body = func_body(code, "async function ensureNumberVariables(")
check("ensureNumberVariables 存在", bool(body))

for grp, table, prefix in (
    ("字号", type_scale, "size/"),
    ("间距", spacing, "spacing/"),
    ("圆角", radius, "radius/"),
):
    ok = f"'{prefix}' + key" in body
    check(f"{grp} {len(table)} 项经 {prefix}* 入表", ok)

def parse_hex_table(name):
    """从 code.js 解析形如 `var X = { 'a': '#112233' };` 的单层色表。

    与 parse_scale 分开写是因为色值是带引号的字符串而非裸数字，
    正则不同；两者都必须从真源解析，不得在探针里手写第二份副本。

    Args:
        name: 变量名，如 "SEMANTIC_COLORS"
    Returns:
        dict[str, str]: role 键到 HEX 的映射
    """
    m = re.search(r"var\s+" + name + r"\s*=\s*\{(.*?)\};", code, re.S)
    assert m, f"未找到真源表 {name}"
    return dict(re.findall(r"'([\w-]+)'\s*:\s*'(#[0-9A-Fa-f]{6})'", m.group(1)))


semantic_colors = parse_hex_table("SEMANTIC_COLORS")
category_colors = parse_hex_table("CATEGORY_COLORS")
category_deep = parse_hex_table("CATEGORY_DEEP")
color_total = len(semantic_colors) + len(category_colors) + len(category_deep)
float_total = len(type_scale) + len(spacing) + len(radius)

# 计数从真源表长度算出，不写死数字（2026-08-26 改）：
# 原先标题写死「COLOR 21」而断言只验 FLOAT == 17，新增 5 个 category/*-deep
# 后标题就与事实脱节，且没有任何断言会报错 —— 这正是「断言看着绿其实没在看」
# 的形态。现在把 COLOR 也纳入实际计数。
check(
    f"变量总数 = COLOR {color_total} + FLOAT {float_total} = {color_total + float_total}",
    float_total == 17 and color_total == 26,
    f"语义 {len(semantic_colors)} + 分类 {len(category_colors)}"
    f" + 分类深色 {len(category_deep)} = COLOR {color_total}；FLOAT {float_total}",
)

check(
    "五个分类色各有对应的 -deep 深色变体（缺一个就有一类选中态白字不达标）",
    set(category_deep) == set(category_colors),
    f"deep={sorted(category_deep)} base={sorted(category_colors)}",
)

check("FLOAT 查询已加入", "getLocalVariablesAsync('FLOAT')" in code)
check("ensureVariables 汇总 FLOAT 计数", "await ensureNumberVariables(" in code)

# 行高刻意不入变量（派生值），确认没被误加
check(
    "行高未被建成独立变量",
    "'lineHeight/'" not in code and '"lineHeight/"' not in code,
    "行高为字号×倍数的派生值",
)

# ============================================================
# 三之二、Dart 单向出口与真源逐项一致（条目 [58] / I2）
#
# 为什么必须有这条：lib/design_tokens.dart 由 export-dart-tokens.js 生成，而
# 「改了 code.js 忘记重跑」不会有任何征兆 —— 产物依旧是合法 Dart，编译照过，
# 只是取值停留在旧版。这正是原则 ㊱ 的静默降级形态。
#
# 为什么产物值得留（与本文件 docstring 末句「跑完即删，不留产物」不冲突）：
# 那句话防的是可被双向编辑的副本。本产物是单向出口，有本节断言把它钉在真源上，
# 脱钩当场变红，不存在需要人去手工同步的第二份。留它的唯一理由是让 Token 取值
# 变更进 git diff —— Figma 侧 figma_diff_versions 不追踪变量值变更，主色对比度
# 余量只 0.41，悄悄调深一档此前没有任何机制会报警（条目 [57] 查明）。
#
# 断言按产物里的 `/// <Figma 变量名>` 注释取值，不复制导出脚本的 camelCase
# 转换规则 —— 复制一份转换规则就是新的手抄副本（原则 ㊾）。
# ============================================================

DART_OUT = os.path.join(os.path.dirname(BASE), "lib", "design_tokens.dart")


def parse_dart_tokens(path):
    """从生成的 Dart 产物里解析「Figma 变量名 → 值」映射。

    产物的每个常量都由一行 `/// <变量名>[  ·  <备注>]` 紧跟 `static const`
    组成，故按注释行锚定即可，无需理解 Dart 语法。

    字阶的构造参数**跨多行**（`dart format` 的产物形态，见 export-dart-tokens.js
    里 typeScaleBlock 的注释），故其正则须允许参数间出现换行与缩进。写成单行匹配
    的话，格式化一跑正则就全部落空、本函数返回空字典 —— 之所以那样也不会酿成
    「静默通过」，是因为调用方用的是**整表相等**比对（dart_styles == want_styles），
    空字典与 6 项字典不等，断言会失败。若哪天把它改成逐键循环校验，这层保护就没了。

    Args:
        path: Dart 产物路径
    Returns:
        tuple[dict, dict, dict]: (颜色 变量名→0xAARRGGBB 字符串,
                                  数值 变量名→float,
                                  字阶 变量名→(size, weight, lineHeight))
    """
    with open(path, encoding="utf-8") as fh:
        src = fh.read()
    colors = dict(
        re.findall(
            r"///\s+((?:color|category)/[\w-]+)\s+·[^\n]*\n\s*static const int \w+ = (0x[0-9A-F]{8});",
            src,
        )
    )
    numbers = {
        k: float(v)
        for k, v in re.findall(
            r"///\s+((?:spacing|radius)/[\w-]+)\n\s*static const double \w+ = ([\d.]+);",
            src,
        )
    }
    styles = {
        k: (float(size), weight, float(lh))
        for k, size, weight, lh in re.findall(
            r"///\s+(size/[\w-]+)\s+·[^\n]*\n\s*static const AppTextStyleToken \w+ = "
            r"AppTextStyleToken\(\s*size:\s*([\d.]+),\s*weight:\s*'(\w+)',"
            r"\s*lineHeight:\s*([\d.]+),?\s*\);",
            src,
        )
    }
    return colors, numbers, styles


def hex_to_argb(hex_value):
    """把 #RRGGBB 转成 Dart 侧的 0xAARRGGBB 字面量文本（不透明）。

    Args:
        hex_value: 形如 '#0B7C8C' 的色值
    Returns:
        str: 形如 '0xFF0B7C8C'
    """
    return "0xFF" + hex_value[1:].upper()


check("Dart 产物存在（未生成则整个单向出口形同不存在）", os.path.exists(DART_OUT), DART_OUT)

if os.path.exists(DART_OUT):
    dart_colors, dart_numbers, dart_styles = parse_dart_tokens(DART_OUT)

    # 由真源表现算出「产物应当长什么样」，再整体比对。
    # 逐键循环会漏掉「产物多了一项真源已删的 Token」，整表相等才两个方向都守住。
    want_colors = {}
    for k, v in semantic_colors.items():
        want_colors["color/" + k] = hex_to_argb(v)
    for k, v in category_colors.items():
        want_colors["category/" + k] = hex_to_argb(v)
    for k, v in category_deep.items():
        want_colors["category/" + k + "-deep"] = hex_to_argb(v)

    check(
        f"Dart 产物颜色与真源逐项一致（{len(want_colors)} 项）",
        dart_colors == want_colors,
        f"产物 {len(dart_colors)} 项"
        + (
            ""
            if dart_colors == want_colors
            else "；差异 "
            + str(sorted(set(want_colors.items()) ^ set(dart_colors.items())))
            + "  —— 请重跑 node prototype-figma/export-dart-tokens.js"
        ),
    )

    want_numbers = {}
    for k, v in spacing.items():
        want_numbers["spacing/" + k] = float(v)
    for k, v in radius.items():
        want_numbers["radius/" + k] = float(v)

    check(
        f"Dart 产物间距与圆角与真源逐项一致（{len(want_numbers)} 项）",
        dart_numbers == want_numbers,
        f"产物 {len(dart_numbers)} 项"
        + (
            ""
            if dart_numbers == want_numbers
            else "；差异 "
            + str(sorted(set(want_numbers.items()) ^ set(dart_numbers.items())))
            + "  —— 请重跑导出脚本"
        ),
    )

    # 字阶三个字段都要比：只比 size 的话，字重或行高倍数改了照样绿。
    # 行高倍数不在 Variables 里（派生值），Dart 侧是它唯一的机器可读落点，
    # 漏比等于这一项完全没人守。
    m_full_type = re.search(r"var\s+TYPE_SCALE\s*=\s*\{(.*?)\n\};", code, re.S)
    want_styles = {
        "size/" + k: (float(size), weight, float(lh))
        for k, size, weight, lh in re.findall(
            r"([a-z0-9]+):\s*\{\s*size:\s*(\d+),\s*weight:\s*'(\w+)',\s*lineHeight:\s*([\d.]+)\s*\}",
            m_full_type.group(1),
        )
    }
    check(
        "真源字阶三字段可解析（size/weight/lineHeight 全取到）",
        len(want_styles) == len(type_scale),
        f"{len(want_styles)}/{len(type_scale)} 档",
    )
    check(
        f"Dart 产物字阶与真源逐项一致（{len(want_styles)} 档 × 3 字段）",
        dart_styles == want_styles,
        f"产物 {len(dart_styles)} 档"
        + (
            ""
            if dart_styles == want_styles
            else "；差异 "
            + str(sorted(set(want_styles.items()) ^ set(dart_styles.items())))
            + "  —— 请重跑导出脚本"
        ),
    )

    # 产物必须保持「任何 Dart 项目可用」：一旦 import 了 Flutter，还没有 Flutter
    # 工程的当下就引用不了，用户拍板选纯常量文件正是为此。
    #
    # 按行首匹配而非全文含有 "import"：产物的头注释里写着「刻意不 import
    # 'package:flutter/material.dart'」来交代这个设计决定，全文搜会被这句自我
    # 说明误伤（本轮实际踩到）。Dart 的 import 只能顶格在行首，按行首判定既准
    # 又不会因注释措辞变化而漂移。
    with open(DART_OUT, encoding="utf-8") as fh:
        dart_src = fh.read()
    check(
        "Dart 产物无任何 import（不依赖 Flutter，颜色以 int 存）",
        re.search(r"(?m)^\s*import\s", dart_src) is None,
        "无行首 import",
    )
    check(
        "Dart 产物标明禁止手改并给出重跑命令",
        "请勿手改" in dart_src and "export-dart-tokens.js" in dart_src,
    )
    # 动效刻意不导出：ease: 'spring' 在 Flutter 是 SpringSimulation、在 CSS 无
    # 对应值，替设计师把语义词落成具体参数超出「冻结契约」的范围（条目 [51] 红线）。
    check(
        "动效未被导出到 Dart（annotation-only 契约，不替实现侧选参）",
        "spring" not in dart_src and "MOTION" not in dart_src,
    )

# ============================================================
# 四、反查索引：必须由真源表派生，不得手写第二份副本
# ============================================================

m_idx = re.search(r"function buildNumTokenIndex\(\)\s*\{(.*?)\n\}\)\(\);", code, re.S)
check("NUM_TOKEN_NAMES 由真源表派生", bool(m_idx))
if m_idx:
    idx = m_idx.group(1)
    for table in ("TYPE_SCALE", "SPACING", "RADIUS"):
        check(f"反查索引遍历 {table}", f"in {table})" in idx)
    # 反查表内不得出现字面数字键，否则就是手写副本
    check(
        "反查索引内无手写数字键",
        not re.search(r"\[\s*\d+\s*\]\s*=", idx),
        "全部经 for-in 派生",
    )

# 分组唯一性：4 与 8 同时属间距与圆角，分表后各自不得内部撞值
for grp, table in (("spacing", spacing), ("radius", radius), ("size", type_scale)):
    vals = list(table.values())
    check(f"{grp} 组内值唯一（反查无歧义）", len(vals) == len(set(vals)), f"{sorted(vals)}")

# ============================================================
# 五、接入：绑定器是否真被 box()/text() 调用
# ============================================================

box_body = func_body(code, "function box(name, dir, opt)")
check("box() 存在", bool(box_body))

check("box() 绑圆角", "bindRadius(f, opt.radius)" in box_body)
check("box() 绑 itemSpacing", "bindNum(f, 'itemSpacing', 'spacing', opt.gap)" in box_body)
for side in ("paddingTop", "paddingBottom", "paddingLeft", "paddingRight"):
    check(f"box() 绑 {side}", f"bindNum(f, '{side}', 'spacing', f.{side})" in box_body)

text_body = func_body(code, "function text(content, scale, colorRole)")
check("text() 存在", bool(text_body))
check("text() 绑 fontSize", "bindNum(t, 'fontSize', 'size', s.size)" in text_body)

# bindRadius 必须绑四个角：cornerRadius 不是可绑定字段，绑它等于没绑
br = func_body(code, "function bindRadius(node, value)")
check("bindRadius 存在", bool(br))
if br:
    for corner in ("topLeftRadius", "topRightRadius", "bottomLeftRadius", "bottomRightRadius"):
        check(f"bindRadius 绑 {corner}", f"'{corner}'" in br)
    check(
        "bindRadius 未误绑 cornerRadius",
        "'cornerRadius'" not in br,
        "cornerRadius 非可绑定字段",
    )

# hydrate 必须兼载 FLOAT，否则批次 2/3/4 全部绑定失效
hyd = func_body(code, "async function hydrateVariables()")
check("hydrateVariables 存在", bool(hyd))
if hyd:
    check("hydrate 载入 FLOAT", "getLocalVariablesAsync('FLOAT')" in hyd)
    for prefix in ("size/", "spacing/", "radius/"):
        check(f"hydrate 收录 {prefix}*", f"'{prefix}'" in hyd)

# ============================================================
# 六、card() 与 PRD §1.4.7 对齐
# ============================================================

# 签名只截到 "function card(" 而不写全参数列表（2026-08-29 条目 [70] 修）：
# card() 本轮加了第五参 completeness，写死 "(title, sub, catRole, tag)" 的
# 签名当场失配，card_body 取到空串，随后 6 条断言连带全红 —— 报的却是
# 「内边距不是 lg」「没有阴影」这类假问题，把「取值路径失效」伪装成了内容问题。
# 这正是 func_body 文档里写的原则 ㉙ 形态，此前防住了正则截断，没防住签名硬编码。
CARD_SIG = "function card("
card_body = func_body(code, CARD_SIG)
check("card() 存在", bool(card_body))

check("card 内边距 = lg（PRD §1.4.7）", "pad: SPACING.lg" in card_body)
check("card 圆角 = R-lg", "radius: RADIUS.lg" in card_body)
check("card 底色 = surface", "fill: 'color/surface'" in card_body)
check(
    "card 有阴影 a=0.04（PRD §1.4.7）",
    re.search(r"DROP_SHADOW[^}]*a:\s*0\.04", card_body, re.S) is not None,
)
check(
    "card 阴影 offset 0,2 radius 8",
    re.search(r"offset:\s*\{\s*x:\s*0,\s*y:\s*2\s*\},\s*radius:\s*8", card_body) is not None,
)
check(
    "card 已移除代替阴影的 stroke（避免双线）",
    "stroke: 'color/border'" not in card_body,
)

# PRD 侧规格仍在，防止「改实现顺手改了 PRD」
check(
    "PRD §1.4.7 阴影规格未被改动",
    "0 2 8 rgba(0,0,0,0.04)" in prd,
)
check("PRD §1.4.7 内边距规格未被改动", "内边距 lg（16）" in prd)

# ============================================================
# 六之二、口径标注卡必须移出画框
#
# 为什么要探针守：漏移不会报错，画面照样生成，只是每张画框里多一块蓝框。
# 这正是原则 ㊱ 说的「静默降级」—— 失败后画面依旧「正确」，只能离线查。
# 而这次的失败模式尤其隐蔽：detachAnnotations 写好了但没在 layout 里调用，
# 代码看着完整，跑起来什么都没发生（本轮就差点停在这一步）。
# ============================================================

detach_body = func_body(code, "function detachAnnotations(frame, host)")
check("detachAnnotations() 存在", bool(detach_body))

check(
    "按 _annotation/ 前缀收集（与 annotation() 的命名对齐）",
    "n.name.indexOf('_annotation/') === 0" in detach_body,
)
check(
    "标注卡挂到 host 而非留在画框内",
    "host.appendChild(c)" in detach_body,
)
check(
    "移出后 opacity 复位为 1（mapCanvas 曾设 0.92/0.96）",
    "c.opacity = 1" in detach_body,
)
check(
    "清掉被搬空的 _note 壳",
    "n.name === '_note'" in detach_body and "children.length === 0" in detach_body,
)

layout_body = func_body(code, "function layout(host, nodes, perRow, startY)")
check("layout() 存在", bool(layout_body))

# 最关键的一条：函数写了不等于接上了
check(
    "layout() 确实调用了 detachAnnotations",
    "detachAnnotations(nodes[i], host)" in layout_body,
)

# 调用必须在坐标赋值之后，否则 frame.x 还是旧值，标注卡落到搬走前的位置
_pos_x = layout_body.find("nodes[i].x =")
_pos_call = layout_body.find("detachAnnotations(")
check(
    "detachAnnotations 在坐标赋值之后调用",
    _pos_x >= 0 and _pos_call > _pos_x,
    f"x@{_pos_x} call@{_pos_call}",
)

# gapX 要容得下宽 260 的标注卡加左右间隙
m_gap = re.search(r"var gapX = (\d+)", layout_body)
check(
    "gapX 足够容纳标注卡（≥308）",
    m_gap is not None and int(m_gap.group(1)) >= 308,
    f"gapX={m_gap.group(1) if m_gap else '未找到'} 卡宽 260 + 间隙 48",
)

# annotation() 产出的宽度是上一条断言的前提，一起钉住。
# 签名随 I1 加了第三个参数 opts（2026-08-27）：此处按签名全文匹配，
# 参数一变就抓不到函数体、断言恒失败 —— 这是「按字符串抓函数体」的固有脆性，
# 失败方向是安全的（不会假绿），故只需跟着更新签名。
ann_body = func_body(code, "function annotation(title, lines, opts)")
check(
    "annotation() 卡宽仍为 260（gapX 断言的前提）",
    "w: 260" in ann_body,
)

# ============================================================
# 六之三、splash / login 与 PRD 逐条对齐（M3 精修第 1-2 页）
#
# 判定标准由用户拍定：只改与 PRD 不一致处，不靠审美。故每条断言都必须
# 同时钉住「PRD 那句话还在」与「code.js 照做了」两端 —— 只钉一端的话，
# 顺手改 PRD 就能让断言变绿，等于没守（原则 ㉑）。
# ============================================================

splash_body = func_body(code, "function buildSplash()")
check("buildSplash() 存在", bool(splash_body))

# 底色：PRD §1.7 表③ 的 splash.svg 是品牌色满屏，画布须一致（用户 08-26 拍定）
check(
    "splash 底色 = primary（对齐已交付 splash.svg）",
    "s.fills = [paintOf('color/primary')]" in splash_body,
)
# 真源那一端：build-4b-assets.py 的启动页必须仍是品牌色满铺
with open(os.path.join(BASE, "build-4b-assets.py"), encoding="utf-8") as fh:
    build_assets = fh.read()
check(
    "splash.svg 真源仍为品牌色满铺（上一条断言的依据）",
    re.search(r'<rect width="\{w:g\}" height="\{h:g\}" fill="\{BRAND\}"', build_assets)
    is not None,
)
# 符号尺寸 132.6 = 390 × 34%，与 build_splash() 的 w * 0.34 同源
check(
    "splash 符号 132.6px（= 390 × 34%，同 build_splash）",
    "duckSymbol(132.6)" in splash_body,
)
check(
    "splash.svg 真源符号仍取 34%（上一条的依据）",
    "sym = w * 0.34" in build_assets,
)
# 品牌色底上文案必须反白，否则对比度不达 PRD §1.8 的 4.5:1
check(
    "splash 品牌名与 slogan 均反白为 surface",
    splash_body.count("'color/surface'") >= 2,
)

# slogan 文案：两页同句，且必须是 PRD §3.4.1 的原文
SLOGAN = "用就近的资源解决本地的需求"
check("PRD §3.4.1 slogan 原文仍在", SLOGAN in prd)
check("splash slogan 取 PRD 原文", SLOGAN in splash_body)
check(
    "splash 已弃用自拟文案「本地供需，一图看清」",
    "本地供需，一图看清" not in splash_body,
)

login_body = func_body(code, "function buildLogin()")
check("buildLogin() 存在", bool(login_body))

check("login slogan 与 splash 同句", SLOGAN in login_body)

# PRD §3.4.1 主方案三要素，此前缺图形验证码
check("PRD §3.4.1 图形验证码条款仍在", "图形验证码" in prd)
check("login 有图形验证码字段", "field('图形验证码'" in login_body)
check("login 图形码画占位块而非写死字符", "_captcha-image" in login_body)

# 次方案与底部四条款，此前全缺
check("PRD §3.4.1 密码登录条款仍在", "密码登录保留" in prd)
check("login 有密码登录折叠入口", "用密码登录" in login_body)

check("PRD §3.4.1 自动注册条款仍在", "未注册手机号验证后自动注册" in prd)
check("login 有自动注册说明", "未注册手机号验证后自动注册" in login_body)

check("PRD §3.4.1 第三方灰禁用条款仍在", "第三方入口折叠" in prd)
check(
    "login 三个第三方入口走 disabled 变体",
    "'微信', 'QQ', 'Apple'" in login_body and "'disabled'" in login_body,
)

check("PRD §3.4.1 协议默认不勾条款仍在", "默认不勾" in prd)
check(
    "login 协议勾选 checked 传 false",
    re.search(r"checkRow\('我已阅读并同意[^']*', false", login_body) is not None,
)

# 主按钮：PRD 要求「主色胶囊（80% 宽）」，此前是 primary 变体 + 87.7% 宽
check("PRD §3.4.1 主按钮胶囊 80% 条款仍在", "主色胶囊（80% 宽）" in prd)
check(
    "login 主按钮走 capsule 变体且宽 = 80%",
    "button('登录 / 注册', 'capsule', Math.round(CANVAS.w * 0.8))" in login_body,
)
# capsule 变体必须仍是 RADIUS.full，否则上一条断言名不副实。
# 2026-08-27（条目 [51] 第 5 步）：六类按钮的配色/圆角已从 buttonRaw 函数体内
# 提为模块级 BUTTON_SPECS —— 因为 component description 也要写这些值，留在函数
# 体内就必然抄出第二份副本（原则㊾）。故此处取值路径跟着改到 BUTTON_SPECS，
# 断言语义不变。这也是「按字符串抓函数体」的固有脆性，好在失败方向安全：
# 抓不到就恒失败，不会假绿。
specs_body = re.search(r"var BUTTON_SPECS = \{(.*?)\n\};", code, re.S)
check("BUTTON_SPECS 已提为模块级真源（下一条断言的前提）", specs_body is not None)
check(
    "capsule 变体圆角仍为 RADIUS.full",
    specs_body is not None
    and re.search(r"capsule:\s*\{[^}]*radius:\s*RADIUS\.full", specs_body.group(1)) is not None,
)
# buttonRaw 必须真的从 BUTTON_SPECS 取值：否则表改了而画布不变，
# 上面两条就成了对一张没人读的表的断言。
check(
    "buttonRaw 从 BUTTON_SPECS 取档位配置（表与画布不脱钩）",
    "BUTTON_SPECS[variant]" in func_body(code, "function buttonRaw(label, variant, width)"),
)

# 表单间距：PRD 明写 md，此前用 lg
check("PRD §3.4.1 表单 md 间距条款仍在", "表单（md 间距，R-md 输入框）" in prd)
check(
    "login 表单间距 = md",
    "pad: SPACING.xl, gap: SPACING.md" in login_body,
)

# 字段溢出 bug：xl 内边距下可用宽 342，field 默认 358
check(
    "field() 开放了 width 参数（修 login 溢出 16px）",
    "function field(label, placeholder, width)" in code,
)
check(
    "field() 默认宽未被改动（十几处 lg 内边距调用点依赖它）",
    "var w = width || (CANVAS.w - SPACING.lg * 2)" in code,
)
check(
    "login 三个字段全部显式传宽",
    login_body.count("innerW") >= 4,
)

# ============================================================
# 六之二、动效规格与 PRD §1.4.8 / §6.8 逐项一致（条目 [51] 第 6 步 / I5）
#
# 为什么动效的一致性必须在本探针里守：TIMING/EASING 进不了 Figma Variables，
# 所以本文件前面那套「Token 值 == PRD 表格值」的机制完全覆盖不到它。动效唯一
# 的一致性保障就是这一段 —— MOTION 表若与 PRD 对不上，画布上照样正常渲染，
# 截图验收看不出任何异常（这正是动效最容易在交接中蒸发的原因）。
#
# 判据从 PRD 原文取，而不是在这里手抄一份期望时长（原则㊾）：写死 260/240/180
# 只是把 PRD 的数字复制到第三个地方，PRD 改了它照样绿。
# ============================================================
print("\n--- 动效规格与 PRD 一致性（I5） ---")

motion_body_m = re.search(r"var MOTION = \{(.*?)\n\};", code, re.S)
check("MOTION 已建为模块级真源（下列断言的前提）", motion_body_m is not None)
motion_body = motion_body_m.group(1) if motion_body_m else ""

# 逐档解析出 dur 与 ease，供下面与 PRD 原文对照
motion_parsed = {
    k: (int(dur), ease)
    for k, dur, ease in re.findall(
        r"(\w+):\s*\{[^}]*?dur:\s*(\d+),\s*ease:\s*'([^']+)'", motion_body, re.S
    )
}
check(
    "MOTION 六档均可解析出 dur 与 ease",
    len(motion_parsed) == 6,
    f"解析到 {sorted(motion_parsed)}",
)

# PRD §1.4.8 的六行表是唯一真源。每档时长必须能在 PRD 原文里找到对应表述 ——
# 用「时长 + 场景关键词同现于一行」判定，而非全文含某个数字：全文含 260ms
# 会被别处任意一个 260 误命中。
prd_lines = prd.splitlines()


def prd_row(*keywords):
    """在 PRD 原文里找同时含全部关键词的那一行。

    动效判据一律按「关键词同现于一行」定位，而不是全文包含：PRD 里 180/200
    这类数字在别的章节也出现，全文匹配会假绿。

    Args:
        *keywords: 需在同一行同时出现的关键词
    Returns:
        str: 命中的第一行原文；未命中返回空串
    """
    for line in prd_lines:
        if all(k in line for k in keywords):
            return line
    return ""


motion_prd_cases = [
    ("page", "页面切换", ["页面切换", "260ms", "ease-out"]),
    ("sheet", "弹窗/抽屉上滑", ["弹窗", "240ms", "spring"]),
    ("mask", "遮罩渐显", ["遮罩渐显", "180ms"]),
    ("press", "按钮按下反馈", ["按钮反馈", "80ms"]),
    ("fade", "列表内容淡入", ["骨架屏", "180ms"]),
    # layer 档必须带上场景词：只写 200ms 会命中任意含该数字的行，
    # 而 §6.8 那行的判据恰恰是「颜色渐变 200ms」这个组合
    ("layer", "图层切换颜色渐变", ["Marker", "渐变", "200ms"]),
]
motion_bad = []
for key, desc, kws in motion_prd_cases:
    row = prd_row(*kws)
    if not row:
        motion_bad.append(f"{key}({desc}) 在 PRD 找不到对应行：{kws}")
        continue
    dur = motion_parsed.get(key, (None, None))[0]
    if dur is None or f"{dur}ms" not in row:
        motion_bad.append(f"{key} dur={dur} 与 PRD 行不符：{row.strip()[:40]}")
check(
    "MOTION 六档的时长逐项能在 PRD §1.4.8/§6.8 原文里回标",
    not motion_bad,
    "; ".join(motion_bad) if motion_bad else "6 档全部回标成功",
)

# 缓动必须沿用 PRD 原词。这条防的是「顺手把 spring 换成某条具名贝塞尔」——
# 替设计师把语义词落成具体参数超出「冻结契约」的范围（条目 [51] 红线）。
check(
    "sheet 档缓动仍为 PRD 原词 spring（未被替换成具名曲线）",
    motion_parsed.get("sheet", (None, None))[1] == "spring",
    f"实测 {motion_parsed.get('sheet', (None, 'n/a'))[1]}",
)
# §1.5 U2 的「200-300ms」说的是转场，与 press 的 80ms 不同层。这条断言把
# 两者都钉住：若哪天有人为了「消除矛盾」把 80ms 改成 200ms，这里会红。
check(
    "PRD §1.5 U2 的 200-300ms 转场口径仍在（与 press 80ms 不同层，不得互相修改）",
    "200-300ms" in prd or "200–300ms" in prd,
)
check(
    "press 档仍为 80ms（未被 U2 的转场口径误改）",
    motion_parsed.get("press", (None, None))[0] == 80,
    f"实测 {motion_parsed.get('press', (None,))[0]}ms",
)

# 画布与标注必须从 MOTION 取值，不能各处手抄。三个消费点缺一个，
# 那一处就会在改 MOTION 后静默脱钩。
check(
    "motionSpecLines 从 MOTION 现算（annotation 正文与表不脱钩）",
    "motionLine(k)" in func_body(code, "function motionSpecLines()"),
)
check(
    "首页展开态卡的动效行改为 motionLine 现算（画布上不留手抄的 240ms spring）",
    "'展开/收起动效：' + motionLine('sheet')" in code,
)
check(
    "规格板画板 D 的六行文本由 motionLine 现算",
    "mmeta.appendChild(text(motionLine(mk), 'small'))" in code,
)

# ============================================================
# 七、反向用例：逐项造假，确认断言真会失败
# ============================================================
print("\n--- 反向用例（确认断言不是永真） ---")

reverse = [
    (
        "改 SPACING 值应触发 PRD 不一致",
        lambda t: t.replace("var SPACING = { xs: 4", "var SPACING = { xs: 5"),
        lambda c: parse_scale_in(c, "SPACING") == prd_spacing,
    ),
    (
        "删 box() 圆角绑定应被检出",
        lambda t: t.replace("bindRadius(f, opt.radius);", ""),
        lambda c: "bindRadius(f, opt.radius)" in c,
    ),
    (
        "删 text() 字号绑定应被检出",
        lambda t: t.replace("bindNum(t, 'fontSize', 'size', s.size);", ""),
        lambda c: "bindNum(t, 'fontSize', 'size', s.size)" in c,
    ),
    (
        "hydrate 漏载 FLOAT 应被检出",
        lambda t: t.replace("getLocalVariablesAsync('FLOAT')", "getLocalVariablesAsync('COLOR')"),
        lambda c: "getLocalVariablesAsync('FLOAT')" in c,
    ),
    (
        "card 阴影 alpha 写错应被检出",
        lambda t: t.replace("a: 0.04 }", "a: 0.12 }"),
        lambda c: re.search(r"DROP_SHADOW[^}]*a:\s*0\.04", c, re.S) is not None,
    ),
    (
        "card 恢复 stroke 应被检出",
        lambda t: t.replace(
            "fill: 'color/surface', radius: RADIUS.lg, align: 'MIN'",
            "fill: 'color/surface', radius: RADIUS.lg, stroke: 'color/border', align: 'MIN'",
        ),
        lambda c: "stroke: 'color/border'"
        not in func_body(c, CARD_SIG),
    ),
    (
        "bindRadius 改绑 cornerRadius 应被检出",
        lambda t: t.replace("node.setBoundVariable('topLeftRadius', v);", "node.setBoundVariable('cornerRadius', v);"),
        lambda c: "'topLeftRadius'" in func_body(c, "function bindRadius(node, value)"),
    ),
    (
        "layout 漏调 detachAnnotations 应被检出",
        lambda t: t.replace("detachAnnotations(nodes[i], host);", ""),
        lambda c: "detachAnnotations(nodes[i], host)"
        in func_body(c, "function layout(host, nodes, perRow, startY)"),
    ),
    (
        "gapX 退回 80 应被检出（标注卡会压在下一列画框上）",
        lambda t: t.replace("var gapX = 320, gapY = 120;", "var gapX = 80, gapY = 120;"),
        lambda c: int(
            re.search(
                r"var gapX = (\d+)",
                func_body(c, "function layout(host, nodes, perRow, startY)"),
            ).group(1)
        )
        >= 308,
    ),
    # I5 两条：动效断言全部是「新写的」，必须自证不是永真 —— 上面那些断言
    # 有 PRD 表格与 Variables 双侧兜着，动效只有这一层。
    (
        "改 MOTION.press.dur 应被 PRD 回标断言检出",
        lambda t: t.replace("scene: '按钮反馈', dur: 80", "scene: '按钮反馈', dur: 200"),
        lambda c: re.search(
            r"scene: '按钮反馈', dur: (\d+)",
            re.search(r"var MOTION = \{(.*?)\n\};", c, re.S).group(1),
        ).group(1)
        == "80",
    ),
    (
        "把 spring 换成具名曲线应被检出",
        lambda t: t.replace("dur: 240, ease: 'spring'", "dur: 240, ease: 'cubic-bezier(.2,.8,.2,1)'"),
        lambda c: "dur: 240, ease: 'spring'" in c,
    ),
    # I2 三条：Dart 单向出口的断言必须自证会红。这组尤其需要 ——
    # 它防的场景就是「真源改了、产物没重跑」，而反向用例恰好就是造出这个场景：
    # 只改 code.js 文本、不动磁盘上的产物，比对必须失败。
    (
        "改主色应被 Dart 产物一致性检出（本条断言存在的首要理由）",
        lambda t: t.replace("'primary':        '#0B7C8C'", "'primary':        '#0A7280'"),
        lambda c: dart_colors.get("color/primary")
        == hex_to_argb(parse_hex_table_in(c, "SEMANTIC_COLORS")["primary"]),
    ),
    (
        "改圆角 lg 应被 Dart 产物一致性检出",
        lambda t: t.replace("RADIUS = { sm: 4, md: 8, lg: 12", "RADIUS = { sm: 4, md: 8, lg: 14"),
        lambda c: dart_numbers.get("radius/lg")
        == float(parse_scale_in(c, "RADIUS")["lg"]),
    ),
    (
        "只改字重（size 不变）也应被 Dart 产物一致性检出",
        lambda t: t.replace("h2:      { size: 18, weight: 'SemiBold'", "h2:      { size: 18, weight: 'Bold'"),
        lambda c: dart_styles.get("size/h2")
        == parse_type_scale_in(c)["size/h2"],
    ),
]


def parse_hex_table_in(text, name):
    """在给定源码文本里解析单层色表（供反向用例用）。

    Args:
        text: 已去注释的源码
        name: 变量名
    Returns:
        dict[str, str]: role 键到 HEX 的映射
    """
    m = re.search(r"var\s+" + name + r"\s*=\s*\{(.*?)\};", text, re.S)
    if not m:
        return {}
    return dict(re.findall(r"'([\w-]+)'\s*:\s*'(#[0-9A-Fa-f]{6})'", m.group(1)))


def parse_type_scale_in(text):
    """在给定源码文本里解析字阶三字段（供反向用例用）。

    Args:
        text: 已去注释的源码
    Returns:
        dict[str, tuple[float, str, float]]: 'size/<档>' 到 (size, weight, lineHeight)
    """
    m = re.search(r"var\s+TYPE_SCALE\s*=\s*\{(.*?)\n\};", text, re.S)
    if not m:
        return {}
    return {
        "size/" + k: (float(size), weight, float(lh))
        for k, size, weight, lh in re.findall(
            r"([a-z0-9]+):\s*\{\s*size:\s*(\d+),\s*weight:\s*'(\w+)',\s*lineHeight:\s*([\d.]+)\s*\}",
            m.group(1),
        )
    }


def parse_scale_in(text, name):
    """在给定源码文本里解析单层数值表（供反向用例用）。

    Args:
        text: 已去注释的源码
        name: 变量名
    Returns:
        dict[str, int]: 键到数值的映射
    """
    m = re.search(r"var\s+" + name + r"\s*=\s*\{(.*?)\};", text, re.S)
    if not m:
        return {}
    out = {k: int(v) for k, v in re.findall(r"([A-Za-z0-9_]+)\s*:\s*(\d+)", m.group(1))}
    return {"xxl" if k == "xxl" else k: v for k, v in out.items()}


for label, mutate, assertion in reverse:
    mutated = strip_comments(mutate(raw))
    still_ok = False
    try:
        still_ok = assertion(mutated)
    except Exception:
        still_ok = False
    check(f"[反向] {label}", not still_ok, "造假后断言确实失败" if not still_ok else "断言未被触发")

# ============================================================
print(f"\n{'=' * 56}")
print(f"通过 {len(passed)} / 失败 {len(failed)}")
if failed:
    print("\n失败项：")
    for f in failed:
        print("  - " + f)
sys.exit(1 if failed else 0)
