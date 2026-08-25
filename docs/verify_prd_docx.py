# -*- coding: utf-8 -*-
"""
verify_prd_docx.py
验证 找鸭找-产品需求文档-v2.1.docx 内容完整性。
"""
from docx import Document
import os
import sys

# Windows 终端默认 GBK，无法输出 emoji（如 🟢），强制切 UTF-8 避免 UnicodeEncodeError
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

doc_path = r"d:\developer\code\aicoding\s2s\docs\找鸭找-产品需求文档-v2.1.docx"
size = os.path.getsize(doc_path)
print(f"[OK] 文件大小: {size} 字节 ({size/1024:.1f} KB)")

doc = Document(doc_path)
text = "\n".join(p.text for p in doc.paragraphs)
for t in doc.tables:
    for row in t.rows:
        for c in row.cells:
            text += "\n" + c.text

print(f"[OK] 段落数: {len(doc.paragraphs)}")
print(f"[OK] 表格数: {len(doc.tables)}")
print(f"[OK] 总字符数: {len(text)}")
print()
print("=" * 60)
print("核心规格关键词验证:")
print("=" * 60)

keywords = [
    # 核心指标与算法
    "三乘积", "0.216", "D5.1", "LR+GBDT", "分类三级树",
    "T2", "T3", "T4", "T6",
    "S1", "S2", "S4", "S6", "S7",
    # 决策兜底
    "D1", "D2", "D3",
    # 蜂窝 + 性能
    "蜂窝", "P95", "红清单", "严格 Scope",
    # 关键章节
    "未实名", "资质", "完整度三档", "LR+GBDT",
    "永久单轨", "双向推送", "运营治理后台",
    "三轴联动", "动态蜂窝", "智能发布",
    "Batch1", "冷启动", "灰度",
]

for k in keywords:
    cnt = text.count(k)
    status = "OK " if cnt > 0 else "MISS"
    print(f"  [{status}] {k}: {cnt} 次")

print()
print("=" * 60)
print("Scope 红线反向验证（以下关键词必须为 0 次或仅在澄清语境）:")
print("=" * 60)
forbidden = ["QS 分", "金牌", "银牌", "铜牌", "确认码", "撮合完成率", "最大 365 天"]
for k in forbidden:
    cnt = text.count(k)
    status = "OK  " if cnt == 0 else "FAIL"
    print(f"  [{status}] {k}: {cnt} 次（期望 0）")

print()
print("=" * 60)
print("统一口径正向验证:")
print("=" * 60)
expected = ["首次联系触发率", "实名+🟢", "默认 7 天", "14 天未刷新", "完整度档 40%", "联系点击×5"]
for k in expected:
    cnt = text.count(k)
    status = "OK  " if cnt > 0 else "MISS"
    print(f"  [{status}] {k}: {cnt} 次")

print()
print("=" * 60)
print("一级章节验证:")
print("=" * 60)
h1_chapters = [
    "0. 产品总览",
    "1. 视觉设计系统",
    "2. 多级分类体系",
    "3. 注册",
    "4. 实名认证",
    "5. 发布页",
    "6. 首页",
    "7. 详情页",
    "8. 我的发布",
    "9. 设置与合规模块",
    "10. 信息架构",
    "11. 功能模块验收清单",
]
for h in h1_chapters:
    cnt = text.count(h)
    status = "OK " if cnt > 0 else "MISS"
    print(f"  [{status}] {h}: {cnt} 次")

print()
print("=" * 60)
print("版本演进痕迹反向验证（初始版本文档，以下必须为 0 次）:")
print("=" * 60)
# 用户明确要求：本文档为初始版本，不得出现任何「新增/替换/修订」等版本演进叙述
version_traces = [
    "修订前", "修订后", "变更记录", "砍留改", "v2.0", "附录 D",
    "ideation", "对齐 Survivor", "替代 v1", "v1 原型", "原 v2.0", "v2.1 修订",
    # 差异叙述残留词 + 占位符
    "替代", "替换", "原信誉", "N/A", "TBD", "TODO",
]
for k in version_traces:
    cnt = text.count(k)
    status = "OK  " if cnt == 0 else "FAIL"
    print(f"  [{status}] {k}: {cnt} 次（期望 0）")
