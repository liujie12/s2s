"""按本轮实际改写的文案原句，逐条核对两份 PPTX 是否真的已落盘。

功能：提取 pptx 全文，检索本轮 14 处硬编码改动对应的特征串，
      打印每条的命中状态，用于确认交付件而非仅 MD 已更新。
参数：无
返回：无返回值，结果打印到 stdout
"""
from pptx import Presentation

# 本轮 BRD.pptx 改动的特征串（取改写后文案的稳定片段）
BRD_EXPECT = [
    "首版拍定基线",
    "同类目 ≥20 条计分母",
    "图层切换 P95 ≤300ms",
    "首批前置 1 天聚合性能 POC",
    "受限态转正",
    "第 4 周校准值",
    "运营治理后台 7 页",
    "冷启动三阶段",
    "一级联系漏斗",
    "前置聚合性能 POC",
    "Flutter 客户端",
    "高德原生 SDK",
    "审计留痕",
]
# 本轮 MRD.pptx 改动的特征串
MRD_EXPECT = [
    "九条待验证假设",
    "冷启动三阶段匹配",
    "不追踪撮合结果",
    "只埋一级联系漏斗",
    "未实名先发后审",
    "样本达标后再开灰度",
    "基线 0.216 等权硬线",
    "同类目 ≥20 条",
    "POC 通过后承诺",
    "灰度组点击率高于基线",
    "以前置 POC 结论为准",
    "聚合性能经 POC 实测达标",
    "高风险内容占比",
]


def pptx_text(path):
    """提取 pptx 全文（递归展开 Group）。

    参数：path —— pptx 文件路径
    返回：str，全文
    """
    prs = Presentation(path)
    parts = []

    def walk(shapes):
        """递归收集形状文本。"""
        for shp in shapes:
            if shp.shape_type is not None and str(shp.shape_type).startswith("GROUP"):
                walk(shp.shapes)
                continue
            if shp.has_text_frame:
                parts.append(shp.text_frame.text)

    for slide in prs.slides:
        walk(slide.shapes)
    return "\n".join(parts)


def check(path, expect):
    """核对单个 pptx 的特征串命中情况。

    参数：path 文件路径；expect 期望出现的特征串列表
    返回：无
    """
    text = pptx_text(path)
    miss = [w for w in expect if w not in text]
    print(f"== {path}")
    print(f"   命中 {len(expect) - len(miss)}/{len(expect)}")
    print(f"   缺失 = {miss}")


def main():
    """主流程。"""
    check("找鸭找-商业需求文档-v2.1.pptx", BRD_EXPECT)
    check("找鸭找-市场需求文档-v2.1.pptx", MRD_EXPECT)


if __name__ == "__main__":
    main()
