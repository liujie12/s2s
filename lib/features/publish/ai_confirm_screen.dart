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
/// **B2-4 接真（2026-10-14）**：
/// - **猜测来自服务端**：进页面即调 `POST /ai/publish/parse`，四件套猜测由服务端
///   §5.10 严格 Scope 四步管线（3B 小模型）产出，本页只负责展示与逐项修改；
///   `ai_guess_builder.dart` 的本地规则降为离线兜底（本页主路径不再使用）；
/// - **配额计数在服务端**：真实配额快照随解析一并下发，本页展示「已用 / 上限」，
///   不自行计数（§5.9「仅本页点确认发布才计 1 次」）；
/// - **确认即真发布**：`precheck` 闸门 → `createPost`（载荷带 `ai_assisted: true`）；
/// - **「取当前定位门牌」拿不到真值**：依赖高德 Key，按钮保留但禁用，
///   门牌号走手填框（§9.8 兜底列允许手填并视为达成）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_exception.dart';
import '../../design_tokens.dart';
import '../../domain/ai_guess.dart';
import '../../domain/category_tree.dart';
import '../../domain/listing_detail.dart';
import '../../domain/publish_completeness.dart';
import '../../router/app_router.dart';
import '../ai/ai_dto.dart';
import '../ai/ai_repository.dart';
import '../auth/auth_repository.dart';
import '../post/post_repository.dart';
import 'ai_confirm_args.dart';
import 'publish_form_state.dart';

/// AI 结果确认页。
///
/// 参数 [args] 从发布页/入口弹层带过来的入参（表单快照 + 模式①一句话 +
/// 图片媒体 ID + 是否抢发）—— 猜测的 scope 就是其中的表单（§5.10 Step 2）。
class AiConfirmScreen extends ConsumerStatefulWidget {
  const AiConfirmScreen({super.key, this.args = const AiConfirmArgs()});

  final AiConfirmArgs args;

  @override
  ConsumerState<AiConfirmScreen> createState() => _AiConfirmScreenState();
}

class _AiConfirmScreenState extends ConsumerState<AiConfirmScreen> {
  /// 当前表单（冲刺区补的门牌号与三级类目会改它）。
  late PublishFormState _form = widget.args.form;

  /// 当前解析状态。初值 parsing —— 进入本页即真实调用服务端解析（B2-4 接真）。
  AiParseStatus _status = AiParseStatus.parsing;

  final TextEditingController _doorCtrl = TextEditingController();

  /// 「说一句」输入框（模式① 的文本输入；B2-4）。
  final TextEditingController _sentenceCtrl = TextEditingController();

  /// 服务端返回的逐字段猜测（Step 4 已校验；未猜出者为 null）。
  List<FieldGuess> _guesses = const [];

  /// 服务端返回的配额快照（可空）。
  AiQuotaDto? _quota;

  /// 发布中标志（防重入）。
  bool _publishing = false;

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
    _runParse();
  }

  @override
  void dispose() {
    _doorCtrl.dispose();
    _sentenceCtrl.dispose();
    super.dispose();
  }

  /// 初始「一句话」文本（模式① 原文优先，其次标题，最后描述）。
  ///
  /// 仅作 `_runParse` 的**回退文本**：用户没在「说一句」里输入时，用入口带进来的
  /// 一句话 / 表单已有标题去解析。不预填进输入框 —— 那会让同一句话出现两次。
  ///
  /// 返回：[String] 回退文本（可空串）。
  String _initialSentence() {
    final incoming = widget.args.initialText?.trim() ?? '';
    if (incoming.isNotEmpty) return incoming;
    if (_form.title.trim().isNotEmpty) return _form.title.trim();
    return _form.description.trim();
  }

  /// 解析用的图片媒体 ID（模式①④ 已上传图；发布页入口为空）。
  ///
  /// 返回：[String?] 媒体 ID。
  String? _mediaIdForParse() {
    final incoming = widget.args.initialMediaId;
    if (incoming != null && incoming.isNotEmpty) return incoming;
    return _form.mediaIds.isEmpty ? null : _form.mediaIds.first;
  }

  /// 调用服务端解析（`POST /ai/publish/parse`），并落到 [FieldGuess] 列表。
  ///
  /// 解析文本优先取「说一句」输入，为空则回退 [_initialSentence]。
  /// 失败（含 42901 配额耗尽 / 50301 不可用 / 传输错误）一律进 `failed` 态，
  /// 保留用户已输入内容（§5.9「已输入内容全部保留」）。
  Future<void> _runParse() async {
    setState(() => _status = AiParseStatus.parsing);
    final typed = _sentenceCtrl.text.trim();
    final text = typed.isEmpty ? _initialSentence() : typed;
    try {
      final result = await ref.read(aiRepositoryProvider).parse(
            AiParseRequestDto(
              mediaId: _mediaIdForParse(),
              voiceMediaId: widget.args.initialVoiceMediaId,
              text: text.isEmpty ? null : text,
              // 契约 PostTypeEnum 是 resource/demand（≠ 本地 PublishKind.name 的
              // supply/demand），故按 postDraftPayload 同一映射转一次。
              kind: _form.kind == PublishKind.supply ? 'resource' : 'demand',
              leafCategoryId: _form.leafCategoryId,
              completenessLevel: _completenessCode(),
            ),
          );
      if (!mounted) return;
      setState(() {
        _guesses = _toFieldGuesses(result);
        _quota = result.quota;
        _status = AiParseStatus.ready;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _status = AiParseStatus.failed);
    }
  }

  /// 当前草稿完整度档 → 契约码（0=🔴 / 1=🟡 / 2=🟢）。
  ///
  /// 返回：[int] 契约 completeness_level。
  int _completenessCode() {
    return switch (_form.completeness.level) {
      CompletenessLevel.green => 2,
      CompletenessLevel.yellow => 1,
      CompletenessLevel.red => 0,
    };
  }

  /// 服务端解析结果 → 确认页逐字段猜测（含来源与未猜出者）。
  ///
  /// 参数：[result] 服务端返回（Step 4 已剔除越界字段）。
  /// 返回：[List<FieldGuess>] 展示用猜测列表（分类/标题/价格/模板字段）。
  List<FieldGuess> _toFieldGuesses(AiParseResultDto result) {
    final guess = result.guess;
    final verified = result.scopeVerified;
    GuessSource? sourceOf(String key) => switch (verified[key]) {
          'user_input' => GuessSource.userInput,
          'neighbor_mode' => GuessSource.neighborMode,
          'platform' => GuessSource.template,
          _ => null,
        };
    final fields = <FieldGuess>[];

    // 分类：仅当服务端回传 leaf_category_id（Step 4 已校验等于已选叶子）时展示面包屑。
    final leafId = guess.leafCategoryId;
    fields.add(FieldGuess(
      fieldKey: 'category',
      label: '分类',
      value: leafId == null ? null : categoryPathLabel(leafId),
      source: leafId == null ? null : (sourceOf('leaf_category_id') ?? GuessSource.template),
    ));

    fields.add(FieldGuess(
      fieldKey: 'title',
      label: '标题',
      value: guess.title,
      source: guess.title == null ? null : (sourceOf('title') ?? GuessSource.userInput),
    ));

    final price = guess.price;
    fields.add(FieldGuess(
      fieldKey: 'price',
      label: '价格',
      value: price == null
          ? null
          : '${_trimNumber(price)}${guess.priceUnit == null ? '' : ' ${guess.priceUnit}'}',
      source: price == null ? null : (sourceOf('price') ?? GuessSource.userInput),
    ));

    final templateValues = guess.templateValues;
    if (templateValues != null) {
      for (final entry in templateValues.entries) {
        fields.add(FieldGuess(
          fieldKey: entry.key,
          label: entry.key,
          value: entry.value?.toString(),
          source: sourceOf(entry.key) ?? GuessSource.template,
        ));
      }
    }
    return fields;
  }

  /// 数值去掉无意义的小数尾巴（50.0 → 50）。
  ///
  /// 参数：[value] 数值。
  /// 返回：[String] 展示文案。
  String _trimNumber(double value) {
    return value == value.roundToDouble()
        ? value.toInt().toString()
        : value.toString();
  }

  /// 当前猜测结果（含用户手改的覆盖值）。
  AiGuessResult get _result {
    final base = AiGuessResult(status: _status, guesses: _guesses);
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

  /// 确认发布（§5.9「点确认发布后进入 publish-success-screen」）。
  ///
  /// 真发布链路：先 `precheck` 闸门 → `createPost`（载荷显式追加 `ai_assisted: true`）。
  /// **配额扣减与内容标识落库都在服务端**（§5.9），客户端不自行计数。
  /// 被闸门拦下或业务报错时以 SnackBar 提示并留在本页（用户可继续改）。
  ///
  /// 返回：[Future] 完成信号（发布成功已 push 成功页）。
  Future<void> _confirm() async {
    if (_publishing) return;
    setState(() => _publishing = true);
    final payload = <String, Object?>{
      ..._form.postDraftPayload(),
      // B2-4：AI 辅助标记（服务端据此扣配额 + 落内容标识）。
      'ai_assisted': true,
    };
    try {
      final repo = ref.read(postRepositoryProvider);
      final precheck = await repo.precheck(payload);
      if (!mounted) return;
      if (!precheck.passed) {
        _toast(
          precheck.blocks.isEmpty ? '暂不满足发布条件' : precheck.blocks.first.message,
        );
        return;
      }
      await repo.createPost(payload);
      if (!mounted) return;
      GoRouter.of(context).push(AppRoutes.publishSuccess, extra: _form);
    } on ApiException catch (error) {
      if (mounted) _toast(error.uiMessage);
    } finally {
      if (mounted) setState(() => _publishing = false);
    }
  }

  /// 轻量提示（SnackBar，用于闸门阻断与业务错误）。
  ///
  /// 参数：[message] 提示文案。
  /// 返回：[void]。
  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
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
          onRetry: _runParse,
          onManual: () => GoRouter.of(context).pop(),
        ),
        AiParseStatus.ready => _buildReady(),
      },
      bottomNavigationBar: _status == AiParseStatus.ready
          ? _ConfirmBar(
              assessment: _form.completeness,
              allFilled: _result.allFilled,
              allowIncomplete: widget.args.flashMode,
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
          widget.args.flashMode ? '抢发：可先发布，24 小时内补全' : '每项都可以改，改完再发',
          style: TextStyle(
            fontSize: AppTypeScale.small.size,
            color: const Color(AppColors.textSecondary),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        // 「说一句」输入 + 重新识别（模式① 的文本输入；B2-4）。
        _SentenceInput(controller: _sentenceCtrl, onRecognize: _runParse),
        const SizedBox(height: AppSpacing.md),
        // B2-4 内容标识落点一：AI 辅助生成显式标注（PRD §5.9 合规裁定）。
        const _AiAssistNote(),
        const SizedBox(height: AppSpacing.sm),
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
          quota: _quota,
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

  /// 慢文案切换定时器。解析早早成功时本视图会先被移除，必须能取消，
  /// 否则残留定时器会在 widget 树销毁后触发（测试 teardown 断言、真机泄漏）。
  Timer? _slowTimer;

  @override
  void initState() {
    super.initState();
    _slowTimer = Timer(const Duration(seconds: kParsingSlowSeconds), () {
      if (mounted) setState(() => _slow = true);
    });
  }

  @override
  void dispose() {
    _slowTimer?.cancel();
    super.dispose();
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

/// 「说一句」输入行（模式① 的文本输入；B2-4）。
///
/// 输入文本后点「识别」重新调用服务端解析。克制样式，不与猜测列表争视觉。
class _SentenceInput extends StatelessWidget {
  const _SentenceInput({required this.controller, required this.onRecognize});

  /// 文本控制器（由父级持有并负责 dispose）。
  final TextEditingController controller;

  /// 点「识别」回调（触发一次服务端解析）。
  final Future<void> Function() onRecognize;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            decoration: const InputDecoration(
              isDense: true,
              hintText: '说一句，例如「楼下超市卖苹果 5 元」',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        TextButton(onPressed: () => onRecognize(), child: const Text('识别')),
      ],
    );
  }
}

/// 「AI 辅助生成」内容标识（B2-4 内容标识落点一；PRD §5.9 合规裁定）。
class _AiAssistNote extends StatelessWidget {
  const _AiAssistNote();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(
          Icons.auto_awesome_outlined,
          size: 14,
          color: Color(AppColors.textPlaceholder),
        ),
        const SizedBox(width: AppSpacing.xs),
        Text(
          'AI 辅助生成 · 请核对后发布',
          style: TextStyle(
            fontSize: AppTypeScale.caption.size,
            color: const Color(AppColors.textPlaceholder),
          ),
        ),
      ],
    );
  }
}

/// 配额说明（§5.10「AI 配额二维分层」）。
///
/// 传入服务端真实配额快照时展示「已用 / 上限」；未取到（解析失败兜底）时按
/// [NfrAi] 常量算上限文案。**不自行推演剩余次数**：计数在服务端（§5.9 仅确认发布计 1 次），
/// 客户端自算的剩余数清一次缓存就会「恢复满额」，那比不显示更坏。
class _QuotaNote extends StatelessWidget {
  const _QuotaNote({
    required this.verified,
    required this.level,
    required this.sensitive,
    this.quota,
  });

  final bool verified;
  final CompletenessLevel level;
  final bool sensitive;

  /// 服务端配额快照（可空；空则回退常量上限文案）。
  final AiQuotaDto? quota;

  @override
  Widget build(BuildContext context) {
    final snapshot = quota;
    final String text;
    if (snapshot != null) {
      text = '今日 AI 额度已用 ${snapshot.used} / ${snapshot.limit} 次';
    } else {
      final limit = dailyAiQuota(
        verified: verified,
        level: level,
        sensitiveCategory: sensitive,
      );
      text = '你当前每日 AI 额度 $limit 次'
          '（${verified ? '已实名' : '未实名'} · ${level.label}'
          '${sensitive ? ' · 高敏类目 +10' : ''}）';
    }
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
            text,
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
    this.allowIncomplete = false,
  });

  final CompletenessAssessment assessment;

  /// 是否所有字段都有值（§5.9「必填项未补齐时『确认发布』保持禁用」）。
  final bool allFilled;

  /// 是否允许「未补齐也发布」（抢发模式④：§5.9「只填标题 + 拍照就发布」，
  /// 落 🔴 并在 24h 内补全）。为 true 时按钮恒可点，提示改为抢发口径。
  final bool allowIncomplete;

  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final bool canPublish = allFilled || allowIncomplete;
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
          if (!allFilled && !allowIncomplete) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              '还有字段标着「需你补充」，补完才能发布',
              style: TextStyle(
                fontSize: AppTypeScale.caption.size,
                color: const Color(AppColors.warningText),
              ),
            ),
          ],
          if (allowIncomplete && !allFilled) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              '抢发：先发布占位，24 小时内补全（未补全会退出推荐池）',
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
              onPressed: canPublish ? onConfirm : null,
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
