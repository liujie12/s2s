/// AI 结果确认页（PRD §5.9 结果待确认态，页面 ID：ai-confirm-screen）。
///
/// **本页是强制环节**：§5.9「AI 返回四件套后 → 强制进入确认页」。它存在的
/// 唯一理由是不让模型的猜测直接入库 —— 每一项都要经用户过目。
///
/// **五种状态全部做出来（§5.9 表五行）**：解析中（骨架屏 + 5 秒后改文案）/
/// 解析失败（两个出路，已填内容保留）/ 结果待确认（逐字段 + 「AI 猜」角标）/
/// 用户拒绝（全部重填，不计配额）/ 部分字段无法猜出（标「需你补充」）。
/// 前两态在本期没有真实触发源（无服务端），但**做出来才能验收文案与版式**，
/// 且接入后这两态是最常见的 —— 留到接入时再写，等于把最容易出错的两态
/// 放在最赶的时候写。
///
/// **本轮降级（写明以免误认为已实现）**：
/// - **没有真实模型**：猜测由 `ai_guess_builder.dart` 在本地按 §5.10 的
///   scope 规则从用户已填内容与模板定义产出，不含任何推理；
/// - **配额不扣减**：§5.9「仅本页点确认发布才计 1 次」的计数必须在服务端
///   （客户端计数清缓存即归零）。本页只按 §5.10 展示当前档位对应的**上限**；
/// - **「取当前定位门牌」拿不到真值**：依赖高德 Key，按钮保留但禁用，
///   门牌号走手填框（§9.8 兜底列允许手填并视为达成）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design_tokens.dart';
import '../../domain/ai_guess.dart';
import '../../domain/category_tree.dart';
import '../../domain/listing_detail.dart';
import '../../domain/publish_completeness.dart';
import '../../router/app_router.dart';
import '../auth/auth_repository.dart';
import 'ai_guess_builder.dart';
import 'publish_form_state.dart';

/// AI 结果确认页。
///
/// 参数 [form] 从发布页带过来的表单快照 —— 猜测的 scope 就是它（§5.10 Step 2）。
class AiConfirmScreen extends ConsumerStatefulWidget {
  const AiConfirmScreen({super.key, required this.form});

  final PublishFormState form;

  @override
  ConsumerState<AiConfirmScreen> createState() => _AiConfirmScreenState();
}

class _AiConfirmScreenState extends ConsumerState<AiConfirmScreen> {
  /// 当前表单（冲刺区补的门牌号与三级类目会改它）。
  late PublishFormState _form = widget.form;

  /// 当前解析状态。初值为 ready —— 本地生成没有等待过程。
  ///
  /// 解析中/失败两态可由页内「重试」与调试入口切到，用于验收；
  /// 接入服务端后初值应改为 `parsing`。
  AiParseStatus _status = AiParseStatus.ready;

  final TextEditingController _doorCtrl = TextEditingController();

  /// 用户已手改过的字段值，key 同 [FieldGuess.fieldKey]。
  ///
  /// **为什么不直接改 `_form`**：§5.9「用户可逐项改」改的是**猜测结果**，
  /// 而猜测结果与表单不是一一对应（标题猜测含自动前缀、价格猜测含单位）。
  /// 把用户的修改写回表单要做反向解析，解析失败就会静默丢改动。
  final Map<String, String> _edited = {};

  @override
  void initState() {
    super.initState();
    _doorCtrl.text = _form.doorNumber;
  }

  @override
  void dispose() {
    _doorCtrl.dispose();
    super.dispose();
  }

  /// 当前猜测结果（含用户手改的覆盖值）。
  AiGuessResult get _result {
    final base = buildLocalGuess(_form);
    if (_edited.isEmpty) return base;
    return AiGuessResult(
      status: base.status,
      guesses: [
        for (final g in base.guesses)
          if (_edited.containsKey(g.fieldKey))
            FieldGuess(
              fieldKey: g.fieldKey,
              label: g.label,
              value: _edited[g.fieldKey],
              // 用户亲手改的，来源当然是用户输入（§5.10 的 U 集合）
              source: GuessSource.userInput,
            )
          else
            g,
      ],
    );
  }

  /// 「全部重填」（§5.9「清空 AI 猜测值，回到手动模板表单，不消耗当日 AI 配额」）。
  void _resetAll() {
    // 直接返回发布页，且不带任何结果 —— 表单在发布页仍是原样，
    // 这正是 §5.9「回到手动模板表单」的含义：不是清空用户填的东西，
    // 是放弃 AI 这条路。
    GoRouter.of(context).pop();
  }

  /// 逐项修改（§5.9「用户可逐项改」）。
  Future<void> _editField(FieldGuess guess) async {
    // 分类走级联选择器 —— 一个文本框改不了三级树
    if (guess.fieldKey == 'category') {
      final leafId = await GoRouter.of(context).push<int>(
        AppRoutes.categorySelector,
        extra: _form.leafCategoryId,
      );
      if (leafId == null || !mounted) return;
      setState(() {
        _form = _form.withCategory(leafId);
        // 换分类等于换模板，旧模板字段的手改值不再适用（同 withCategory 的理由）
        _edited.clear();
      });
      return;
    }

    // 用 TextFormField 而非自建 TextEditingController：手动建的控制器要在
    // 对话框关闭后 dispose，而关闭有一段退场动画 —— 动画期间输入框仍在树上，
    // 提前 dispose 会抛「marked as dirty and is still active」（widget 测试实测抓出）。
    // TextFormField 自己持有并在正确时机释放控制器。
    var input = guess.isGuessed ? guess.value! : '';
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('修改${guess.label}'),
        content: TextFormField(
          initialValue: input,
          autofocus: true,
          decoration: InputDecoration(hintText: '请输入${guess.label}'),
          onChanged: (v) => input = v,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(input.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (value == null || !mounted) return;
    setState(() {
      if (value.isEmpty) {
        // 改成空 = 撤回这次修改，回到 AI 原猜测值。
        // 若存空串会得到「有值但是空」这种既不是猜出也不是未猜出的第三态。
        _edited.remove(guess.fieldKey);
      } else {
        _edited[guess.fieldKey] = value;
      }
    });
  }

  /// 确认发布（§5.9「点确认发布后进入 publish-success-screen」，此处计 1 次配额）。
  void _confirm() {
    // TODO(接后端 §12.3 POST /posts + §5.9 配额计数)：配额扣减必须在服务端。
    GoRouter.of(context).push(AppRoutes.publishSuccess, extra: _form);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(AppColors.background),
      appBar: AppBar(
        toolbarHeight: 48,
        backgroundColor: const Color(AppColors.surface),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back,
            color: Color(AppColors.textPrimary),
          ),
          onPressed: () => GoRouter.of(context).pop(),
        ),
        title: Text(
          '确认信息',
          style: TextStyle(
            fontSize: AppTypeScale.h3.size,
            fontWeight: FontWeight.w600,
            color: const Color(AppColors.textPrimary),
          ),
        ),
        actions: [
          // §5.9「全部重填」。放在右上而非底部：它是放弃动作，
          // 与底部「确认发布」拉开距离，避免误触把已核对的结果清掉。
          TextButton(
            onPressed: _status == AiParseStatus.ready ? _resetAll : null,
            child: Text(
              '全部重填',
              style: TextStyle(
                fontSize: AppTypeScale.body.size,
                color: const Color(AppColors.textSecondary),
              ),
            ),
          ),
        ],
      ),
      body: switch (_status) {
        AiParseStatus.parsing => const _ParsingView(),
        AiParseStatus.failed => _FailedView(
          onRetry: () => setState(() => _status = AiParseStatus.ready),
          onManual: () => GoRouter.of(context).pop(),
        ),
        AiParseStatus.ready => _buildReady(),
      },
      bottomNavigationBar: _status == AiParseStatus.ready
          ? _ConfirmBar(
              assessment: _form.completeness,
              allFilled: _result.allFilled,
              onConfirm: _confirm,
            )
          : null,
    );
  }

  Widget _buildReady() {
    final result = _result;
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        Text(
          'AI 已识别，请核对',
          style: TextStyle(
            fontSize: AppTypeScale.h2.size,
            fontWeight: FontWeight.w600,
            color: const Color(AppColors.textPrimary),
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          '每项都可以改，改完再发',
          style: TextStyle(
            fontSize: AppTypeScale.small.size,
            color: const Color(AppColors.textSecondary),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        for (final guess in result.guesses) ...[
          _GuessRow(guess: guess, onTap: () => _editField(guess)),
          const SizedBox(height: AppSpacing.sm),
        ],
        const SizedBox(height: AppSpacing.sm),
        _GreenSprint(
          assessment: _form.completeness,
          doorController: _doorCtrl,
          onDoorChanged: (v) => setState(() {
            _form = _form.copyWith(doorNumber: v);
          }),
          onPickCategory: () => _editField(
            const FieldGuess(fieldKey: 'category', label: '分类'),
          ),
          categoryPath: _form.leafCategoryId == null
              ? null
              : categoryPathLabel(_form.leafCategoryId!),
        ),
        const SizedBox(height: AppSpacing.md),
        _QuotaNote(
          verified: ref.watch(isLoggedInProvider),
          level: _form.completeness.level,
          sensitive: _form.requiredCert != RequiredCert.none,
        ),
      ],
    );
  }
}

/// 解析中态（§5.9「骨架屏 + 正在识别…，超过 5 秒显示『稍等，马上好』」）。
class _ParsingView extends StatefulWidget {
  const _ParsingView();

  @override
  State<_ParsingView> createState() => _ParsingViewState();
}

class _ParsingViewState extends State<_ParsingView> {
  /// 是否已过 5 秒（§5.9 的 [kParsingSlowSeconds]）。
  bool _slow = false;

  @override
  void initState() {
    super.initState();
    // 用 Future.delayed 而非 Timer：本页只需一次性切换文案，
    // 不需要可取消的定时器语义。
    Future<void>.delayed(const Duration(seconds: kParsingSlowSeconds), () {
      if (mounted) setState(() => _slow = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(color: Color(AppColors.primary)),
          const SizedBox(height: AppSpacing.lg),
          Text(
            _slow ? '稍等，马上好' : '正在识别…',
            style: TextStyle(
              fontSize: AppTypeScale.body.size,
              color: const Color(AppColors.textSecondary),
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          TextButton(
            onPressed: () => GoRouter.of(context).pop(),
            child: const Text(
              '取消，手动填',
              style: TextStyle(color: Color(AppColors.primary)),
            ),
          ),
        ],
      ),
    );
  }
}

/// 解析失败态（§5.9「两个按钮『重试』『改为手动填写』，已输入内容全部保留」）。
class _FailedView extends StatelessWidget {
  const _FailedView({required this.onRetry, required this.onManual});

  final VoidCallback onRetry;
  final VoidCallback onManual;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.error_outline,
              size: 48,
              color: Color(AppColors.errorText),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              '识别没成功，可以重试或手动填',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppTypeScale.body.size,
                color: const Color(AppColors.textPrimary),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '你已填的内容都还在',
              style: TextStyle(
                fontSize: AppTypeScale.small.size,
                color: const Color(AppColors.textSecondary),
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton(onPressed: onRetry, child: const Text('重试')),
                const SizedBox(width: AppSpacing.md),
                TextButton(
                  onPressed: onManual,
                  child: const Text('改为手动填写'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 一行猜测结果（§5.9「逐字段展示 AI 猜测值 +『AI 猜』角标」）。
class _GuessRow extends StatelessWidget {
  const _GuessRow({required this.guess, required this.onTap});

  final FieldGuess guess;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final guessed = guess.isGuessed;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: const Color(AppColors.surface),
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: const Color(AppColors.border)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    guess.label,
                    style: TextStyle(
                      fontSize: AppTypeScale.caption.size,
                      color: const Color(AppColors.textSecondary),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    guess.displayText,
                    style: TextStyle(
                      fontSize: AppTypeScale.body.size,
                      color: Color(
                        guessed
                            ? AppColors.textPrimary
                            : AppColors.errorText,
                      ),
                    ),
                  ),
                  // 来源说明（§5.10 Step 4「每个实体都能找到源头」的用户可见化）。
                  // 不说来源的「AI 猜」角标，用户只能凭感觉决定改不改。
                  if (guessed && guess.source != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      guess.source!.label,
                      style: TextStyle(
                        fontSize: AppTypeScale.caption.size,
                        color: const Color(AppColors.textPlaceholder),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (guessed)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.xs,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: const Color(AppColors.accent),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Text(
                  'AI 猜',
                  style: TextStyle(
                    fontSize: AppTypeScale.caption.size,
                    color: Colors.white,
                  ),
                ),
              )
            else
              Text(
                '去填 ›',
                style: TextStyle(
                  fontSize: AppTypeScale.small.size,
                  color: const Color(AppColors.primary),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 「再花 5 秒升完整」冲刺区（§5.9「确认页默认带 🟢 冲刺项」）。
///
/// §5.9 明确「只放 🟢 档差的两项 —— 门牌号与三级类目」。不放必填项：
/// 必填没齐的话「确认发布」本就是禁用的，那不叫冲刺，叫拦截。
class _GreenSprint extends StatelessWidget {
  const _GreenSprint({
    required this.assessment,
    required this.doorController,
    required this.onDoorChanged,
    required this.onPickCategory,
    required this.categoryPath,
  });

  final CompletenessAssessment assessment;
  final TextEditingController doorController;
  final ValueChanged<String> onDoorChanged;
  final VoidCallback onPickCategory;
  final String? categoryPath;

  @override
  Widget build(BuildContext context) {
    // 已达最高档就不显示冲刺区 —— 一个写着「再花 5 秒升完整」却已经完整的
    // 区块，会让用户以为自己没达标。
    if (assessment.isTop) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: const Color(AppColors.primaryLight),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.bolt_outlined,
                size: 18,
                color: Color(AppColors.primaryDark),
              ),
              const SizedBox(width: AppSpacing.xs),
              Text(
                '再花 5 秒升「${CompletenessLevel.green.label}」',
                style: TextStyle(
                  fontSize: AppTypeScale.h3.size,
                  fontWeight: FontWeight.w600,
                  color: const Color(AppColors.primaryDark),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '附近人 2 倍概率看到',
            style: TextStyle(
              fontSize: AppTypeScale.small.size,
              color: const Color(AppColors.primaryDark),
            ),
          ),
          const SizedBox(height: AppSpacing.md),

          // 冲刺项一：门牌号
          if (!assessment.hasDoorNumber) ...[
            Text(
              CompletenessCondition.doorNumber.gapLabel,
              style: TextStyle(
                fontSize: AppTypeScale.small.size,
                fontWeight: FontWeight.w600,
                color: const Color(AppColors.primaryDark),
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: doorController,
                    onChanged: onDoorChanged,
                    decoration: InputDecoration(
                      hintText: '如 3 号楼 2 单元 501',
                      hintStyle: const TextStyle(
                        color: Color(AppColors.textPlaceholder),
                      ),
                      filled: true,
                      fillColor: const Color(AppColors.surface),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.md,
                        vertical: AppSpacing.sm,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppRadius.md),
                        borderSide: const BorderSide(
                          color: Color(AppColors.border),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                // §5.9「门牌号给『取当前定位门牌』快捷按钮」。
                // 依赖高德 Key，保留但禁用 —— 隐藏会让验收看不出这里
                // 本该有个快捷方式（与发布页「地图选点」同一处置）。
                Tooltip(
                  message: '待接入高德定位',
                  child: OutlinedButton(
                    onPressed: null,
                    child: Text(
                      '取当前定位门牌',
                      style: TextStyle(fontSize: AppTypeScale.caption.size),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
          ],

          // 冲刺项二：三级类目
          if (!assessment.leafCategoryPrecise) ...[
            Text(
              CompletenessCondition.leafCategory.gapLabel,
              style: TextStyle(
                fontSize: AppTypeScale.small.size,
                fontWeight: FontWeight.w600,
                color: const Color(AppColors.primaryDark),
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            OutlinedButton(
              onPressed: onPickCategory,
              child: Text(
                categoryPath ?? '选择三级类目',
                style: TextStyle(fontSize: AppTypeScale.small.size),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 配额说明（§5.10「AI 配额二维分层」）。
///
/// **只展示上限不展示剩余**：剩余次数的计数在服务端（§5.9 仅确认发布才计 1 次），
/// 客户端显示一个自己算的剩余数，清一次缓存就会「恢复满额」，那比不显示更坏。
class _QuotaNote extends StatelessWidget {
  const _QuotaNote({
    required this.verified,
    required this.level,
    required this.sensitive,
  });

  final bool verified;
  final CompletenessLevel level;
  final bool sensitive;

  @override
  Widget build(BuildContext context) {
    final quota = dailyAiQuota(
      verified: verified,
      level: level,
      sensitiveCategory: sensitive,
    );
    return Row(
      children: [
        const Icon(
          Icons.info_outline,
          size: 14,
          color: Color(AppColors.textPlaceholder),
        ),
        const SizedBox(width: AppSpacing.xs),
        Expanded(
          child: Text(
            '你当前每日 AI 额度 $quota 次'
            '（${verified ? '已实名' : '未实名'} · ${level.label}'
            '${sensitive ? ' · 高敏类目 +10' : ''}）',
            style: TextStyle(
              fontSize: AppTypeScale.caption.size,
              color: const Color(AppColors.textPlaceholder),
            ),
          ),
        ),
      ],
    );
  }
}

/// 底部确认栏。
class _ConfirmBar extends StatelessWidget {
  const _ConfirmBar({
    required this.assessment,
    required this.allFilled,
    required this.onConfirm,
  });

  final CompletenessAssessment assessment;

  /// 是否所有字段都有值（§5.9「必填项未补齐时『确认发布』保持禁用」）。
  final bool allFilled;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final level = assessment.level;
    final (dot, textColor) = switch (level) {
      CompletenessLevel.green => (AppColors.success, AppColors.successText),
      CompletenessLevel.yellow => (AppColors.warning, AppColors.warningText),
      CompletenessLevel.red => (AppColors.error, AppColors.errorText),
    };

    return Container(
      color: const Color(AppColors.surface),
      padding: EdgeInsets.only(
        left: AppSpacing.lg,
        right: AppSpacing.lg,
        top: AppSpacing.md,
        bottom: AppSpacing.md + MediaQuery.of(context).padding.bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // §5.9「达标即改角标：两项补齐 + 必填 100% 时角标实时从 🟡 跳 🟢」。
          // 放在按钮上方：用户补完门牌号的下一眼就该看到档位变了，
          // 否则「再花 5 秒」这句承诺没有可见的兑现。
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: Color(dot),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              Text(
                '当前完整度：${level.label}',
                style: TextStyle(
                  fontSize: AppTypeScale.caption.size,
                  fontWeight: FontWeight.w600,
                  color: Color(textColor),
                ),
              ),
              const Spacer(),
              if (level == CompletenessLevel.green)
                Text(
                  '附近人 2 倍概率看到',
                  style: TextStyle(
                    fontSize: AppTypeScale.caption.size,
                    color: const Color(AppColors.successText),
                  ),
                )
              else
                Text(
                  '还差 ${assessment.missing.length} 项升'
                  '${CompletenessLevel.green.label}',
                  style: TextStyle(
                    fontSize: AppTypeScale.caption.size,
                    color: const Color(AppColors.textSecondary),
                  ),
                ),
            ],
          ),
          if (!allFilled) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              '还有字段标着「需你补充」，补完才能发布',
              style: TextStyle(
                fontSize: AppTypeScale.caption.size,
                color: const Color(AppColors.warningText),
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          SizedBox(
            height: 48,
            child: ElevatedButton(
              onPressed: allFilled ? onConfirm : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(AppColors.primary),
                foregroundColor: Colors.white,
                disabledBackgroundColor: const Color(AppColors.border),
                disabledForegroundColor: const Color(AppColors.textPlaceholder),
                elevation: 0,
                shape: const StadiumBorder(),
              ),
              child: Text(
                '确认发布',
                style: TextStyle(
                  fontSize: AppTypeScale.body.size,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
