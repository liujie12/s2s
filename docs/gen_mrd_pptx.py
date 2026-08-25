"""生成 找鸭找-市场需求文档-v2.1.pptx —— 基于「市场需求模板」改造。

功能：读取市场需求模板 pptx（28 页 / 5 章），按 probe_mrd.txt 的 Group 路径
      逐个替换全部幻灯片文字为 MRD v2.1 真实内容，保留模板视觉设计。
      支持两种定位方式：
        1. path_map —— 按「形状名路径」定位（主用）
        2. text_map —— 按「原始文字」定位（用于形状名为乱码字符的页）
参数：无（路径写死在 main 中）
返回：无返回值，结果写入 找鸭找-市场需求文档-v2.1.pptx
"""

import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".pylibs"))

from pptx import Presentation
from pptx.util import Pt


def apply_text(shape, value):
    """把 value 写入 shape 的文本框，清空其余段落，可选强制字号。

    参数：
        shape: 目标形状（须含 text_frame）
        value: 字符串，或 (字符串, 字号pt) 二元组
    返回：无（原地修改）
    """
    if isinstance(value, tuple):
        new_text, force_size = value
    else:
        new_text, force_size = value, None

    tf = shape.text_frame
    tf.word_wrap = True

    # 清空全部文字但保留 run 的字体样式
    for para in tf.paragraphs:
        for run in para.runs:
            run.text = ""

    first_para = tf.paragraphs[0]
    if first_para.runs:
        target_run = first_para.runs[0]
        target_run.text = new_text
        if force_size is not None:
            target_run.font.size = Pt(force_size)
    else:
        from pptx.oxml.ns import qn
        r_elem = first_para._p.makeelement(qn("a:r"), {})
        t_elem = r_elem.makeelement(qn("a:t"), {})
        t_elem.text = new_text
        r_elem.append(t_elem)
        first_para._p.append(r_elem)


def replace_shapes(shapes, path_map, text_map, current_path=""):
    """递归遍历形状（含 Group），先按路径匹配，再按原始文字匹配并替换。

    参数：
        shapes: 形状集合（slide.shapes 或 group.shapes）
        path_map: 形状名路径 → 新文字
        text_map: 原始文字 → 新文字（路径未命中时的兜底）
        current_path: 当前路径前缀，递归时拼接
    返回：无（原地修改）
    """
    for shp in shapes:
        cur = f"{current_path} > {shp.name}" if current_path else shp.name
        is_group = shp.shape_type is not None and str(shp.shape_type).startswith("GROUP")
        if is_group:
            replace_shapes(shp.shapes, path_map, text_map, cur)
            continue
        if not shp.has_text_frame:
            continue
        if cur in path_map:
            apply_text(shp, path_map[cur])
            continue
        original = shp.text_frame.text.strip()
        if original and original in text_map:
            apply_text(shp, text_map[original])


def build_content_map():
    """构建 28 张幻灯片的内容映射表（MRD v2.1）。

    章节规划：
        01 市场概况与竞争格局（4-8）
        02 目标用户与画像（10-13）
        03 用户场景与需求优先级（15-19）
        04 Go-to-Market 市场策略（21-23）
        05 成功指标与关键假设（25-27）
    返回：dict，key=幻灯片序号（1 起），value={"path": {...}, "text": {...}}
    """
    return {
        # ================= 封面 =================
        1: {"path": {
            "Title 4": "找鸭找 APP",
            "Subtitle 8": "市场需求文档（MRD）v2.1 评审版",
            "Text Placeholder 3": "产品经理：刘杰",
            "Text Placeholder 6": "2026-08-19",
        }},
        # ================= 目录 =================
        2: {"path": {
            "Group 36 > Group 1 > TextBox 2": "Agenda",
            "Group 36 > Group 34 > Group 4 > Group 5 > TextBox 7": "01",
            "Group 36 > Group 34 > Group 4 > Group 5 > Rectangle 8": "市场概况与竞争格局",
            "Group 36 > Group 34 > Group 4 > Group 5 > Rectangle 9": "同城撮合市场分层与差异化定位",
            "Group 36 > Group 34 > Group 10 > Group 11 > TextBox 13": "02",
            "Group 36 > Group 34 > Group 10 > Group 11 > Rectangle 14": "目标用户与画像",
            "Group 36 > Group 34 > Group 10 > Group 11 > Rectangle 15": "四层用户分层与三目标使用倾向",
            "Group 36 > Group 34 > Group 16 > Group 17 > TextBox 19": "03",
            "Group 36 > Group 34 > Group 16 > Group 17 > Rectangle 20": "用户场景与需求优先级",
            "Group 36 > Group 34 > Group 16 > Group 17 > Rectangle 21": "十大核心场景与 P0 需求清单",
            "Group 36 > Group 34 > Group 22 > Group 23 > TextBox 25": "04",
            "Group 36 > Group 34 > Group 22 > Group 23 > Rectangle 26": "Go-to-Market 策略",
            "Group 36 > Group 34 > Group 22 > Group 23 > Rectangle 27": "单城试点与三批 GTM 节奏",
            "Group 36 > Group 34 > Group 28 > Group 29 > TextBox 31": "05",
            "Group 36 > Group 34 > Group 28 > Group 29 > Rectangle 32": "成功指标与关键假设",
            "Group 36 > Group 34 > Group 28 > Group 29 > Rectangle 33": "三乘积北极星与九条待验证假设",
        }},
        # ================= 章节 01 =================
        3: {"path": {
            "Title 4": "01.市场概况与竞争格局",
            "Text Placeholder 24": "同城撮合市场分层与差异化定位",
        }},
        # Slide 4: 市场分层与本品位置
        4: {"path": {
            "Group 10 > TextBox 7": "市场分层与本品位置",
            "Group 10 > TextBox 8": "近场双向撮合是空白层级",
            "Group 10 > TextBox 12": "5km 双向轻信任无竞品",
            "Group 10 > TextBox 16": "五层市场格局",
            "Group 10 > TextBox 17": "本品所处层级",
            "Group 10 > TextBox 18": "四层已被占据，仅近场双向空缺",
            "Title 23": "市场分层与本品位置",
        }},
        # Slide 5: 市场规模判断
        5: {"path": {
            "Group 64 > Group 58 > TextBox 99": "市场规模判断",
            "Group 64 > Group 58 > TextBox 100": "同城生活服务是长青基本盘，不依赖单一风口。",
            "Group 64 > Group 76 > TextBox 59": "长青基本盘",
            "Group 64 > Group 76 > TextBox 60": "本地信息撮合需求长期稳定存在",
            "Group 64 > Group 77 > TextBox 66": "5km 心智已验证",
            "Group 64 > Group 77 > TextBox 67": "社区团购与即时配送均扎根 5 公里，用户对「就近」的心智已经成熟。",
            "Group 64 > Group 78 > TextBox 72": "缝隙市场机会",
            "Group 64 > Group 78 > TextBox 73": "双向发布是未被满足的缝隙市场，本品有机会成为细分定义者。",
            "Title 102": "市场规模与机会判断",
        }},
        # Slide 6: 市场趋势（形状名为乱码字符，用原文匹配）
        6: {"text": {
            "竞争市场份额增长": "五大市场趋势",
            "市场份额稳步增长": "从多到准",
            "我们的市场份额在过去一年中稳步增长，预计将继续保持增长势头。":
                "用户对信息密度过高产生反噬，转而倾向「少而准」的精准供需。",
            "超越行业的增长": "即时性升级",
            "我们的市场份额增长速度超过了行业平均水平，证明了我们在市场竞争中的优势。":
                "用户对响应即时性要求提升，近场撮合天然满足即时需求。",
            "新产品市场增长": "信任成为预期",
            "我们成功推出了一系列创新产品，通过提供独特的解决方案，赢得了更多市场份额。":
                "隐私与信任意识提升，实名认证已成为基本预期而非加分项。",
            "对手市场份额降": "地图心智成熟",
            "竞争对手市场份额下降，我方增长机会来临": "地图交互成为本地产品标配，模板化填表被广泛接受。",
            "市场份额的变化": "五大市场趋势",
        }},
        # Slide 7: 竞品格局
        7: {"path": {
            "Group 2 > Rectangle 38": "竞品格局与借鉴",
            "Group 2 > Group 57 > Group 58 > TextBox 119": "58 同城",
            "Group 2 > Group 57 > Group 58 > Rectangle 118": "全品类但信息淹没、弱地图",
            "Group 2 > Group 120 > Group 122 > TextBox 124": "闲鱼",
            "Group 2 > Group 120 > Group 122 > Rectangle 123": "信用强但弱本地即时性",
            "Group 2 > Group 127 > Group 129 > TextBox 131": "58 到家 / 美团",
            "Group 2 > Group 127 > Group 129 > Rectangle 130": "供给丰富但抽成高",
            "Group 2 > Group 31 > Group 33 > TextBox 35": "邻里社区类",
            "Group 2 > Group 31 > Group 33 > Rectangle 34": "信任强但撮合效率弱",
            "Title 135": "竞品深度分析",
        }},
        # Slide 8: 差异化定位
        8: {"path": {
            "Group 1 > TextBox 25": "本品差异化定位",
            "Group 1 > TextBox 12": "落在「即时性强 + 交易履约弱」的右下象限，无直接竞品",
            "Group 1 > Group 27 > Oval 29": "1",
            "Group 1 > Group 27 > TextBox 30": "5km 默认范围",
            "Group 1 > Group 27 > TextBox 31": "把「近」做成第一差异化",
            "Group 1 > Group 37 > Oval 39": "2",
            "Group 1 > Group 37 > TextBox 40": "双向发布",
            "Group 1 > Group 37 > TextBox 41": "资源与需求同池双向流动",
            "Group 1 > Group 32 > Oval 34": "3",
            "Group 1 > Group 32 > TextBox 35": "本地实名信任",
            "Group 1 > Group 32 > TextBox 36": "实名与资质认证替代信誉体系",
            "Group 1 > Group 14 > Oval 4": "4",
            "Group 1 > Group 14 > TextBox 11": "地图优先",
            "Group 1 > Group 14 > TextBox 13": "分类图层分色呈现供需 Pin",
            "Group 1 > Group 20 > Oval 22": "5",
            "Group 1 > Group 20 > TextBox 23": "纯线下成交",
            "Group 1 > Group 20 > TextBox 24": "不做线上支付与平台抽成",
            "Group 1 > Group 15 > Oval 17": "6",
            "Group 1 > Group 15 > TextBox 18": "模板化提效",
            "Group 1 > Group 15 > TextBox 19": "3 秒发布，短路径低门槛",
            "Title 54": "差异化定位六要素",
        }},
        # ================= 章节 02 =================
        9: {"path": {
            "Title 4": "02.目标用户与画像",
            "Text Placeholder 24": "四层用户分层与三目标使用倾向",
        }},
        # Slide 10: 用户分层总览
        10: {"path": {
            "Group 2 > Rectangle 31": "四层用户分层总览",
            "Group 2 > Group 63 > Group 64 > TextBox 69": "本地居民 60%",
            "Group 2 > Group 63 > Group 64 > Rectangle 68": "借物拼车二手求助",
            "Group 2 > Group 70 > Group 72 > TextBox 74": "本地服务者 25%",
            "Group 2 > Group 70 > Group 72 > Rectangle 73": "家政维修就近接单",
            "Group 2 > Group 84 > Group 86 > TextBox 88": "商家与机构 15%",
            "Group 2 > Group 84 > Group 86 > Rectangle 87": "房东车商小店批量发布",
            "Title 92": "目标用户分层",
        }},
        # Slide 11: 核心用户画像
        11: {"path": {
            "Group 28 > Rectangle 2": "核心用户画像",
            "Group 28 > Rectangle 4": "三个画像覆盖需求方、供给方与 B 端",
            "Group 28 > Group 5 > Group 23 > Rectangle 24": "李明 · 需求方",
            "Group 28 > Group 5 > Group 23 > Rectangle 25": "就近、能找到、能联系上",
            "Group 28 > Group 6 > Group 16 > Rectangle 19": "王师傅 · 供给方",
            "Group 28 > Group 6 > Group 16 > Rectangle 20": "就近接单、不被抽成",
            "Group 28 > Group 7 > Group 10 > Rectangle 13": "张房东 · B 端",
            "Group 28 > Group 7 > Group 10 > Rectangle 14": "近、真实租客、直接联系",
            "Title 30": "核心用户画像",
        }},
        # Slide 12: 三目标使用倾向
        12: {"path": {
            "Group 1 > TextBox 25": "三目标使用倾向",
            "Group 1 > TextBox 24": "在角色分层之上引入交叉维度，用于 GTM 节奏与北极星分轴归因。",
            "Group 1 > TextBox 15": "地图发现型 40%",
            "Group 1 > TextBox 16": "看地图找 Pin，依赖图层筛选",
            "Group 1 > TextBox 11": "AI 匹配型 35%",
            "Group 1 > TextBox 12": "高频发需求找资源，依赖推送与智能匹配",
            "Title 27": "三目标使用倾向",
        }},
        # Slide 13: 角色与功能映射
        13: {"path": {
            "Group 7 > TextBox 29": "角色与功能映射",
            "Group 7 > Group 1 > Group 24 > TextBox 2": "C 端需求方",
            "Group 7 > Group 1 > Group 24 > TextBox 3": "首页地图、列表、详情、联系为主",
            "Group 7 > Group 1 > Group 22 > TextBox 9": "C 端资源方",
            "Group 7 > Group 1 > Group 22 > TextBox 10": "发布资源、我的发布、实名认证为主，详情曝光与收藏为辅。",
            "Group 7 > Group 1 > Group 23 > TextBox 15": "B 端资源方",
            "Group 7 > Group 1 > Group 23 > TextBox 16": "资质认证、批量发布、我的发布为主，详情展示资质标为辅。",
            "Title 31": "角色与功能映射",
        }},
        # ================= 章节 03 =================
        14: {"path": {
            "Title 4": "03.用户场景与需求优先级",
            "Text Placeholder 24": "十大核心场景与 P0 需求清单",
        }},
        # Slide 15: 基础五场景
        15: {"path": {
            "Group 1 > TextBox 27": "基础核心场景",
            "Group 1 > Group 43 > Rectangle 37": "01",
            "Group 1 > Group 43 > Rectangle 35": "就近借物与拼车",
            "Group 1 > Group 43 > Rectangle 36": "发需求 30 分钟内收到附近响应",
            "Group 1 > Group 44 > Rectangle 32": "02",
            "Group 1 > Group 44 > Rectangle 30": "二手就近自取",
            "Group 1 > Group 44 > Rectangle 31": "5km 内看到、联系、当面交易，省去快递环节",
            "Group 1 > Group 45 > Rectangle 42": "03",
            "Group 1 > Group 45 > Rectangle 40": "服务接单与招聘",
            "Group 1 > Group 45 > Rectangle 41": "资质认证后就近曝光，联系方式直接跳转",
            "Title 47": "基础核心场景",
        }},
        # Slide 16: 新增五场景
        16: {"path": {
            "Group 1 > TextBox 25": "AI 与地图新增场景",
            "Group 1 > TextBox 12": "五个新增场景把 AI 匹配、AI 发布、图层加载与分级管理串成闭环。",
            "Group 1 > Group 68 > Group 56 > Group 57 > Oval 64": "1",
            "Group 1 > Group 68 > Group 56 > Group 57 > TextBox 65": "AI 帮我发",
            "Group 1 > Group 68 > Group 56 > Group 57 > TextBox 66": "拍照加一句话，7 秒上架",
            "Group 1 > Group 68 > Group 56 > Group 58 > Oval 60": "2",
            "Group 1 > Group 68 > Group 56 > Group 58 > TextBox 61": "双向推送",
            "Group 1 > Group 68 > Group 56 > Group 58 > TextBox 62": "1 分钟内推给 Top30 匹配方",
            "Group 1 > Group 68 > Group 54 > Group 14 > Oval 4": "3",
            "Group 1 > Group 68 > Group 54 > Group 14 > TextBox 11": "图层快加载",
            "Group 1 > Group 68 > Group 54 > Group 14 > TextBox 13": "勾选三级分类，P95 ≤300ms 秒级筛选",
            "Group 1 > Group 68 > Group 54 > Group 20 > Oval 22": "4",
            "Group 1 > Group 68 > Group 54 > Group 20 > TextBox 23": "完整度升级",
            "Group 1 > Group 68 > Group 54 > Group 20 > TextBox 24": "三档自动判定并引导补全，绿档优先曝光",
            "Title 72": "AI 与地图新增场景",
        }},
        # Slide 17: P0 需求优先级
        17: {"path": {
            "Group 1 > Group 161 > Group 141 > Rectangle: Rounded Corners 143": "01",
            "Group 1 > Group 161 > Group 141 > Rectangle 144": "基础闭环需求",
            "Group 1 > Group 161 > Group 141 > Rectangle 145": "5km 发现、双向发布、联系跳转",
            "Group 1 > Group 160 > Group 152 > Rectangle: Rounded Corners 153": "02",
            "Group 1 > Group 160 > Group 152 > Rectangle 154": "AI 类需求",
            "Group 1 > Group 160 > Group 152 > Rectangle 155": "冷启动三阶段匹配、智能发布、推送",
            "Group 1 > Group 161 > Group 148 > Rectangle: Rounded Corners 149": "03",
            "Group 1 > Group 161 > Group 148 > Rectangle 150": "地图类需求",
            "Group 1 > Group 161 > Group 148 > Rectangle 151": "三级分类图层、差异化聚合阈值",
            "Group 1 > Group 160 > Group 156 > Rectangle: Rounded Corners 157": "04",
            "Group 1 > Group 160 > Group 156 > Rectangle 158": "分级治理需求",
            "Group 1 > Group 160 > Group 156 > Rectangle 159": "完整度三档、有效期与预审举报",
            "Title 234": "P0 需求优先级清单",
        }},
        # Slide 18: 明确不做
        18: {"path": {
            "Group 1 > Group 6 > Rectangle 9": "明确不做的需求",
            "Group 1 > Group 3 > TextBox 22": "不做线上交易",
            "Group 1 > Group 3 > Rectangle 23": "支付结算、订单、信誉评价均不做",
            "Group 1 > Group 4 > TextBox 17": "不追踪撮合结果",
            "Group 1 > Group 4 > Rectangle 18": "不做站内 IM，只埋一级联系漏斗",
            "Group 1 > Group 5 > TextBox 12": "不做全自动 AI",
            "Group 1 > Group 5 > Rectangle 13": "AI 预审加人工边界，不做全自动",
            "Title 25": "需求范围与排除项",
        }},
        # Slide 19: 分类聚合阈值
        19: {"path": {
            "Group 1 > Rectangle 21": "分类聚合阈值溯源",
            "Group 1 > Rectangle 22": "各类目按真实数据密度设定差异化阈值。",
            "Group 1 > Group 20 > Group 2 > TextBox 6": "01",
            "Group 1 > Group 20 > Group 2 > Rectangle 4": "工作类 3 条聚",
            "Group 1 > Group 20 > Group 2 > Rectangle 5": "招聘参照，3km 均值 12 条，高密度",
            "Group 1 > Group 20 > Group 8 > TextBox 12": "02",
            "Group 1 > Group 20 > Group 8 > Rectangle 10": "房屋类 5 条聚",
            "Group 1 > Group 20 > Group 8 > Rectangle 11": "房产参照，3km 均值 8 条，中密度",
            "Group 1 > Group 20 > Group 14 > TextBox 18": "03",
            "Group 1 > Group 20 > Group 14 > Rectangle 16": "生活类 8 条聚",
            "Group 1 > Group 20 > Group 14 > Rectangle 17": "二手参照，3km 均值 5 条，车服同档",
            "Title 24": "分类聚合阈值溯源",
        }},
        # ================= 章节 04 =================
        20: {"path": {
            "Title 4": "04.Go-to-Market 策略",
            "Text Placeholder 24": "单城试点与三批 GTM 节奏",
        }},
        # Slide 21: 试点选择
        21: {"path": {
            "Group 2 > TextBox 27": "单城试点策略",
            "Group 2 > TextBox 25": "先选一个一二线城市社区密集区做单城 5km 密度试点，跑通后再复制。",
            "Group 2 > Group 1 > TextBox 42": "试点城市选择",
            "Group 2 > Group 1 > TextBox 43": "选社区密集区，做单城 5km 供给密度试点。",
            "Group 2 > TextBox 47": "种子资源导入",
            "Group 2 > TextBox 48": "人工导入本地优质资源与需求，避免冷启动撮合空转。",
            "Group 2 > TextBox 55": "种子用户招募",
            "Group 2 > TextBox 56": "通过社区社群、物业合作与本地微信群定向邀请首批用户。",
            "Title 83": "单城试点与种子导入",
        }},
        # Slide 22: 三批 GTM 节奏
        22: {"path": {
            "Group 2 > Rectangle 31": "三批 GTM 节奏",
            "Group 2 > Group 63 > Group 64 > TextBox 69": "第一批 GTM",
            "Group 2 > Group 63 > Group 64 > Rectangle 68": "种子配方导入，未实名先发后审保供给",
            "Group 2 > Group 70 > Group 72 > TextBox 74": "第二批 GTM",
            "Group 2 > Group 70 > Group 72 > Rectangle 73": "双向推送钩子，样本达标后再开灰度",
            "Group 2 > Group 77 > Group 79 > TextBox 81": "第三批 GTM",
            "Group 2 > Group 77 > Group 79 > Rectangle 80": "AI 发布钩子，达标后扩量",
            "Group 2 > Group 84 > Group 86 > TextBox 88": "三目标联动",
            "Group 2 > Group 84 > Group 86 > Rectangle 87": "三目标 Tab 同屏，任选其一进入撮合",
            "Title 92": "三批 GTM 节奏",
        }},
        # Slide 23: 关键传播点
        23: {"path": {
            "Group 19 > TextBox 17": "关键传播点",
            "Group 19 > Rectangle 18": "以就近、双向、实名三个标签构成对外统一话术。",
            "Group 19 > Group 9 > TextBox 12": "01",
            "Group 19 > Group 9 > TextBox 10": "核心口号",
            "Group 19 > Group 9 > Rectangle 11": "用就近的资源解决本地的需求",
            "Group 19 > Group 13 > TextBox 16": "02",
            "Group 19 > Group 13 > TextBox 14": "传播钩子",
            "Group 19 > Group 13 > Rectangle 15": "你身边 5 公里，缺什么发什么",
            "Group 19 > Group 5 > TextBox 8": "03",
            "Group 19 > Group 5 > TextBox 6": "差异化标签",
            "Group 19 > Group 5 > Rectangle 7": "双向发布 / 5km / 实名",
            "Title 21": "关键传播点与话术",
        }},
        # ================= 章节 05 =================
        24: {"path": {
            "Title 4": "05.成功指标与关键假设",
            "Text Placeholder 24": "三乘积北极星与九条待验证假设",
        }},
        # Slide 25: 三乘积北极星
        25: {"path": {
            "Group 12 > Rectangle 1": "三乘积北极星",
            "Group 12 > TextBox 48": "三项指标相乘，基线 0.216 等权硬线，第 4 周依实测校准。",
            "Group 12 > Group 2 > Group 33 > TextBox 21": "AI 匹配召回率",
            "Group 12 > Group 2 > Group 33 > TextBox 22": "5 分钟内被推送方点击占比，同类目 ≥20 条",
            "Group 12 > Group 39 > Group 35 > TextBox 25": "图层加载成功率",
            "Group 12 > Group 39 > Group 35 > TextBox 26": "图层切换 P95 ≤300 毫秒，POC 通过后承诺",
            "Group 12 > Group 40 > Group 36 > TextBox 29": "完整发布率",
            "Group 12 > Group 40 > Group 36 > TextBox 30": "信息完整度判定为绿档的发布占比",
            "Title 50": "三乘积北极星指标",
        }},
        # Slide 26: 分层与分组指标
        26: {"path": {
            "Group 2 > Group 1 > TextBox 13": "01",
            "Group 2 > Group 1 > TextBox 14": "02",
            "Group 2 > Group 1 > TextBox 15": "03",
            "Group 2 > Group 1 > Group 20 > TextBox 17": "AI 匹配组",
            "Group 2 > Group 1 > Group 20 > TextBox 16": "灰度组点击率高于基线，不追踪撮合结果",
            "Group 2 > Group 1 > Group 24 > TextBox 26": "地图加载组",
            "Group 2 > Group 1 > Group 24 > TextBox 25": "P95 ≤300ms，以前置 POC 结论为准",
            "Group 2 > Group 1 > Group 21 > TextBox 23": "分级管理组",
            "Group 2 > Group 1 > Group 21 > TextBox 22": "绿档完整发布率与预审拦截准确率双达标",
            "Title 28": "三组关键指标",
        }},
        # Slide 27: 假设与反指标
        27: {"path": {
            "Group 8 > Group 1 > TextBox 27": "关键假设与反指标",
            "Group 8 > Group 1 > TextBox 9": "九条待验证假设配套四类反指标，持续监控风险信号。",
            "Group 8 > Rectangle: Rounded Corners 7": "01",
            "Group 8 > Group 6 > TextBox 4": "供给密度假设",
            "Group 8 > Group 6 > TextBox 5": "5km 内存在足够供需密度",
            "Group 8 > Rectangle: Rounded Corners 14": "02",
            "Group 8 > Group 10 > TextBox 12": "用户接受度假设",
            "Group 8 > Group 10 > TextBox 13": "接受模板发布，未实名可先发后审",
            "Group 8 > Rectangle: Rounded Corners 19": "03",
            "Group 8 > Group 15 > TextBox 17": "技术可行性假设",
            "Group 8 > Group 15 > TextBox 18": "小模型成本可控，聚合性能经 POC 实测达标",
            "Group 8 > Rectangle: Rounded Corners 24": "04",
            "Group 8 > Group 20 > TextBox 22": "反指标监控",
            "Group 8 > Group 20 > TextBox 23": "零联系率、跳失率、高风险内容占比均设阈值",
            "Title 29": "关键假设与反指标",
        }},
        # ================= 封底 =================
        28: {"path": {
            "Title 4": "Thank You",
            "Text Placeholder 3": "产品经理：刘杰",
            "Text Placeholder 6": "找鸭找 APP · MRD v2.1 评审版",
        }},
    }


def main():
    """主流程：读取模板 → 按映射表替换文字 → 输出到临时文件。"""
    template_path = r"d:\developer\code\aicoding\s2s\docs\模板\市场需求模板.pptx"
    output_path = r"d:\developer\code\aicoding\s2s\docs\找鸭找-市场需求文档-v2.1_tmp.pptx"

    prs = Presentation(template_path)
    content_map = build_content_map()
    print(f"slides={len(prs.slides)}")

    for si, slide in enumerate(prs.slides, 1):
        cfg = content_map.get(si)
        if not cfg:
            print(f"  Slide {si:2d}: skipped")
            continue
        path_map = cfg.get("path", {})
        text_map = cfg.get("text", {})
        replace_shapes(slide.shapes, path_map, text_map)
        print(f"  Slide {si:2d}: replaced (path={len(path_map)} text={len(text_map)})")

    prs.save(output_path)
    print(f"\nSaved: {output_path}")


if __name__ == "__main__":
    main()
