# -*- coding: utf-8 -*-
"""
gen_prd_docx.py
功能：基于 PRD.md 原文档 + 2026-08-19 Scope 校正要点，生成 Word 版 PRD 文档。
输出：d:\\developer\\code\\aicoding\\s2s\\docs\\PRD.docx
"""
from docx import Document
from docx.shared import Pt, RGBColor, Cm, Inches
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_LINE_SPACING
from docx.enum.table import WD_ALIGN_VERTICAL, WD_TABLE_ALIGNMENT
from docx.oxml.ns import qn
from docx.oxml import OxmlElement


# ======================================================================
# 0) 通用工具函数
# ======================================================================
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


def add_para(doc, text, size=11, bold=False, color=None, align=None,
             name="微软雅黑", space_before=2, space_after=2, line_spacing=1.5):
    """添加一个普通段落。"""
    p = doc.add_paragraph()
    if align:
        p.alignment = align
    pf = p.paragraph_format
    pf.space_before = Pt(space_before)
    pf.space_after = Pt(space_after)
    pf.line_spacing = line_spacing
    r = p.add_run(text)
    set_run_font(r, name=name, size=size, bold=bold, color=color)
    return p


def add_heading(doc, text, level=1):
    """自定义标题（替代 python-docx 默认 heading，避免样式漂移）。"""
    sizes = {1: 20, 2: 16, 3: 14, 4: 12}
    colors = {1: (0x1F, 0x4E, 0x79), 2: (0x2E, 0x74, 0xB5), 3: (0x33, 0x33, 0x33), 4: (0x55, 0x55, 0x55)}
    p = doc.add_paragraph()
    p.paragraph_format.space_before = Pt(12 if level <= 2 else 8)
    p.paragraph_format.space_after = Pt(6)
    p.paragraph_format.line_spacing = 1.3
    r = p.add_run(text)
    set_run_font(r, name="微软雅黑", size=sizes.get(level, 12),
                 bold=True, color=colors.get(level))
    return p


def add_scope_note(doc, text):
    """添加 Scope 校正标记段落，红色 + 加粗 + 前缀【Scope校正】。"""
    p = doc.add_paragraph()
    p.paragraph_format.space_before = Pt(4)
    p.paragraph_format.space_after = Pt(4)
    p.paragraph_format.line_spacing = 1.4
    r = p.add_run("【Scope校正】" + text)
    set_run_font(r, name="微软雅黑", size=10, bold=True,
                 color=(0xC0, 0x39, 0x2B))
    # 段落底纹淡黄
    pPr = p._p.get_or_add_pPr()
    shd = OxmlElement("w:shd")
    shd.set(qn("w:val"), "clear")
    shd.set(qn("w:color"), "auto")
    shd.set(qn("w:fill"), "FFF8E1")
    pPr.append(shd)
    return p


def add_bullet(doc, text, size=11, level=0):
    """无序列表段落。"""
    p = doc.add_paragraph(style="List Bullet" if level == 0 else "List Bullet 2")
    p.paragraph_format.space_before = Pt(1)
    p.paragraph_format.space_after = Pt(1)
    p.paragraph_format.line_spacing = 1.4
    r = p.add_run(text)
    set_run_font(r, size=size)
    return p


def add_numbered(doc, text, size=11):
    """有序列表段落。"""
    p = doc.add_paragraph(style="List Number")
    p.paragraph_format.space_before = Pt(1)
    p.paragraph_format.space_after = Pt(1)
    p.paragraph_format.line_spacing = 1.4
    r = p.add_run(text)
    set_run_font(r, size=size)
    return p


def add_table(doc, headers, rows, col_widths=None, header_color="1F4E79"):
    """生成带样式的表格。headers: list[str]; rows: list[list[str]]。"""
    table = doc.add_table(rows=1, cols=len(headers))
    table.alignment = WD_TABLE_ALIGNMENT.CENTER
    table.style = "Table Grid"
    # 表头
    hdr = table.rows[0].cells
    for i, h in enumerate(headers):
        hdr[i].text = ""
        p = hdr[i].paragraphs[0]
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        r = p.add_run(h)
        set_run_font(r, name="微软雅黑", size=10, bold=True,
                     color=(0xFF, 0xFF, 0xFF))
        # 表头底色
        tcPr = hdr[i]._tc.get_or_add_tcPr()
        shd = OxmlElement("w:shd")
        shd.set(qn("w:val"), "clear")
        shd.set(qn("w:color"), "auto")
        shd.set(qn("w:fill"), header_color)
        tcPr.append(shd)
        hdr[i].vertical_alignment = WD_ALIGN_VERTICAL.CENTER
    # 数据行
    for row_data in rows:
        cells = table.add_row().cells
        for i, val in enumerate(row_data):
            cells[i].text = ""
            p = cells[i].paragraphs[0]
            p.paragraph_format.line_spacing = 1.2
            r = p.add_run(str(val))
            set_run_font(r, name="微软雅黑", size=9)
            cells[i].vertical_alignment = WD_ALIGN_VERTICAL.CENTER
    # 列宽
    if col_widths:
        for i, w in enumerate(col_widths):
            for row in table.rows:
                row.cells[i].width = Cm(w)
    return table


def add_code_block(doc, text):
    """生成等宽字体代码块（淡灰底）。"""
    p = doc.add_paragraph()
    p.paragraph_format.space_before = Pt(4)
    p.paragraph_format.space_after = Pt(4)
    p.paragraph_format.line_spacing = 1.2
    r = p.add_run(text)
    set_run_font(r, name="Consolas", size=9, color=(0x1a, 0x1a, 0x1a))
    pPr = p._p.get_or_add_pPr()
    shd = OxmlElement("w:shd")
    shd.set(qn("w:val"), "clear")
    shd.set(qn("w:color"), "auto")
    shd.set(qn("w:fill"), "F4F4F4")
    pPr.append(shd)
    # 边框
    pBdr = OxmlElement("w:pBdr")
    for side in ("top", "left", "bottom", "right"):
        b = OxmlElement(f"w:{side}")
        b.set(qn("w:val"), "single")
        b.set(qn("w:sz"), "4")
        b.set(qn("w:color"), "CCCCCC")
        pBdr.append(b)
    pPr.append(pBdr)
    return p


def add_page_break(doc):
    doc.add_page_break()


def set_page_header(doc, text):
    """设置页眉。"""
    section = doc.sections[0]
    section.different_first_page_header_footer = True
    header = section.header
    p = header.paragraphs[0]
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    r = p.add_run(text)
    set_run_font(r, name="微软雅黑", size=9, color=(0x7F, 0x7F, 0x7F))
    # 页眉下加一条线
    pPr = p._p.get_or_add_pPr()
    pBdr = OxmlElement("w:pBdr")
    bottom = OxmlElement("w:bottom")
    bottom.set(qn("w:val"), "single")
    bottom.set(qn("w:sz"), "6")
    bottom.set(qn("w:color"), "BFBFBF")
    pBdr.append(bottom)
    pPr.append(pBdr)


def add_section_label(doc, text):
    """8 段式段落的小节标签（如“功能名”“需求描述”）。"""
    p = doc.add_paragraph()
    p.paragraph_format.space_before = Pt(6)
    p.paragraph_format.space_after = Pt(2)
    p.paragraph_format.line_spacing = 1.4
    r = p.add_run("▍" + text)
    set_run_font(r, name="微软雅黑", size=11, bold=True,
                 color=(0x1F, 0x4E, 0x79))
    return p


def add_8section(doc, sections):
    """8 段式输出。sections: dict {段落名: 内容(支持 str/list)}。"""
    order = ["功能名", "需求描述", "概述", "相关页面设计",
             "用户旅程", "用户故事", "实现逻辑", "功能细节描述"]
    for key in order:
        if key not in sections:
            continue
        add_section_label(doc, key)
        content = sections[key]
        if isinstance(content, str):
            add_para(doc, content, size=10)
        elif isinstance(content, list):
            for item in content:
                if isinstance(item, tuple) and item[0] == "table":
                    add_table(doc, item[1], item[2])
                elif isinstance(item, tuple) and item[0] == "code":
                    add_code_block(doc, item[1])
                elif isinstance(item, tuple) and item[0] == "scope":
                    add_scope_note(doc, item[1])
                elif isinstance(item, tuple) and item[0] == "bullet":
                    add_bullet(doc, item[1])
                elif isinstance(item, tuple) and item[0] == "h4":
                    add_heading(doc, item[1], level=4)
                else:
                    add_para(doc, str(item), size=10)


# ======================================================================
# 1) 主函数：构建文档
# ======================================================================
def build_doc():
    doc = Document()

    # 页面基础设置
    section = doc.sections[0]
    section.top_margin = Cm(2.2)
    section.bottom_margin = Cm(2.2)
    section.left_margin = Cm(2.4)
    section.right_margin = Cm(2.4)

    # 默认正文样式
    style = doc.styles["Normal"]
    style.font.name = "微软雅黑"
    style.font.size = Pt(11)
    style.element.rPr.rFonts.set(qn("w:eastAsia"), "微软雅黑")

    # 页眉
    set_page_header(doc, "Scope校正版 v2.1  ·  找鸭找 APP v2 PRD  ·  2026-08-19")

    # ---------------- 标题页 ----------------
    add_para(doc, "找鸭找 APP v2", size=30, bold=True,
             color=(0x1F, 0x4E, 0x79), align=WD_ALIGN_PARAGRAPH.CENTER,
             space_before=80, space_after=10)
    add_para(doc, "产品需求文档（PRD）", size=22, bold=True,
             color=(0x2E, 0x74, 0xB5), align=WD_ALIGN_PARAGRAPH.CENTER,
             space_after=20)
    add_para(doc, "v2.1 Scope校正版", size=18, bold=True,
             color=(0xC0, 0x39, 0x2B), align=WD_ALIGN_PARAGRAPH.CENTER,
             space_after=30)
    add_para(doc, "2026-08-19 冻结", size=14, bold=False,
             color=(0x55, 0x55, 0x55), align=WD_ALIGN_PARAGRAPH.CENTER,
             space_after=60)

    # Scope 校正要点总览（标题页内嵌）
    add_heading(doc, "Scope校正要点总览（2026-08-19 冻结）", level=2)
    scope_points = [
        "定位：纯需求/资源信息共享平台，永久不做支付/不做交易担保/不做信誉评价系统/不追踪撮合结果。",
        "AI能力（三大目标#1）：LR+GBDT 双轨匹配（纯信息特征 7 类：联系点击/位置/时效/分类/认证/关键词/完整度，不取撮合反馈/历史信誉）+ 3B 小模型严格 Scope 管线 AI 辅助发布。",
        "地图图层（三大目标#2）：图层核心=5大类三级树分类快速加载引擎（预渲染+按需取数+本地三级缓存，P95≤300ms硬指标），不做认证/时效/质量筛选器/金字塔五层视觉炫技/撮合热力。图层弹层=分类三级勾选树（5大类→二级类目→三级类目），视觉仅保留供需双色（实心=供/空心=需）+完整度角标（🟢🟡🔴）。",
        "分级管理（三大目标#3）：信息完整度三档🟢🟡🔴（必填项50%+位置精度30%+类目匹配度20%，阈值≥85%=🟢/50-84%=🟡/<50%=🔴）+ 基础实名权限两档（未实名每日3条/实名无限次），不做 QS 五档信誉/钻石金牌标签/五级权限阶梯/商业化售卖。",
        "北极星：3步找到率 = AI匹配召回率 × 图层加载成功率（P95≤300ms）× 🟢完整发布率（合格线 ≥ 0.5）。",
        "联系方式：永久单轨中转页（电话/VX二选一 + 号码中间4位脱敏 + 触达埋点），不接 IM SDK/不做文本聊天/不设 DAU 阈值切换。",
        "口号：附近谁有谁要 → 打开APP勾分类 → 3步300ms看到、30秒联系上。",
        "信任认证：只做二层独立认证标（实名/资质）+ 信息完整度三档角标，不做动态衰减信誉分/不做撮合反馈激励/不做历史撮合追踪。",
        "信息维护：7天一键刷新有效期 + 14天不续从推荐池下架 + 发布后1h完整度升级引导，不做撮合确认码/不做撮合反馈/不跑权重回归模型。",
    ]
    for i, pt in enumerate(scope_points, 1):
        add_para(doc, f"{i}. {pt}", size=10, color=(0x33, 0x33, 0x33),
                 space_before=2, space_after=2)

    add_page_break(doc)

    # ---------------- §0 产品总览 ----------------
    add_heading(doc, "0. 产品总览", level=1)

    add_heading(doc, "0.1 一句话定义", level=2)
    add_para(doc, "找鸭找 = 5公里生活圈 · 双向供需信息撮合 APP", size=12, bold=True,
             color=(0x1F, 0x4E, 0x79))
    add_para(doc, "用就近的资源解决本地的需求。资源方与需求方双向发布，平台做就近匹配与信息共享，交易在线下达成。",
             size=10)
    add_scope_note(doc, "定位收紧为「纯需求/资源信息共享平台」：永久不做支付、不做交易担保、不做信誉评价系统、不追踪撮合结果。撮合动作完全交由用户线下完成。")

    add_heading(doc, "0.2 北极星指标", level=2)
    add_para(doc, "3步找到率 = AI匹配召回率 × 图层加载成功率（P95≤300ms）× 🟢完整发布率", size=12, bold=True,
             color=(0xC0, 0x39, 0x2B))
    add_para(doc, "合格线 ≥ 0.5（即三项乘积至少达到 0.5 视为本期目标达成）", size=10, bold=True)
    add_scope_note(doc, "原「近场撮合完成率（24h内有效联系比例）」被废弃，因不再追踪撮合结果。新北极星改为纯信息三乘积，三个因子均可纯信息侧测量，无隐私与撮合反馈依赖。")

    add_heading(doc, "0.3 本期边界", level=2)
    add_table(doc,
              ["维度", "做（In Scope）", "不做（Out of Scope）"],
              [
                  ["定位", "5km默认就近（可调1/3/5/10/全城）", "线上支付与结算、交易担保"],
                  ["发布", "资源/需求双向发布", "交易订单、信誉评价闭环、撮合结果追踪"],
                  ["分类", "多级分类（工作/房屋/车辆/生活/服务）", "—"],
                  ["发布方式", "模板化发布 + 发布记忆 + AI辅助发布（3B小模型严格Scope）", "无Scope约束的通用AI生成、幻觉内容"],
                  ["认证", "二层独立认证标（实名/资质）", "QS五档信誉、动态衰减信誉分、钻石金牌标签"],
                  ["分级", "信息完整度三档🟢🟡🔴 + 实名权限两档", "五级权限阶梯、商业化售卖"],
                  ["地图", "5大类三级树分类快速加载引擎 + 弹层勾选树 + 供需双色 + 完整度角标", "金字塔五层视觉、认证/时效/质量筛选器、撮合热力"],
                  ["联系", "永久单轨中转页（电话/VX二选一+脱敏+触达埋点）", "站内IM SDK、文本聊天、DAU阈值切换"],
                  ["匹配", "LR+GBDT双轨灰度匹配 + 7类纯信息特征 + Hard Filter", "撮合反馈激励、历史信誉加权、权重回归模型"],
                  ["信息维护", "7天一键刷新 + 14天不续下架 + 1h完整度升级引导", "撮合确认码、撮合反馈、权重回归模型"],
              ],
              col_widths=[2.0, 6.5, 6.5])
    add_scope_note(doc, "边界表新增三条硬约束：①不做信誉评价；②不追踪撮合结果；③不接 IM SDK。任何后续评审如要解禁，必须先更新本表并经 PRD 评审通过。")

    add_heading(doc, "0.4 口号（用户心智锚点）", level=2)
    add_para(doc, "附近谁有谁要 → 打开APP勾分类 → 3步300ms看到、30秒联系上", size=12, bold=True,
             color=(0x1F, 0x4E, 0x79))
    add_scope_note(doc, "口号由原「就近的资源解决本地的需求」升级为可量化承诺：3步 + 300ms + 30秒，分别对应北极星三个因子。")

    add_heading(doc, "0.5 三大目标对应表", level=2)
    add_table(doc,
              ["三大目标", "对应模块", "硬指标"],
              [
                  ["#1 AI能力", "§11 AI智能匹配 + §12 AI智能发布", "幻觉率≈0、匹配召回率纳入北极星"],
                  ["#2 地图图层", "§6 首页地图", "P95 ≤ 300ms、三级树弹层"],
                  ["#3 分级管理", "§4 信任与认证 + §9 分级管理", "完整度三档🟢🟡🔴 + 实名权限两档"],
              ],
              col_widths=[3.0, 6.0, 5.0])

    add_page_break(doc)
