# -*- coding: utf-8 -*-
"""
clean_prd_versioning.py
一次性清理脚本：把 PRD.md 里所有「版本演进痕迹」剥离，使其成为纯粹的初始版本产品定义。

清理对象（4 类）：
1. 章节标题中的「（新增，对齐 Survivor xx）」「（保留 v2.0 §x.x，...）」等括注；
2. 「**修订前（v2.0 ...）**：...」整行删除，「**修订后（v2.1）xxx**：」改写为「**xxx**：」；
3. 行内版本差异标注，如「（原 v2.0 限 2 条）」「砍掉 v2.0 未实名 50 / 实名 200 双轨」「替代 v1 11 个算法群」；
4. 附录 B 砍留改对照表、附录 D 变更记录整段删除。

用法：python clean_prd_versioning.py
"""
import io
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

SRC = r"d:\developer\code\aicoding\s2s\docs\PRD.md"


def strip_heading_annotations(text):
    """
    清理章节标题尾部的版本演进括注。

    参数:
        text (str): PRD 全文
    返回:
        tuple[str, int]: (清理后全文, 命中次数)
    """
    # 匹配 ### / #### 标题行末尾的「（新增...）」「（保留 v2.0...）」「（v2.1 修订...）」「（替换...）」等括注
    pattern = re.compile(
        r"^(#{3,4} .*?)（(?:新增|保留 v2\.0|v2\.1 修订|替换|改为)[^）]*）\s*$",
        re.MULTILINE,
    )
    return pattern.subn(r"\1", text)


def strip_before_after_blocks(text):
    """
    删除「修订前」整行，并把「修订后（v2.1）xxx」还原为直述的规格标题。

    参数:
        text (str): PRD 全文
    返回:
        tuple[str, int]: (清理后全文, 命中次数)
    """
    total = 0
    # 1) 删除「**修订前（...）**：....」整行（含其后紧跟的空行）
    text, n = re.subn(r"^\*\*修订前（[^）]*）\*\*：.*\n\n?", "", text, flags=re.MULTILINE)
    total += n
    # 2) 「**修订后（v2.1）新增发布有效期管理（全文唯一口径）**：」→「**发布有效期管理（全文唯一口径）**：」
    text, n = re.subn(
        r"^\*\*修订后（v2\.1）(?:新增|替换为|改为|从 P2 升级为 P0 必修)?\s*",
        "**",
        text,
        flags=re.MULTILINE,
    )
    total += n
    return text, total


def strip_inline_diffs(text):
    """
    逐条替换行内的版本差异表述（显式枚举，避免正则误伤）。

    参数:
        text (str): PRD 全文
    返回:
        tuple[str, int]: (清理后全文, 命中次数)
    """
    pairs = [
        # §3 账号体系
        ("**不能发布**（原 v2.0 限 2 条改为 0 条）", "**不能发布**"),
        ("未实名用户不能发布（v2.1 校正为 0 条）", "未实名用户不能发布（0 条）"),
        (
            "不能发布（v2.1 校正为 0 条，原 v2.0 限 2 条作废）；引导",
            "不能发布（0 条）；引导",
        ),
        # §5 发布
        ("- **新增 T2 AI 智能发布四模式**（详见 §5.9）", "- **T2 AI 智能发布四模式**（详见 §5.9）"),
        ("**新增四模式发布**：", "**四模式发布**："),
        ("- 地图选点复用 v1 地图选择器（视觉升级 + 位置默认 5km 内）；", "- 地图选点提供地图选择器（位置默认 5km 内）；"),
        (
            "- **地图选点**：复用 v1 `map-selector`（见 `../prototype/index.html` 行 10523-10540），视觉升级为新色板；",
            "- **地图选点**：`map-selector` 组件，配色遵循 §1 视觉系统；",
        ),
        # §6 首页地图
        ("- 视觉升级（遵循 §1）；", "- 视觉规范遵循 §1；"),
        ("- 地图 Marker 按 §2 分类分色，并新增\"聚合/展开\"；", "- 地图 Marker 按 §2 分类分色，支持\"聚合/展开\"；"),
        ("- 新增\"范围滑块\"（1/3/5/10/全城）放在显眼位置；", "- \"范围滑块\"（1/3/5/10/全城）放在显眼位置；"),
        ("- 图例升级为\"颜色 + 资源/需求态 双重图例\"；", "- 图例为\"颜色 + 资源/需求态 双重图例\"；"),
        ("- 列表页新增二级筛选、资源/需求切换 Tab；", "- 列表页提供二级筛选、资源/需求切换 Tab；"),
        ("- **新增 T3 分类三级树图层弹层**（详见 §6.9）", "- **T3 分类三级树图层弹层**（详见 §6.9）"),
        ("- **新增 S2 动态蜂窝半径引擎**（详见 §6.11）；", "- **S2 动态蜂窝半径引擎**（详见 §6.11）；"),
        ("- **新增 T1 LR+GBDT 匹配实现逻辑**（详见 §6.12）；", "- **T1 LR+GBDT 匹配实现逻辑**（详见 §6.12）；"),
        ("- **新增 T6 三轴联动飞轮视觉交互规格**（详见 §6.13）；", "- **T6 三轴联动飞轮视觉交互规格**（详见 §6.13）；"),
        ("- **新增 S1 双向推送引擎规格**（详见 §6.14）；", "- **S1 双向推送引擎规格**（详见 §6.14）；"),
        ("- **新增分类差异化聚合阈值表**（详见 §6.15，含 D3 决策 evidence 溯源）。", "- **分类差异化聚合阈值表**（详见 §6.15，含 D3 决策 evidence 溯源）。"),
        (
            "- **地图 SDK**：高德地图 Web JS API 2.0（v1 已接入，保持，视觉升级 Marker 样式）；",
            "- **地图 SDK**：高德地图 Web JS API 2.0（Marker 样式按 §1 色板定制）；",
        ),
        (
            "- **轻量匹配（替代 v1 11 个算法群）**：v2.1 替换为 **T1 LR+GBDT 两阶段**，详见 §6.12；",
            "- **轻量匹配**：**T1 LR+GBDT 两阶段**，详见 §6.12；",
        ),
        ("**理由**：不阻塞 Batch1 排期，符合\"轻量无新增\"原则，研发资源聚焦核心功能。", "**理由**：不阻塞 Batch1 排期，研发资源聚焦核心功能。"),
        ("- 砍所有信誉星级发光", "- 不做信誉星级发光"),
        # §7 联系中转
        (
            "  - **统一防爬限频**：同一 IP 每日 ≤30 次（**不分层**，砍掉 v2.0 未实名 50 / 实名 200 双轨）；",
            "  - **统一防爬限频**：同一 IP 每日 ≤30 次（**不分层**，不按实名状态区分额度）；",
        ),
        ("- 前端图片渲染号码而非文本（可选升级方案）；", "- 前端图片渲染号码而非文本（可选增强）；"),
        (
            "明天再来\"（v2.1 S7 单轨：不分层） |",
            "明天再来\"（S7 单轨：不分层） |",
        ),
        ("- **反爬/反采集（v2.1 S7 单轨修订）**：", "- **反爬/反采集（S7 单轨）**："),
        # §8 我的
        ("#### 8.3.3 通知中心（替换 v1 通知中心屏幕 + 消息列表 + 聊天详情）", "#### 8.3.3 通知中心"),
        ("违规下架、版本升级）", "违规下架、版本更新）"),
        # §9 合规
        ("### 9.9 AI 预审 + 人工边界合规流程（保留 v2.0 §9.2，对齐 Survivor T4）", "### 9.9 AI 预审 + 人工边界合规流程"),
        # §10 页面清单「变更」列取值
        ("| 联系中转页（新增） | P0 | 新增（替代 IM） |", "| 联系中转页 | P0 | 电话 / 微信二选一单轨 |"),
        ("| 我的发布 | P0 | 新增独立（原含在 profile） |", "| 我的发布 | P0 | 独立页面 |"),
        ("| 信任与认证 | P0 | 新增（替代信誉详情） |", "| 信任与认证 | P0 | 实名 + 资质二层认证 |"),
        ("| 分类级联选择器 | P0 | 新增（替代原分类树） |", "| 分类级联选择器 | P0 | 三级分类级联 |"),
        ("| 地图选点 | P0 | 改（视觉升级） |", "| 地图选点 | P0 | 地图打点选位 |"),
        ("| 认证拦截浮层 | P0 | 新增 |", "| 认证拦截浮层 | P0 | 未实名发布拦截 |"),
        # 附录 A 术语表
        (
            "；v2.1 北极星已升级为三乘积（详见 §0.2） |",
            "；北极星为三乘积公式（详见 §0.2） |",
        ),
        ("| 三乘积北极星 | v2.1 北极星指标：", "| 三乘积北极星 | 北极星指标："),
        # 结尾
        (
            "**文档结束。本 PRD 与 BRD.md / MRD.md 共同构成 v2 完整产品定义基线。版本变更须经 PRD 评审并记录在案。**",
            "**文档结束。本 PRD 与 BRD.md / MRD.md 共同构成完整产品定义基线。后续变更须经 PRD 评审并记录在案。**",
        ),
    ]
    hit = 0
    for old, new in pairs:
        if old in text:
            text = text.replace(old, new)
            hit += 1
        else:
            print(f"  [WARN] 未命中: {old[:48]}")
    return text, hit


def strip_survivor_markers(text):
    """
    删除「📌 对齐 Survivor」溯源行与「⚠️ 风险」行（属 ideation 过程物，不属产品定义）。

    参数:
        text (str): PRD 全文
    返回:
        tuple[str, int]: (清理后全文, 命中次数)
    """
    total = 0
    text, n = re.subn(r"^> 📌 \*\*对齐 Survivor\*\*：.*\n", "", text, flags=re.MULTILINE)
    total += n
    text, n = re.subn(r"^> ⚠️ \*\*风险\*\*：.*\n", "", text, flags=re.MULTILINE)
    total += n
    # 清理因删除引用行而残留的孤立空引用块与三连空行
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text, total


def strip_appendix_b_and_d(text):
    """
    整段删除附录 B（砍留改对照表）与附录 D（变更记录），并修正附录序号引用。

    参数:
        text (str): PRD 全文
    返回:
        tuple[str, int]: (清理后全文, 删除段数)
    """
    removed = 0
    # 附录 B：从「## 附录 B：砍留改对照表」到下一个「## 附录」之前
    pat_b = re.compile(r"\n## 附录 B：砍留改对照表.*?(?=\n## 附录 )", re.DOTALL)
    text, n = pat_b.subn("", text)
    removed += n
    # 附录 D：从「## 附录 D」到文末「**文档结束」之前
    pat_d = re.compile(r"\n## 附录 D[^\n]*.*?(?=\n\*\*文档结束)", re.DOTALL)
    text, n = pat_d.subn("", text)
    removed += n
    return text, removed


def main():
    """主函数：按 5 类规则依次清理 PRD.md 的版本演进痕迹并回写。"""
    with io.open(SRC, encoding="utf-8") as f:
        text = f.read()
    before = len(text)

    text, n1 = strip_heading_annotations(text)
    print(f"[1] 标题括注清理: {n1} 处")
    text, n2 = strip_before_after_blocks(text)
    print(f"[2] 修订前/修订后块清理: {n2} 处")
    text, n3 = strip_inline_diffs(text)
    print(f"[3] 行内差异表述清理: {n3} 处")
    text, n4 = strip_survivor_markers(text)
    print(f"[4] Survivor 溯源行/风险行清理: {n4} 处")
    text, n5 = strip_appendix_b_and_d(text)
    print(f"[5] 附录 B/D 整段删除: {n5} 段")

    with io.open(SRC, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    print(f"[OK] {before} → {len(text)} 字符（减少 {before - len(text)}）")


if __name__ == "__main__":
    main()
