"""
PRD.md → docx 的源–派生一致性比对。

为什么需要它，而 verify_prd_docx.py 不够：
    verify_prd_docx.py 验的是「规格清单是否命中」—— 一份固定的关键词表。
    它管不了「PRD.md 改了但 docx 没重生」这件事：8/24 那次整章缺失，
    两个文件各自合法、闸门全绿、无任何工具报错，唯一检出手段是主动做
    源–派生比对。本脚本把那个手工动作固化下来。

设计要点（三次踩坑换来的）：
    md 侧比对前必须剥掉 ** 与 ` 标记。docx 提取出的是纯文本，标记已被消化，
    而 PRD.md 里大量硬约束写成「**24px** 下必须可辨」这种跨标记形式。
    不剥标记就会假 MISS —— 我在人工比对时连续三次栽在这上面：
      ① 「Figma Variables」根本不在 PRD 里（凭印象编的词）
      ② 「24px 下必须可辨」原文是「**24px** 下必须可辨」（跨 ** 边界）
      ③ 「44px 最小触控」原文是「按钮最小触控区 44×44 px」（措辞脑补）
    所以特征句一律先在 md 侧验明存在（报「脑补」），再查 docx（报 MISS）。
    双向确认能把「我记错了」与「docx 真缺内容」分开 —— 混为一谈时，
    假 MISS 会淹没真 MISS。

用法：python docs\verify_prd_docx_sync.py
"""
import re
import sys
from pathlib import Path

from docx import Document

BASE = Path(__file__).resolve().parent
MD = BASE / 'PRD.md'
DOCX = BASE / '找鸭找-产品需求文档-v2.1.docx'

# 特征句必须逐字从 PRD.md 复制（含 ** 与 ` 标记也无妨，比对前会剥掉）。
# 选句原则：覆盖 8/24 之后各轮改动的落点，且用具体标识符、路径名、
# 数值约束这类不易改写的内容 —— 泛泛的措辞会在正常改写时假报警。
FEATURES = [
    '受限态不是空白页',
    'duck-symbol-mini',
    '24px 下必须可辨',
    '眼点直径与喙颈开口最窄处均不得小于',
    '外圈环是可减部件',
    '下架（Opacity 50%',
    'com.s2s.zhaoyazhao.dev',
    'embed-map-bg.py',
    'logo-horizontal.svg',
    'map-bg.png',
    '按钮最小触控区 44×44 px',
]


def extract_docx_text(path):
    """
    提取 docx 全部可见文字，段落与表格单元格都收。

    只收段落会漏检：PRD 有 91 张表，大量硬约束（如尺寸档位阈值、验收清单）
    落在表格里，漏收表格等于放过一半内容。
    :param path: docx 文件路径
    :type path: Path
    :return: 段落与单元格文字拼成的全文
    :rtype: str
    """
    doc = Document(str(path))
    parts = [p.text for p in doc.paragraphs]
    for table in doc.tables:
        for row in table.rows:
            for cell in row.cells:
                parts.append(cell.text)
    return '\n'.join(parts)


def flatten_markdown(text):
    """
    剥掉 Markdown 强调与代码标记，使 md 侧文本可与 docx 纯文本直接比对。

    只剥 ** 与 ` 两种：它们最常出现在句子中间，会把连续语句切断。
    标题的 # 与列表的 - 位于行首，不影响句内特征匹配，无需处理。
    :param text: PRD.md 原文
    :type text: str
    :return: 剥除标记后的文本
    :rtype: str
    """
    return text.replace('**', '').replace('`', '')


def main():
    """
    执行比对并以退出码表明结果。

    退出码非 0 便于将来接入 CI 或 pre-commit；当前手工跑也能一眼看出成败。
    :return: 进程退出码，0 为全部对上
    :rtype: int
    """
    if not DOCX.exists():
        print('[FAIL] docx 不存在，请先跑 gen_prd_v2.1_docx.py 并改名')
        return 1

    md_flat = flatten_markdown(MD.read_text(encoding='utf-8'))
    docx_text = extract_docx_text(DOCX)

    # 时间序只作提示，不参与成败判定 —— mtime 对无关操作敏感：Git 检出、
    # 编辑器保存、脚本还原文件都会把 md 的 mtime 推到现在，内容一字未改也会
    # 显示「docx 早于 md」。若让它决定退出码，就又造出一条经常假红的判据
    # （本轮刚从 verify_prd_docx.py 删掉两个这样的裸词，不该在这里重犯）。
    # 内容是否真缺失，下面的逐句比对已能实证，那才是可靠判据。
    md_mtime = MD.stat().st_mtime
    docx_mtime = DOCX.stat().st_mtime
    order = ('docx 早于 md（可能是漏重生，也可能只是 md 被无关操作碰过 —— '
             '以下逐句比对为准）' if docx_mtime < md_mtime else 'docx 不早于 md')
    print('时间序：' + order)
    print('-' * 56)

    fabricated = []
    missing = []
    for feat in FEATURES:
        if feat not in md_flat:
            fabricated.append(feat)
            print('[脑补] 特征句不在 PRD.md：' + feat)
        elif feat not in docx_text:
            missing.append(feat)
            print('[MISS] PRD.md 有、docx 无：' + feat)
        else:
            print('[OK  ] ' + feat)

    print('-' * 56)
    md_sections = len(re.findall(r'^## ', MD.read_text(encoding='utf-8'), re.M))
    print('一级章节 ' + str(md_sections) + ' 个 · docx 提取 ' + str(len(docx_text)) + ' 字符')

    if fabricated:
        # 脑补与 MISS 分开报：前者是本脚本自身的清单有误（要改 FEATURES），
        # 后者是 docx 真缺内容（要重生）。混报会让人拿错处置方式
        print('[FAIL] ' + str(len(fabricated)) + ' 条特征句在 PRD.md 中不存在 —— '
              '请修正本脚本 FEATURES（须逐字复制原文），而不是去改 PRD')
    if missing:
        print('[FAIL] ' + str(len(missing)) + ' 条内容 PRD.md 有而 docx 无 —— '
              '请重跑 gen_prd_v2.1_docx.py 并改名落盘')
    if not fabricated and not missing:
        print('[PASS] 源–派生一致')
        return 0
    return 1


if __name__ == '__main__':
    sys.exit(main())
