"""对比模板与生成件的文本长度，找出可能溢出重叠的文本框。

功能：按顺序配对两份 probe 报告中的文本行，输出新文字长度显著超过
      模板原文长度的条目，用于定位文字重叠风险点。
参数：无（路径写死在 main 中）
返回：无返回值，结果打印到标准输出
"""
import re


def load(path):
    """读取 probe 报告，返回 [(slide, 路径, 字号, 文字)] 列表。"""
    items = []
    slide = 0
    cur_path = ""
    for line in open(path, encoding="utf-8"):
        s = line.strip()
        m = re.match(r"===== Slide (\d+)", s)
        if m:
            slide = int(m.group(1))
            continue
        if s.startswith("[T] "):
            cur_path = s[4:]
            continue
        m = re.match(r"p(\d+)\(([\d.]+|None)\): (.*)", s)
        if m:
            size = m.group(2)
            items.append((slide, cur_path, size, m.group(3)))
    return items


def main():
    """主流程：配对比较并输出超长条目。"""
    old = load(r"d:\developer\code\aicoding\s2s\docs\probe_mrd.txt")
    new = load(r"d:\developer\code\aicoding\s2s\docs\probe_mrd_check.txt")
    print(f"old={len(old)} new={len(new)}")
    if len(old) != len(new):
        print("!! 条目数不一致，逐页核对")
    for (s1, p1, z1, t1), (s2, p2, z2, t2) in zip(old, new):
        if t1 == t2:
            print(f"[残留] S{s1} {p1} :: {t1}")
            continue
        if len(t2) > len(t1) * 1.4 and len(t2) - len(t1) >= 5:
            print(f"[超长] S{s1} {p1} ({z1}) {len(t1)}->{len(t2)}")
            print(f"       旧: {t1}")
            print(f"       新: {t2}")


if __name__ == "__main__":
    main()
