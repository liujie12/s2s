"""生成 找鸭找-商业需求文档-v2.1.pptx —— 基于 a2c9499b 模板改造。

功能：读取模板 pptx，按 probe_out.txt 的 Group 路径逐个替换全部 23 张幻灯片
      的文字为 BRD v2.1 真实内容，保留模板视觉设计。
      映射值支持两种形式：
        1. 字符串        —— 仅替换文字，保留原字号
        2. (文字, 字号)  —— 替换文字并强制指定字号（用于长文本防溢出）
参数：无（路径写死在 main 中）
返回：无返回值，结果写入 找鸭找-商业需求文档-v2.1.pptx
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

    # 保留第一个 run 的样式，清空全部文字
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
        # 原段落没有 run（极少见），新建一个
        from pptx.oxml.ns import qn
        r_elem = first_para._p.makeelement(qn("a:r"), {})
        t_elem = r_elem.makeelement(qn("a:t"), {})
        t_elem.text = new_text
        r_elem.append(t_elem)
        first_para._p.append(r_elem)


def replace_text(shapes, path_map, current_path=""):
    """递归遍历形状（含 Group），按 path_map 中的完整路径替换文字。

    参数：
        shapes: 形状集合（slide.shapes 或 group.shapes）
        path_map: 映射字典，key=完整路径，value=新文字或 (新文字, 字号)
        current_path: 当前路径前缀，递归时拼接
    返回：无（原地修改）
    """
    for shp in shapes:
        cur = f"{current_path} > {shp.name}" if current_path else shp.name
        is_group = shp.shape_type is not None and str(shp.shape_type).startswith("GROUP")
        if is_group:
            replace_text(shp.shapes, path_map, cur)
            continue
        if shp.has_text_frame and cur in path_map:
            apply_text(shp, path_map[cur])


def build_content_map():
    """构建 23 张幻灯片的内容映射表。

    说明：
        - 严格对齐模板原有的「短标题（16/24pt）+ 长正文（12pt）」布局，
          避免长文本塞进小标题框导致文字重叠；
        - 全文为产品初始版本视角，不含任何历史版本对比表述。
    返回：dict，key=幻灯片序号（1 起），value=路径到文字的映射
    """
    return {
        # ---- Slide 1: 封面 ----
        1: {
            "Title 4": "找鸭找 APP",
            "Subtitle 8": "商业需求文档（BRD）v2.1 评审版",
            "Text Placeholder 3": "产品经理：刘杰",
            "Text Placeholder 6": "2026-08-19",
        },
        # ---- Slide 2: 目录 ----
        2: {
            "Group 1 > Group 22 > TextBox 24": "Agenda",
            "Group 1 > Group 26 > Rectangle 43": "01",
            "Group 1 > Group 26 > Group 42 > Rectangle 44": "产品定义与目标用户",
            "Group 1 > Group 26 > Group 42 > Rectangle 45": "5km 生活圈双向供需信息撮合",
            "Group 1 > Group 27 > Rectangle 39": "02",
            "Group 1 > Group 27 > Group 38 > Rectangle 40": "市场机会与产品定位",
            "Group 1 > Group 27 > Group 38 > Rectangle 41": "空白地带与核心价值主张",
            "Group 1 > Group 28 > Rectangle 35": "03",
            "Group 1 > Group 28 > Group 34 > Rectangle 36": "竞品与差异化",
            "Group 1 > Group 28 > Group 34 > Rectangle 37": "错位竞争与商业护城河",
            "Group 1 > Group 29 > Rectangle 31": "04",
            "Group 1 > Group 29 > Group 30 > Rectangle 32": "北极星与成功指标",
            "Group 1 > Group 29 > Group 30 > Rectangle 33": "三乘积等权硬线 0.216",
            "Group 1 > Group 46 > Rectangle 48": "05",
            "Group 1 > Group 46 > Group 47 > Rectangle 49": "滚动 MVP 路线图",
            "Group 1 > Group 46 > Group 47 > Rectangle 50": "三批交付与风险应对",
        },
        # ---- Slide 3: 章节页 01 ----
        3: {
            "Title 4": "01.产品定义与目标用户",
            "Text Placeholder 8": "5km 生活圈双向供需信息撮合",
        },
        # ---- Slide 4: 产品核心定义 ----
        4: {
            "Group 1 > TextBox 13": "产品核心定义",
            "Group 1 > Rectangle 14": "聚焦 5 公里生活圈的双向供需撮合 APP，就近解决本地需求。",
            "Group 1 > Group 15 > TextBox 17": "5km 生活圈",
            "Group 1 > Group 15 > Rectangle 16": "默认 5 公里可调，把「近」做成第一差异化。",
            "Group 1 > Group 27 > TextBox 25": "双向供需",
            "Group 1 > Group 27 > Rectangle 24": "资源与需求同池双向发布，互为猎手。",
            "Group 1 > Group 28 > TextBox 23": "纯信息撮合",
            "Group 1 > Group 28 > Rectangle 22": "线下成交，不做支付结算与履约。",
            "Title 30": "产品核心定义",
        },
        # ---- Slide 5: 目标用户分层 ----
        5: {
            "Rectangle 4": "目标用户分层",
            "TextBox 5": "四类用户构成 5km 生活圈的供需两端",
            "Group 20 > Rectangle: Rounded Corners 1": "01",
            "Group 21 > Rectangle: Rounded Corners 10": "02",
            "Group 22 > Rectangle: Rounded Corners 11": "03",
            "Group 2 > Rectangle 12": "本地居民 60%",
            "Group 2 > Rectangle 13": "25-45 岁社区居住人群，核心诉求为借物、拼车、二手与找帮手。",
            "Group 18 > Rectangle 14": "本地服务者 25%",
            "Group 18 > Rectangle 15": "家政、维修、教学、咨询个体，诉求为接本地订单、就近服务。",
            "Group 19 > Rectangle 16": "小微商家 10%",
            "Group 19 > Rectangle 17": "房东、二手车、招聘小店，诉求为本地信息发布与精准曝光。",
            "Title 24": "目标用户与场景",
        },
        # ---- Slide 6: AI 三色清单 ----
        6: {
            "Group 3 > Group 137 > Rectangle 139": "AI 能力三色清单",
            "Group 3 > Group 137 > Rectangle 138": "按落地节奏把 AI 能力拆为绿黄红三档，为研发提供明确入场券。",
            # 01 绿清单
            "Group 3 > Group 1 > Group 152 > TextBox 151": "01",
            "Group 3 > Group 1 > Group 152 > Group 112 > Group 113 > Rectangle 115": "绿清单｜立刻做",
            "Group 3 > Group 1 > Group 152 > Group 112 > Group 113 > Rectangle 116": "冷启动三阶段匹配、3B 发布辅助、信息健康分、查询加权。",
            # 02 黄清单
            "Group 3 > Group 1 > Group 26 > TextBox 28": "02",
            "Group 3 > Group 1 > Group 26 > Group 27 > Group 29 > Rectangle 31": "黄清单｜待验证",
            "Group 3 > Group 1 > Group 26 > Group 27 > Group 29 > Rectangle 32": "端侧离线 3B、多智能体代撮合、街景 Pin 视频，验证后再进。",
            # 03 红清单
            "Group 3 > Group 1 > Group 153 > TextBox 155": "03",
            "Group 3 > Group 1 > Group 153 > Group 154 > Group 156 > Rectangle 158": "红清单｜不做",
            "Group 3 > Group 1 > Group 153 > Group 154 > Group 156 > Rectangle 159": "重型算法群、70B 端到端 LLM、交易担保、AI 平台担责。",
            "Title 161": "AI 能力边界",
        },
        # ---- Slide 7: 章节页 02 ----
        7: {
            "Title 4": "02.市场机会与产品定位",
            "Text Placeholder 8": "空白地带与核心价值主张",
        },
        # ---- Slide 8: 市场机会与痛点 ----
        8: {
            "Group 3 > Rectangle 34": "市场机会判断",
            "Group 3 > Rectangle 33": "市场机会 = 5km 生活圈 × 双向供需 × 轻信任，三者交叉处仍是空白。",
            # 01
            "Group 3 > Group 2 > Group 1 > Group 152 > TextBox 151": "01",
            "Group 3 > Group 2 > Group 1 > Group 152 > Group 112 > Group 113 > Rectangle 115": "资源方痛点",
            "Group 3 > Group 2 > Group 1 > Group 152 > Group 112 > Group 113 > Rectangle 116": "发布成本高、曝光范围不可控、难以直接找到需求方。",
            # 02
            "Group 3 > Group 2 > Group 1 > Group 26 > TextBox 28": "02",
            "Group 3 > Group 2 > Group 1 > Group 26 > Group 27 > Group 29 > Rectangle 31": "需求方痛点",
            "Group 3 > Group 2 > Group 1 > Group 26 > Group 27 > Group 29 > Rectangle 32": "找就近资源难、信息真伪难辨、响应即时性差。",
            # 03
            "Group 3 > Group 2 > Group 1 > Group 153 > TextBox 155": "03",
            "Group 3 > Group 2 > Group 1 > Group 153 > Group 154 > Group 156 > Rectangle 158": "双向用户痛点",
            "Group 3 > Group 2 > Group 1 > Group 153 > Group 154 > Group 156 > Rectangle 159": "同时是资源方与需求方，被迫在多个平台之间反复切换。",
            "Title 161": "市场机会与用户痛点",
        },
        # ---- Slide 9: 核心价值主张 ----
        9: {
            "Group 4 > Rectangle 1": "核心价值主张",
            "Group 4 > Rectangle 2": "五条价值主张构成产品的差异化竞争力，其中双向撮合是单一核心差异点。",
            "Group 4 > Group 3 > Group 16 > TextBox 19": "01",
            "Group 4 > Group 3 > Group 16 > Rectangle 17": "近场优先",
            "Group 4 > Group 3 > Group 16 > Rectangle 18": "默认 5km，可调 1/3/5/10/全城",
            "Group 4 > Group 3 > Group 20 > TextBox 23": "02",
            "Group 4 > Group 3 > Group 20 > Rectangle 21": "双向撮合",
            "Group 4 > Group 3 > Group 20 > Rectangle 22": "既能发资源也能发需求，互为猎手",
            "Group 4 > Group 3 > Group 24 > TextBox 27": "03",
            "Group 4 > Group 3 > Group 24 > Rectangle 25": "极简丝滑",
            "Group 4 > Group 3 > Group 24 > Rectangle 26": "3 秒发布、一指发现、模板化提效",
            "Group 4 > Group 3 > Group 28 > TextBox 31": "04",
            "Group 4 > Group 3 > Group 28 > Rectangle 29": "本地实名",
            "Group 4 > Group 3 > Group 28 > Rectangle 30": "实名 + 资质认证，本地可验证",
            "Group 4 > Group 3 > Group 32 > TextBox 35": "05",
            "Group 4 > Group 3 > Group 32 > Rectangle 33": "纯线下成交",
            "Group 4 > Group 3 > Group 32 > Rectangle 34": "避开金融合规与履约纠纷成本",
            "Title 37": "核心价值主张",
        },
        # ---- Slide 10: 产品边界 ----
        10: {
            "Group 3 > Rectangle 8": "产品边界",
            "Group 3 > Rectangle 10": "明确不做高成本路径，把有限资源集中投入信息撮合深度。",
            "Group 3 > Group 22 > Group 15 > Rectangle 4": "01",
            "Group 3 > Group 22 > Group 15 > TextBox 2": "不做支付结算",
            "Group 3 > Group 22 > Group 15 > TextBox 7": "合规与履约成本高，不在本期焦点。",
            "Group 3 > Group 23 > Group 25 > Rectangle 26": "02",
            "Group 3 > Group 23 > Group 25 > TextBox 35": "不做站内 IM",
            "Group 3 > Group 23 > Group 25 > TextBox 36": "改为联系方式跳转，降低运营成本。",
            "Group 3 > Group 37 > Group 39 > Rectangle 40": "03",
            "Group 3 > Group 37 > Group 39 > TextBox 41": "不售卖信任资产",
            "Group 3 > Group 37 > Group 39 > TextBox 42": "完整度角标与实名徽章不可商业化。",
            "Title 44": "产品边界与合规红线",
        },
        # ---- Slide 11: 章节页 03 ----
        11: {
            "Title 4": "03.竞品与差异化",
            "Text Placeholder 8": "错位竞争与商业护城河",
        },
        # ---- Slide 12: 竞品矩阵 ----
        12: {
            "Group 1 > Group 193 > TextBox 194": "竞品格局",
            "Group 1 > Group 193 > Rectangle 195": "邻里社区偏社交、撮合弱；58 到家为纯 B 端供给，不支持双向发布。",
            "Group 1 > Group 192 > Group 191 > Group 188 > TextBox 167": "58 同城",
            "Group 1 > Group 192 > Group 191 > Group 188 > Rectangle 166": "全城分类信息，信息密度高但地图弱、真伪难辨。",
            "Group 1 > Group 190 > Group 189 > Group 187 > TextBox 173": "闲鱼",
            "Group 1 > Group 190 > Group 189 > Group 187 > Rectangle 172": "二手交易导向，本地属性弱，不支持需求发布。",
            "Title 197": "竞品分析矩阵",
        },
        # ---- Slide 13: 差异化小结 ----
        13: {
            "Group 5 > TextBox 3": "差异化定位",
            "Group 5 > TextBox 4": "在全城平台与邻里社区之间，找到 5km 双向供需撮合的专属生态位。",
            "Group 5 > TextBox 8": "vs 全城平台",
            "Group 5 > TextBox 9": "聚焦 5km + 双向 + 实名，避开全城信息淹没。",
            "Group 5 > TextBox 10": "vs 二手与社区",
            "Group 5 > TextBox 11": "近场自取与服务为主，需求可发布，专业撮合。",
            "Title 22": "差异化小结",
        },
        # ---- Slide 14: 商业护城河 ----
        14: {
            "Group 1 > Group 22 > Rectangle 23": "商业护城河",
            "Group 1 > Group 22 > Rectangle 24": "本期暂不变现，聚焦产品验证与用户增长，按顺序构建三层壁垒。",
            "Group 1 > Group 29 > Group 26 > Group 3 > Rectangle 7": "01",
            "Group 1 > Group 29 > Group 26 > Group 3 > Rectangle 5": "就近供给密度",
            "Group 1 > Group 29 > Group 26 > Group 3 > Rectangle 6": "先做深 5km，再做广城市。",
            "Group 1 > Group 29 > Group 27 > Group 10 > Rectangle 14": "02",
            "Group 1 > Group 29 > Group 27 > Group 10 > Rectangle 12": "双向数据沉淀",
            "Group 1 > Group 29 > Group 27 > Group 10 > Rectangle 13": "资源与需求双向数据飞轮。",
            "Group 1 > Group 29 > Group 28 > Group 17 > Rectangle 21": "03",
            "Group 1 > Group 29 > Group 28 > Group 17 > Rectangle 19": "本地信任资产",
            "Group 1 > Group 29 > Group 28 > Group 17 > Rectangle 20": "实名与资质认证数据积累。",
            "Title 31": "商业模式与护城河",
        },
        # ---- Slide 15: 章节页 04 ----
        15: {
            "Title 4": "04.北极星与成功指标",
            "Text Placeholder 8": "三乘积等权硬线 0.216",
        },
        # ---- Slide 16: 三乘积北极星 ----
        16: {
            "Group 1 > TextBox 6": "三乘积北极星",
            "Group 1 > TextBox 7": "北极星 = AI 匹配召回率 × 分类图层加载成功率 × 完整发布率，等权相乘 0.6×0.6×0.6 = 0.216，任一轴为 0 则整体为 0；该值为首版拍定基线，第 4 周依实测校准。",
            "Group 1 > Group 3 > TextBox 27": "AI 匹配召回率",
            "Group 1 > Group 3 > Rectangle 26": "5min 内被推送方点击占比，同类目 ≥20 条计分母。",
            "Group 1 > Group 8 > TextBox 22": "图层加载成功率",
            "Group 1 > Group 8 > Rectangle 21": "图层切换 P95 ≤300ms，POC 通过后承诺，基线 ≥0.6。",
            "Group 1 > Group 10 > TextBox 17": "完整发布率",
            "Group 1 > Group 10 > Rectangle 16": "信息完整度达绿档的发布占比，基线 ≥0.6。",
            "Title 29": "三乘积北极星指标",
        },
        # ---- Slide 17: 关键决策兜底 ----
        17: {
            "Group 3 > Group 137 > Rectangle 139": "关键决策与兜底",
            "Group 3 > Group 137 > Rectangle 138": "三项关键决策为北极星落地提供保障，避免指标空转与排期阻塞。",
            "Group 3 > Group 1 > Group 152 > TextBox 151": "01",
            "Group 3 > Group 1 > Group 152 > Group 112 > Group 113 > Rectangle 115": "等权硬线",
            "Group 3 > Group 1 > Group 152 > Group 112 > Group 113 > Rectangle 116": "首批设为冷启动观察期不考核，第二批起正式纳入 KPI。",
            "Group 3 > Group 1 > Group 26 > TextBox 28": "02",
            "Group 3 > Group 1 > Group 26 > Group 27 > Group 29 > Rectangle 31": "性能兜底",
            "Group 3 > Group 1 > Group 26 > Group 27 > Group 29 > Rectangle 32": "首批前置 1 天聚合性能 POC，通过后承诺 SLA，配降级开关。",
            "Group 3 > Group 1 > Group 153 > TextBox 155": "03",
            "Group 3 > Group 1 > Group 153 > Group 154 > Group 156 > Rectangle 158": "聚合阈值",
            "Group 3 > Group 1 > Group 153 > Group 154 > Group 156 > Rectangle 159": "工作 3 条、房屋 5 条、生活 8 条，车辆服务参照生活类。",
            "Title 161": "关键决策与兜底机制",
        },
        # ---- Slide 18: 成功标准 ----
        18: {
            "Group 7 > TextBox 9": "本期成功标准",
            "Group 7 > Rectangle 8": "BRD/MRD/PRD 三件套齐备且逻辑自洽，信息撮合闭环完整定义、无交易断点。",
            "Group 18 > Group 17 > Rectangle 16": "近场体验",
            "Group 18 > Group 17 > Rectangle: Rounded Corners 11": "5km 差异化在地图、列表、发布三处均落地。",
            "Group 19 > Group 21 > Rectangle 23": "双向闭环",
            "Group 19 > Group 21 > Rectangle: Rounded Corners 22": "双向发布机制在资源与需求两态均可闭环。",
            "Group 24 > Group 26 > Rectangle 28": "体验与信任",
            "Group 24 > Group 26 > Rectangle: Rounded Corners 27": "视觉设计系统建立规范，实名认证与受限态转正流程定义清晰。",
            "Group 29 > Group 31 > Rectangle 33": "北极星达标",
            "Group 29 > Group 31 > Rectangle: Rounded Corners 32": "三乘积北极星 ≥0.216，三轴均 ≥0.6，以第 4 周校准值验收。",
            "Title 35": "成功标准与验收",
        },
        # ---- Slide 19: 章节页 05 ----
        19: {
            "Title 4": "05.滚动 MVP 路线图",
            "Text Placeholder 8": "三批交付与风险应对",
        },
        # ---- Slide 20: 三批滚动 MVP ----
        20: {
            "Group 1 > Group 2 > Rectangle 20": "滚动 MVP 路线图",
            "Group 1 > Group 2 > TextBox 19": "按绝对日期锚点分批交付，9/30 交内测包，11/25 商店上架。",
            "Group 1 > Group 4 > Group 16 > TextBox 17": "第一批｜08/24-09/30",
            "Group 1 > Group 4 > Group 16 > Rectangle 18": "五大 P0 闭环、地图分类图层、完整度分级、聚合 POC，交付内测包。",
            "Group 1 > Group 5 > Group 12 > TextBox 13": "合规窗口｜10/01-11/25",
            "Group 1 > Group 5 > Group 12 > Rectangle 14": "运营治理后台 7 页、公安备案、安全评估，软著下证后提审上架。",
            "Group 1 > Group 6 > Group 8 > TextBox 9": "后续批次｜11/26 起",
            "Group 1 > Group 6 > Group 8 > Rectangle 10": "匹配三阶段与双向推送、AI 发布、动态蜂窝，2027/04 联动。",
            "Title 22": "滚动 MVP 路线图",
        },
        # ---- Slide 21: 风险与应对 ----
        21: {
            "Rectangle 21": "关键风险与应对",
            "TextBox 22": "供给密度、性能退化、评审阻塞三类高优风险均已配置明确应对方案。",
            "Group 1 > TextBox 17": "01",
            "Group 1 > TextBox 15": "供给密度不足",
            "Group 1 > Rectangle 16": "冷启动 18 条种子供给踩阈值 + 双向灰度开关。",
            "Group 3 > TextBox 14": "02",
            "Group 3 > TextBox 12": "地图性能退化",
            "Group 3 > Rectangle 13": "前置聚合性能 POC + 埋点告警 + 性能降级开关。",
            "Group 4 > TextBox 20": "03",
            "Group 4 > TextBox 18": "AI 清单未过评审",
            "Group 4 > Rectangle 19": "三色清单附录 + 前置验收 + 决策评审强制流程。",
            "Title 32": "风险与应对",
        },
        # ---- Slide 22: 资源与依赖 ----
        22: {
            "Group 23 > TextBox 1": "资源与依赖",
            "Group 23 > TextBox 2": "首批为单人加 AI 辅助，理想配置在获得资源后逐步补齐。",
            "Group 23 > Group 3 > Group 5 > TextBox 6": "01",
            "Group 23 > Group 3 > Group 5 > Rectangle 7": "核心团队",
            "Group 23 > Group 3 > Group 5 > Rectangle 8": "产品、设计、Flutter 客户端、后端、算法",
            "Group 23 > Group 9 > Group 11 > TextBox 12": "02",
            "Group 23 > Group 9 > Group 11 > Rectangle 13": "外部依赖",
            "Group 23 > Group 9 > Group 11 > Rectangle 14": "高德原生 SDK、实名认证、内容审核",
            "Group 23 > Group 15 > Group 17 > TextBox 18": "03",
            "Group 23 > Group 15 > Group 17 > Rectangle 19": "合规要点",
            "Group 23 > Group 15 > Group 17 > Rectangle 20": "软著 60 工作日、ICP 与 APP 备案、企业主体",
            "Title 25": "资源与依赖",
        },
        # ---- Slide 23: 封底 ----
        23: {
            "Title 4": "Thank You",
            "Text Placeholder 3": "产品经理：刘杰",
            "Text Placeholder 6": "找鸭找 APP · BRD v2.1 评审版",
        },
    }


def main():
    """主流程：读取模板 → 按映射表替换文字 → 输出到交付件路径。"""
    template_path = (
        r"d:\developer\code\aicoding\s2s\docs\模板"
        r"\a2c9499b-b91f-4fbc-7c4e-3a1b385f0921.pptx"
    )
    output_path = r"d:\developer\code\aicoding\s2s\docs\找鸭找-商业需求文档-v2.1_tmp.pptx"

    prs = Presentation(template_path)
    content_map = build_content_map()
    print(f"slides={len(prs.slides)}")

    for si, slide in enumerate(prs.slides, 1):
        if si in content_map:
            replace_text(slide.shapes, content_map[si])
            print(f"  Slide {si:2d}: replaced ({len(content_map[si])} texts)")
        else:
            print(f"  Slide {si:2d}: skipped")

    prs.save(output_path)
    print(f"\nSaved: {output_path}")


if __name__ == "__main__":
    main()
