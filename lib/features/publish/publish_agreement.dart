/// 发布协议全文与展示入口（2026-11-01）。
///
/// **为什么单独成文件**：协议正文是纯文案，与发布表单的状态、校验、提交链路
/// 无关；塞进 `publish_screen.dart` 只会让那个已经很长的文件更难读。
///
/// **文案口径**：覆盖信息真实性、禁止内容、联系方式与隐私、平台角色与零佣金五类
/// 关键承诺，与 PRD 零佣金红线一致。属产品侧初版，正式对外前需法务复核。
library;

import 'package:flutter/material.dart';

/// 协议正文（按条拆分，渲染时逐段排版）。
///
/// 第一条固定为更新日期；其余每条以「一、」「二、」… 开头，
/// 便于用户逐条核对而不是面对一整块文字。
const List<String> kPublishAgreementParagraphs = <String>[
  '更新日期：2026 年 11 月 1 日',
  '一、信息真实性\n你发布的信息（分类、位置、标题、价格、描述、图片及分类专属字段）应真实、准确、'
      '完整，不得含有虚假、夸大或引人误解的内容。',
  '二、发布资格\n你应具备发布该信息所需的民事行为能力；涉及房屋、车辆、用工、服务等需要资质的'
      '事项，应确保已取得相应合法资质。',
  '三、禁止发布的内容\n不得发布下列内容：违反法律法规的信息；色情、赌博、毒品、枪支、迷药等'
      '违法信息；诈骗、传销、刷单、代开发票、办证等违法推广；侵犯他人隐私、名誉、著作权或其他'
      '合法权益的内容；辱骂、人身攻击等不文明内容。对上述内容，平台有权直接拦截、下架或删除。',
  '四、联系方式与隐私\n你填写的手机号仅用于其他用户与你取得联系。开启「查看联系方式需申请」后，'
      '其他用户须经你同意才能看到号码；关闭该开关则对方可直接取号。请勿在公开信息中填写他人手机号、'
      '身份证号等敏感个人信息。',
  '五、平台角色与交易风险\n本平台仅提供供需信息的展示与撮合，不参与你们的实际交易，不代收代付，'
      '不对交易结果作担保。线下见面与交易的风险由双方自行承担，请务必核验对方身份与物品、服务情况。',
  '六、零佣金\n本平台不向用户收取信息发布费、交易佣金或会员费，也不出售任何展示特权。',
  '七、内容管理与账号处理\n对违反本协议的信息，平台可采取拦截、下架、限制发布、封禁账号等措施，'
      '并保留追究法律责任的权利。',
  '八、协议变更\n本协议可能随产品与法规变化更新，更新后在发布页公示即生效；你继续发布即视为接受'
      '更新后的协议。',
];

/// 展示发布协议全文（底部可拖拽弹层）。
///
/// 参数：[context] 触发页面的上下文。
/// 返回：[Future<void>]，弹层关闭后完成。
Future<void> showPublishAgreement(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) {
      final textTheme = Theme.of(sheetContext).textTheme;
      return DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (context, controller) => SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '发布协议',
                        style: textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(sheetContext).pop(),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.separated(
                  controller: controller,
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                  itemCount: kPublishAgreementParagraphs.length,
                  separatorBuilder: (context, index) => const SizedBox(height: 14),
                  itemBuilder: (context, index) => Text(
                    kPublishAgreementParagraphs[index],
                    style: textTheme.bodyMedium?.copyWith(height: 1.6),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
