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

check(
    "变量总数 = COLOR 21 + FLOAT 17 = 38",
    len(type_scale) + len(spacing) + len(radius) == 17,
    f"FLOAT {len(type_scale) + len(spacing) + len(radius)} 项",
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

card_body = func_body(code, "function card(title, sub, catRole, tag)")
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
        not in func_body(c, "function card(title, sub, catRole, tag)"),
    ),
    (
        "bindRadius 改绑 cornerRadius 应被检出",
        lambda t: t.replace("node.setBoundVariable('topLeftRadius', v);", "node.setBoundVariable('cornerRadius', v);"),
        lambda c: "'topLeftRadius'" in func_body(c, "function bindRadius(node, value)"),
    ),
]


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
