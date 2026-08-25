# -*- coding: utf-8 -*-
"""
gen_prd_v2.1_docx.py
功能：基于 PRD.md 生成 Word 版产品需求文档。
输出：d:\\developer\\code\\aicoding\\s2s\\docs\\找鸭找-产品需求文档-v2.1.docx
"""
import re
from docx import Document
from docx.shared import Pt, RGBColor, Cm
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_BREAK, WD_TAB_ALIGNMENT, WD_TAB_LEADER
from docx.enum.table import WD_ALIGN_VERTICAL, WD_TABLE_ALIGNMENT
from docx.oxml.ns import qn
from docx.oxml import OxmlElement


# ======================================================================
# 0) 通用工具函数
# ======================================================================
def set_cell_shading(cell, color_hex):
    """为表格单元格设置底纹颜色。"""
    tc_pr = cell._tc.get_or_add_tcPr()
    shd = OxmlElement("w:shd")
    shd.set(qn("w:val"), "clear")
    shd.set(qn("w:color"), "auto")
    shd.set(qn("w:fill"), color_hex)
    tc_pr.append(shd)


def set_run_font(run, name="微软雅黑", size=11, bold=False, color=None):
    """统一设置 run 字体、字号、粗体、颜色；同时处理中文东亚字体。"""
    run.font.name = name
    run.font.size = Pt(size)
    run.font.bold = bold
    if color:
        run.font.color.rgb = RGBColor(*color)
    rpr = run._element.get_or_add_rPr()
    rfonts = rpr.find(qn("w:rFonts"))
    if rfonts is None:
        rfonts = OxmlElement("w:rFonts")
        rpr.append(rfonts)
    rfonts.set(qn("w:eastAsia"), name)
    rfonts.set(qn("w:ascii"), name)
    rfonts.set(qn("w:hAnsi"), name)


def add_page_break(doc):
    """在文档中插入分页符。"""
    p = doc.add_paragraph()
    run = p.add_run()
    run.add_break(WD_BREAK.PAGE)


def add_para(doc, text, size=11, bold=False, color=None, align=None,
             name="微软雅黑", space_before=2, space_after=2, line_spacing=1.25,
             left_indent=None):
    """添加一个普通段落。"""
    p = doc.add_paragraph()
    if align:
        p.alignment = align
    pf = p.paragraph_format
    pf.space_before = Pt(space_before)
    pf.space_after = Pt(space_after)
    pf.line_spacing = line_spacing
    if left_indent is not None:
        pf.left_indent = Pt(left_indent)
    if text:
        r = p.add_run(text)
        set_run_font(r, name=name, size=size, bold=bold, color=color)
    return p


def add_rich_para(doc, segments, align=None, line_spacing=1.25,
                  space_before=2, space_after=2, left_indent=None):
    """
    添加富文本段落（包含粗体/普通混排）。
    segments: [(text, bold), (text, bold), ...]
    """
    p = doc.add_paragraph()
    if align:
        p.alignment = align
    pf = p.paragraph_format
    pf.space_before = Pt(space_before)
    pf.space_after = Pt(space_after)
    pf.line_spacing = line_spacing
    if left_indent is not None:
        pf.left_indent = Pt(left_indent)
    for text, bold in segments:
        r = p.add_run(text)
        set_run_font(r, size=11, bold=bold)
    return p


def add_heading(doc, text, level=1, page_break=False):
    """添加标题（H1 18pt, H2 14pt, H3 12pt, H4 11pt）。"""
    sizes = {1: 18, 2: 14, 3: 12, 4: 11}
    colors = {
        1: (0x1F, 0x4E, 0x79),
        2: (0x2E, 0x74, 0xB5),
        3: (0x33, 0x33, 0x33),
        4: (0x55, 0x55, 0x55),
    }
    if page_break and level == 1:
        add_page_break(doc)
    p = doc.add_paragraph()
    p.paragraph_format.space_before = Pt(14 if level == 1 else 10)
    p.paragraph_format.space_after = Pt(8 if level == 1 else 6)
    p.paragraph_format.line_spacing = 1.3
    p.paragraph_format.keep_with_next = True
    r = p.add_run(text)
    set_run_font(r, name="微软雅黑", size=sizes.get(level, 11),
                 bold=True, color=colors.get(level))
    return p


def add_quote(doc, text, size=10):
    """添加引用块（左侧浅黄底纹，灰色斜体）。"""
    p = doc.add_paragraph()
    p.paragraph_format.left_indent = Pt(16)
    p.paragraph_format.right_indent = Pt(16)
    p.paragraph_format.space_before = Pt(4)
    p.paragraph_format.space_after = Pt(4)
    p.paragraph_format.line_spacing = 1.4
    r = p.add_run(text)
    set_run_font(r, name="微软雅黑", size=size, color=(0x66, 0x66, 0x66))
    # 添加底纹
    pPr = p._p.get_or_add_pPr()
    shd = OxmlElement("w:shd")
    shd.set(qn("w:val"), "clear")
    shd.set(qn("w:color"), "auto")
    shd.set(qn("w:fill"), "FFF8E1")
    pPr.append(shd)
    # 左侧边框
    pbdr = OxmlElement("w:pBdr")
    left = OxmlElement("w:left")
    left.set(qn("w:val"), "single")
    left.set(qn("w:sz"), "24")
    left.set(qn("w:color"), "0B7C8C")
    pbdr.append(left)
    pPr.append(pbdr)
    return p


def add_code_block(doc, text):
    """添加代码块（Consolas 9pt，浅灰底）。"""
    for line in text.split("\n"):
        p = doc.add_paragraph()
        p.paragraph_format.space_before = Pt(0)
        p.paragraph_format.space_after = Pt(0)
        p.paragraph_format.line_spacing = 1.2
        p.paragraph_format.left_indent = Pt(12)
        r = p.add_run(line if line else " ")
        set_run_font(r, name="Consolas", size=9, color=(0x33, 0x33, 0x33))
        # 底纹
        pPr = p._p.get_or_add_pPr()
        shd = OxmlElement("w:shd")
        shd.set(qn("w:val"), "clear")
        shd.set(qn("w:color"), "auto")
        shd.set(qn("w:fill"), "F5F5F5")
        pPr.append(shd)


def add_bullet(doc, text, size=11, level=0):
    """无序列表段落。"""
    p = doc.add_paragraph(style="List Bullet" if level == 0 else "List Bullet 2")
    p.paragraph_format.space_before = Pt(1)
    p.paragraph_format.space_after = Pt(1)
    p.paragraph_format.line_spacing = 1.4
    # 处理 **粗体** 标记
    for seg_text, seg_bold in parse_inline_bold(text):
        r = p.add_run(seg_text)
        set_run_font(r, size=size, bold=seg_bold)
    return p


def add_numbered(doc, text, size=11):
    """有序列表段落。"""
    p = doc.add_paragraph(style="List Number")
    p.paragraph_format.space_before = Pt(1)
    p.paragraph_format.space_after = Pt(1)
    p.paragraph_format.line_spacing = 1.4
    for seg_text, seg_bold in parse_inline_bold(text):
        r = p.add_run(seg_text)
        set_run_font(r, size=size, bold=seg_bold)
    return p


def parse_inline_bold(text):
    """解析 **粗体** 标记，返回 [(text, bold), ...] 段。"""
    segments = []
    parts = re.split(r"(\*\*[^*]+\*\*)", text)
    for part in parts:
        if part.startswith("**") and part.endswith("**"):
            segments.append((part[2:-2], True))
        else:
            segments.append((part, False))
    return segments


def add_table_from_md(doc, header_row, body_rows, col_widths=None):
    """根据表头和表体创建表格。header_row = [c1, c2, ...]"""
    n_cols = len(header_row)
    table = doc.add_table(rows=1, cols=n_cols)
    table.style = "Light Grid Accent 1"
    table.alignment = WD_TABLE_ALIGNMENT.CENTER
    table.autofit = False
    # 表头
    hdr_cells = table.rows[0].cells
    for i, cell_text in enumerate(header_row):
        cell = hdr_cells[i]
        cell.vertical_alignment = WD_ALIGN_VERTICAL.CENTER
        set_cell_shading(cell, "1F4E79")
        cell.paragraphs[0].paragraph_format.space_before = Pt(2)
        cell.paragraphs[0].paragraph_format.space_after = Pt(2)
        r = cell.paragraphs[0].add_run(cell_text.strip())
        set_run_font(r, name="微软雅黑", size=10, bold=True,
                     color=(0xFF, 0xFF, 0xFF))
    # 表体
    for row_data in body_rows:
        row_cells = table.add_row().cells
        for i in range(n_cols):
            cell = row_cells[i]
            cell.vertical_alignment = WD_ALIGN_VERTICAL.TOP
            cell.paragraphs[0].paragraph_format.space_before = Pt(1)
            cell.paragraphs[0].paragraph_format.space_after = Pt(1)
            text = row_data[i] if i < len(row_data) else ""
            for seg_text, seg_bold in parse_inline_bold(text):
                r = cell.paragraphs[0].add_run(seg_text)
                set_run_font(r, name="微软雅黑", size=10, bold=seg_bold)
    # 列宽
    if col_widths:
        for i, w in enumerate(col_widths):
            for row in table.rows:
                if i < len(row.cells):
                    row.cells[i].width = Cm(w)
    return table


def add_do_dont_table(doc, do_items, dont_items):
    """专门渲染 **做**/**不做** 表格，2 列等宽。"""
    table = doc.add_table(rows=1, cols=2)
    table.style = "Light Grid Accent 1"
    table.alignment = WD_TABLE_ALIGNMENT.CENTER
    table.autofit = False
    # 表头
    hdr_cells = table.rows[0].cells
    for i, label in enumerate(["做", "不做"]):
        cell = hdr_cells[i]
        set_cell_shading(cell, "0B7C8C" if i == 0 else "C0392B")
        cell.vertical_alignment = WD_ALIGN_VERTICAL.CENTER
        r = cell.paragraphs[0].add_run(label)
        set_run_font(r, name="微软雅黑", size=11, bold=True,
                     color=(0xFF, 0xFF, 0xFF))
        cell.paragraphs[0].alignment = WD_ALIGN_PARAGRAPH.CENTER
    # 行数对齐
    max_len = max(len(do_items), len(dont_items))
    for idx in range(max_len):
        row_cells = table.add_row().cells
        for col_idx, items in enumerate([do_items, dont_items]):
            cell = row_cells[col_idx]
            cell.vertical_alignment = WD_ALIGN_VERTICAL.TOP
            text = items[idx] if idx < len(items) else ""
            if text:
                for seg_text, seg_bold in parse_inline_bold(text):
                    r = cell.paragraphs[0].add_run(seg_text)
                    set_run_font(r, name="微软雅黑", size=10, bold=seg_bold)
    for row in table.rows:
        for cell in row.cells:
            cell.width = Cm(8.0)
    return table


# ======================================================================
# 1) 文档初始化与全局设置
# ======================================================================
def init_document():
    doc = Document()
    # 页面边距
    section = doc.sections[0]
    section.top_margin = Cm(2.54)
    section.bottom_margin = Cm(2.54)
    section.left_margin = Cm(3.18)
    section.right_margin = Cm(3.18)
    # 默认字体
    style = doc.styles["Normal"]
    style.font.name = "微软雅黑"
    style.font.size = Pt(11)
    rpr = style.element.get_or_add_rPr()
    rfonts = rpr.find(qn("w:rFonts"))
    if rfonts is None:
        rfonts = OxmlElement("w:rFonts")
        rpr.append(rfonts)
    rfonts.set(qn("w:eastAsia"), "微软雅黑")
    rfonts.set(qn("w:ascii"), "Calibri")
    rfonts.set(qn("w:hAnsi"), "Calibri")
    return doc


# ======================================================================
# 2) 标题页
# ======================================================================
def add_title_page(doc):
    add_para(doc, "", size=11, space_before=24, space_after=12)
    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    r = p.add_run("找鸭找 APP")
    set_run_font(r, name="微软雅黑", size=28, bold=True,
                 color=(0x1F, 0x4E, 0x79))

    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    r = p.add_run("产品需求文档（PRD）")
    set_run_font(r, name="微软雅黑", size=22, bold=True,
                 color=(0x2E, 0x74, 0xB5))

    add_para(doc, "", size=11, space_before=20, space_after=8)

    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    r = p.add_run("版本 v2.1 · 评审中")
    set_run_font(r, name="微软雅黑", size=16, bold=True,
                 color=(0xC0, 0x39, 0x2B))

    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    r = p.add_run("编制日期：2026-08-19")
    set_run_font(r, name="微软雅黑", size=12, color=(0x55, 0x55, 0x55))

    add_para(doc, "", size=11, space_before=40, space_after=8)

    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    r = p.add_run("编制人：产品经理（刘杰）")
    set_run_font(r, name="微软雅黑", size=12, color=(0x55, 0x55, 0x55))

    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    r = p.add_run("文档受众：产品 / 设计 / 研发 / 测试 / 运营")
    set_run_font(r, name="微软雅黑", size=12, color=(0x55, 0x55, 0x55))

    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    r = p.add_run("关联文档：BRD.md（商业需求文档）、MRD.md（市场需求文档）")
    set_run_font(r, name="微软雅黑", size=11, color=(0x55, 0x55, 0x55))

    add_para(doc, "", size=11, space_before=60, space_after=4)

    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    r = p.add_run("本文档与 BRD / MRD 共同构成产品定义基线")
    set_run_font(r, name="微软雅黑", size=10, color=(0x88, 0x88, 0x88))

    add_page_break(doc)


# ======================================================================
# 2) 自动目录页（基于已收集的 H1/H2 标题渲染）
# ======================================================================
def add_toc_page(doc, toc_entries):
    """
    渲染自动目录页。
    toc_entries: list of (level, text, page_hint)
      level=1: 一级章节
      level=2: 二级章节
    """
    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    r = p.add_run("目  录")
    set_run_font(r, name="微软雅黑", size=20, bold=True,
                 color=(0x1F, 0x4E, 0x79))

    add_para(doc, "", size=11, space_before=8, space_after=4)

    # 提示文字
    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    r = p.add_run("（打开后右键“更新域”可同步页码）")
    set_run_font(r, name="微软雅黑", size=9,
                 color=(0x88, 0x88, 0x88))

    add_para(doc, "", size=11, space_before=4, space_after=4)

    # 目录条目
    for level, text, _ in toc_entries:
        if level == 1:
            indent_pt = 0
            size = 12
            bold = True
            color = (0x1F, 0x4E, 0x79)
        else:  # level == 2
            indent_pt = 18
            size = 10
            bold = False
            color = (0x33, 0x33, 0x33)

        p = doc.add_paragraph()
        pf = p.paragraph_format
        pf.left_indent = Pt(indent_pt)
        pf.space_before = Pt(2)
        pf.space_after = Pt(2)
        # 添加制表符右侧页码占位
        tab_stops = pf.tab_stops
        tab_stops.add_tab_stop(Cm(15.5),
                                alignment=WD_TAB_ALIGNMENT.RIGHT,
                                leader=WD_TAB_LEADER.DOTS)
        r = p.add_run(text)
        set_run_font(r, name="微软雅黑", size=size, bold=bold,
                     color=color)
        # 制表符 + 占位页码
        r2 = p.add_run("\t—")
        set_run_font(r2, name="微软雅黑", size=size, bold=bold,
                     color=color)

    add_page_break(doc)


# ======================================================================
# 3) 主流程：解析 Markdown 块并渲染
# ======================================================================
def parse_table_row(line):
    """解析一行 markdown 表格为列表。"""
    line = line.strip()
    if not line.startswith("|"):
        return None
    # 去掉首尾 |
    inner = line.strip("|")
    cells = [c.strip() for c in inner.split("|")]
    return cells


def is_table_separator(line):
    """判断是否是表格分隔行（| --- | --- |）。"""
    line = line.strip()
    if not line.startswith("|"):
        return False
    cells = [c.strip() for c in line.strip("|").split("|")]
    for c in cells:
        if not re.match(r"^:?-+:?$", c):
            return False
    return True


def is_do_dont_header(cells):
    """判断是否是 **做** | **不做** 表头。"""
    if len(cells) != 2:
        return False
    a = re.sub(r"\*", "", cells[0]).strip()
    b = re.sub(r"\*", "", cells[1]).strip()
    return a == "做" and b == "不做"


def render_table_block(doc, lines, start_idx):
    """
    渲染 markdown 表格块。
    返回下一个待处理行号。
    """
    header = parse_table_row(lines[start_idx])
    # 检查表头
    if not header:
        return start_idx
    # 跳过表头与分隔符
    body_start = start_idx + 1
    if body_start < len(lines) and is_table_separator(lines[body_start]):
        body_start += 1
    # 收集表体
    body = []
    i = body_start
    while i < len(lines):
        row = parse_table_row(lines[i])
        if not row:
            break
        body.append(row)
        i += 1
    # 判断是否 **做**/**不做** 表格
    if is_do_dont_header(header):
        add_do_dont_table(doc, [b[0] for b in body if len(b) >= 1],
                          [b[1] for b in body if len(b) >= 2])
    else:
        add_table_from_md(doc, header, body)
    return i


def render_inline_paragraph(doc, line, base_size=11, line_spacing=1.25,
                            space_before=2, space_after=2, left_indent=None,
                            align=None):
    """渲染含粗体的段落。"""
    segments = parse_inline_bold(line)
    if not segments or all(s[0] == "" for s in segments):
        # 空段
        add_para(doc, "", size=base_size, line_spacing=line_spacing,
                 space_before=space_before, space_after=space_after,
                 left_indent=left_indent, align=align)
        return
    p = doc.add_paragraph()
    if align:
        p.alignment = align
    pf = p.paragraph_format
    pf.space_before = Pt(space_before)
    pf.space_after = Pt(space_after)
    pf.line_spacing = line_spacing
    if left_indent is not None:
        pf.left_indent = Pt(left_indent)
    for text, bold in segments:
        if not text:
            continue
        r = p.add_run(text)
        set_run_font(r, size=base_size, bold=bold)


def main():
    """主函数：读取 PRD.md 并生成 Word 版产品需求文档。"""
    src = r"d:\developer\code\aicoding\s2s\docs\PRD.md"
    dst = r"d:\developer\code\aicoding\s2s\docs\找鸭找-产品需求文档-v2.1_tmp.docx"  # 避开 Word 文件锁，生成后由外部改名

    with open(src, "r", encoding="utf-8") as f:
        lines = f.readlines()

    doc = init_document()
    add_title_page(doc)

    # ---- 跳过文档标题与元信息表（已由标题页承载），从 "## 0. 产品总览" 开始正文 ----
    i = 0
    while i < len(lines):
        if lines[i].rstrip("\n").startswith("## 0. 产品总览"):
            break
        i += 1

    in_code_block = False
    code_buffer = []

    # 收集目录（H1 + H2 标题）
    toc_entries = []  # [(level, text, page_hint)]
    # 跳过内置标题（如 H3/H4 不入目录）

    while i < len(lines):
        line = lines[i].rstrip("\n")
        stripped = line.strip()

        # 代码块处理
        if stripped.startswith("```"):
            if not in_code_block:
                in_code_block = True
                code_buffer = []
            else:
                # 结束代码块
                add_code_block(doc, "\n".join(code_buffer))
                in_code_block = False
                code_buffer = []
            i += 1
            continue
        if in_code_block:
            code_buffer.append(line)
            i += 1
            continue

        # 跳过空行
        if not stripped:
            i += 1
            continue

        # 标题
        if stripped.startswith("#### "):
            add_heading(doc, stripped[5:].strip(), level=4)
            i += 1
            continue
        if stripped.startswith("### "):
            add_heading(doc, stripped[4:].strip(), level=3)
            i += 1
            continue
        if stripped.startswith("## "):
            text = stripped[3:].strip()
            add_heading(doc, text, level=2)
            toc_entries.append((2, text, None))
            i += 1
            continue
        if stripped.startswith("# "):
            text = stripped[2:].strip()
            # 一级标题前分页
            add_heading(doc, text, level=1, page_break=True)
            toc_entries.append((1, text, None))
            i += 1
            continue

        # 表格
        if stripped.startswith("|") and parse_table_row(line):
            i = render_table_block(doc, lines, i)
            continue

        # 引用块
        if stripped.startswith("> "):
            text = stripped[2:].strip()
            add_quote(doc, text, size=10)
            i += 1
            continue

        # 水平分隔线
        if stripped == "---":
            # 不渲染（标题已分页）
            i += 1
            continue

        # 无序列表
        if re.match(r"^[-*+]\s+", stripped):
            text = re.sub(r"^[-*+]\s+", "", stripped)
            add_bullet(doc, text)
            i += 1
            continue

        # 有序列表
        if re.match(r"^\d+\.\s+", stripped):
            text = re.sub(r"^\d+\.\s+", "", stripped)
            add_numbered(doc, text)
            i += 1
            continue

        # 普通段落
        render_inline_paragraph(doc, stripped)
        i += 1

    # ===========================================================
    # 文档末尾结束标记
    # ===========================================================
    add_para(doc, "", size=11, space_before=20, space_after=4)
    add_para(doc, "—— 文档结束 ——", size=10, color=(0x88, 0x88, 0x88),
             align=WD_ALIGN_PARAGRAPH.CENTER)

    # ===========================================================
    # 在标题页后、第一章前插入自动目录
    # 策略：先找到标题页的分页符位置，把 toc 段落插入到其后
    # ===========================================================
    insert_toc_after_title_page(doc, toc_entries)

    doc.save(dst)
    print(f"[OK] 已生成: {dst}（含 {len(toc_entries)} 条目录项）")


def insert_toc_after_title_page(doc, toc_entries):
    """
    在标题页分页符后、第一个 H1 章节前，插入自动目录页。
    实现：通过遍历 doc.element.body 的子元素，找到第一个 page-break 后的位置。
    """
    from docx.oxml.ns import qn as q
    body = doc.element.body

    # 找到所有顶层段落
    paragraphs = list(body.iterchildren(q("w:p")))
    if not paragraphs:
        return

    # 找到标题页的最后一个分页符（即第一个分页段落）
    # 简化策略：找到第一个 H1 章节的段落（即第一个 add_heading 后的 page-break 段）
    # 标题页内有一个 add_page_break
    # 然后第一个 H1 章节前 add_page_break（即"第一章：§0 产品总览"前的分页）
    # 我们要在第二个 page-break 之前插入目录页

    # 实际策略：找到 H1 标题"§0 产品总览"的位置，把目录段落插在它之前
    # 由于 H1 章节自带分页符 add_heading(..., page_break=True)，会先插入一个 break 段落
    # 然后是 H1 标题段落
    # 我们在 break 段落之前插入目录

    # 找到第一个 H1 标题段落（按内容匹配）
    target_idx = None
    for idx, p in enumerate(body.iterchildren()):
        # 段落
        text = "".join(t.text or "" for t in p.iter(q("w:t")))
        if "产品总览" in text and p.tag == q("w:p"):
            target_idx = idx
            break

    if target_idx is None:
        return  # 找不到就跳过

    # 生成目录段落（暂存到一个 list）
    toc_paragraphs = []
    # 标题段
    p_title = doc.paragraphs[0]._p  # 借用样式
    from copy import deepcopy
    new_title = deepcopy(p_title)
    # 清空文本
    for t in new_title.iter(q("w:t")):
        t.text = ""
    # 重新写入
    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    r = p.add_run("目  录")
    set_run_font(r, name="微软雅黑", size=20, bold=True,
                 color=(0x1F, 0x4E, 0x79))
    toc_paragraphs.append(p._p)
    p._p.getparent().remove(p._p)  # 暂时移出 body

    # 提示
    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    r = p.add_run("（打开后右键“更新域”可同步页码）")
    set_run_font(r, name="微软雅黑", size=9,
                 color=(0x88, 0x88, 0x88))
    toc_paragraphs.append(p._p)
    p._p.getparent().remove(p._p)

    # 空行
    p = doc.add_paragraph()
    toc_paragraphs.append(p._p)
    p._p.getparent().remove(p._p)

    # 目录条目
    for level, text, _ in toc_entries:
        if level == 1:
            indent_pt = 0
            size = 12
            bold = True
            color = (0x1F, 0x4E, 0x79)
        else:
            indent_pt = 18
            size = 10
            bold = False
            color = (0x33, 0x33, 0x33)

        p = doc.add_paragraph()
        pf = p.paragraph_format
        pf.left_indent = Pt(indent_pt)
        pf.space_before = Pt(2)
        pf.space_after = Pt(2)
        tab_stops = pf.tab_stops
        tab_stops.add_tab_stop(Cm(15.5),
                                alignment=WD_TAB_ALIGNMENT.RIGHT,
                                leader=WD_TAB_LEADER.DOTS)
        r = p.add_run(text)
        set_run_font(r, name="微软雅黑", size=size, bold=bold,
                     color=color)
        r2 = p.add_run("\t—")
        set_run_font(r2, name="微软雅黑", size=size, bold=bold,
                     color=color)
        toc_paragraphs.append(p._p)
        p._p.getparent().remove(p._p)

    # 目录后的分页符
    p = doc.add_paragraph()
    p.add_run().add_break(WD_BREAK.PAGE)
    toc_paragraphs.append(p._p)
    p._p.getparent().remove(p._p)

    # 把目录段落插入到 target_idx 之前
    for offset, p_elem in enumerate(toc_paragraphs):
        body.insert(target_idx + offset, p_elem)


if __name__ == "__main__":
    main()
