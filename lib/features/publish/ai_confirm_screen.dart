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

import 'package:dio/dio.dart';
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
import '../location/high_accuracy_locator.dart';
import '../location/location_center.dart';
import '../location/location_permission.dart';
import '../post/post_repository.dart';
import 'ai_confirm_args.dart';
import 'precheck_sheet.dart';
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

  /// 联系方式输入框（契约 `contact_value` 必填，AI 入口不采集故必须在此补）。
  final TextEditingController _contactCtrl = TextEditingController();

  /// 单次高精度定位进行中的防重入标记。
  bool _locating = false;

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
    _contactCtrl.text = _form.contact;
    _runParse();
  }

  @override
  void dispose() {
    _doorCtrl.dispose();
    _contactCtrl.dispose();
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
  /// 解析文本取入口带入的一句话（[_initialSentence]）。
  /// 失败（含 42901 配额耗尽 / 50301 不可用 / 传输错误）一律进 `failed` 态，
  /// 保留用户已输入内容（§5.9「已输入内容全部保留」）。
  Future<void> _runParse() async {
    setState(() => _status = AiParseStatus.parsing);
    final text = _initialSentence();
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
        // 猜测必须回填表单：确认页展示的是 [_edited] 覆盖层，而发布载荷
        // 由 [_form] 构造 —— 只写展示就会出现「页面有标题、载荷没 title」
        // 的 400（2026-10-17 真机实测）。重新识别视为接受新结果，手改清空。
        _form = _applyGuessToForm(result);
        _edited.clear();
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

  /// 把服务端猜测回填进表单（发布载荷的唯一真源）。
  ///
  /// 参数：[result] 服务端解析结果（Step 4 已剔除越界字段）。
  /// 返回：[PublishFormState] 回填后的新快照。
  PublishFormState _applyGuessToForm(AiParseResultDto result) {
    final guess = result.guess;
    var next = _form;
    // 只在表单还没选分类时采用猜测：用户已选的叶子优先，
    // 否则「先选分类再识别」会把用户的选择换掉。
    final leafId = guess.leafCategoryId;
    if (leafId != null && next.leafCategoryId == null) {
      next = next.withCategory(leafId);
    }
    final title = guess.title?.trim() ?? '';
    if (title.isNotEmpty) next = next.copyWith(title: title);
    final price = guess.price;
    if (price != null) {
      final unit = guess.priceUnit?.trim() ?? '';
      next = next.copyWith(
        priceText: _trimNumber(price),
        priceUnit: unit.isEmpty ? next.priceUnit : unit,
      );
    } else if ((guess.priceUnit?.trim() ?? '').isNotEmpty) {
      next = next.copyWith(priceUnit: guess.priceUnit!.trim());
    }
    final templateValues = guess.templateValues;
    if (templateValues != null && templateValues.isNotEmpty) {
      final merged = <String, String>{...next.templateValues};
      for (final entry in templateValues.entries) {
        final value = entry.value?.toString().trim() ?? '';
        if (value.isNotEmpty) merged[entry.key] = value;
      }
      next = next.copyWith(templateValues: merged);
    }
    return next;
  }

  /// 把确认页的手改值同步进表单。
  ///
  /// 参数：[fieldKey] 字段键（同 [FieldGuess.fieldKey]）；
  ///       [value] 新值（空串表示撤回到 AI 原猜测值）。
  /// 返回：[PublishFormState] 同步后的新快照。
  PublishFormState _applyEditToForm(String fieldKey, String value) {
    // 分类是 ID 语义，标签文本反解不出 ID：ID 已由 withCategory 写入。
    if (fieldKey == 'category') return _form;
    if (fieldKey == 'title') return _form.copyWith(title: value.trim());
    if (fieldKey == 'price') {
      // 展示值是「数值 + 单位」的合成串（如「50 元/月」），回写必须拆开：
      // 整串进 priceText 会让 priceValue 解析失败，价格静默丢失。
      final match =
          RegExp(r'^(\d+(?:\.\d+)?)\s*(.*)$').firstMatch(value.trim());
      if (match == null) return _form.copyWith(priceText: '');
      final unit = match.group(2)!.trim();
      return _form.copyWith(
        priceText: match.group(1)!,
        priceUnit: unit.isEmpty ? _form.priceUnit : unit,
      );
    }
    return _form.copyWith(
      templateValues: {..._form.templateValues, fieldKey: value.trim()},
    );
  }

  /// 采集当前位置（与发布页同一口径：先高精度，失败退化到会话最优点）。
  ///
  /// 返回：[Future]，定位完成时结束。
  Future<void> _useCurrentLocation() async {
    if (ref.read(locationPermissionProvider) !=
        LocationPermissionPhase.granted) {
      _toast('请先开启定位权限，再使用当前位置');
      return;
    }
    if (_locating) return;
    _locating = true;
    _toast('正在获取高精度定位…');
    try {
      final high = await locateForPublish(ref);
      if (!mounted) return;
      final coordinate = high != null
          ? (lat: high.lat, lng: high.lng)
          : readPublishCoordinate(ref);
      if (coordinate == null) {
        _toast('定位失败，请到开阔处重试');
        return;
      }
      setState(
        () => _form = _form.copyWith(lng: coordinate.lng, lat: coordinate.lat),
      );
      if (high == null) {
        _toast('高精度定位未成功，已使用最近定位点');
      }
    } finally {
      _locating = false;
    }
  }

  /// 契约必填是否齐（分类 / 标题 / 位置 / 联系方式）。
  ///
  /// 不用 [PublishFormState.blocker]：它把手动页的描述与协议也算必填；
  /// AI 快速发布按契约 `PostCreateRequest` 的必填集执行（2026-10-17 裁定）。
  bool get _requiredReady =>
      _form.leafCategoryId != null &&
      _form.title.trim().isNotEmpty &&
      _form.hasLocation &&
      _form.contact.trim().isNotEmpty;

  /// 本页完整度。不复用 `_form.completeness`：其必填口径含描述，
  /// 会让角标永远显示「还差 1 项升 🟢」而页面上无处可补。
  CompletenessAssessment get _assessment => CompletenessAssessment(
        requiredFieldsComplete: _requiredReady,
        // 与发布页共用同一「位置精确」判据（KTD3）：拼车看起终点 POI，
        // 其余分类看门牌号 —— 否则本页说 🟢、落库却是 🟡。
        hasDoorNumber: _form.locationPrecise,
        leafCategoryPrecise: _form.leafCategoryId != null &&
            leafCategoryById(_form.leafCategoryId!) != null,
      );

  /// 契约必填缺项的可读文案（按表单段落顺序）。
  ///
  /// 返回：[String] 如「位置、联系方式」；无缺项返回空串。
  String _missingRequiredText() {
    final missing = <String>[];
    if (_form.leafCategoryId == null) missing.add('分类');
    if (_form.title.trim().isEmpty) missing.add('标题');
    if (!_form.hasLocation) missing.add('位置');
    if (_form.contact.trim().isEmpty) missing.add('联系方式');
    return missing.join('、');
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
      // 换分类 = 换模板：只丢弃「旧模板字段」的手改值。
      // ⚠ 不能 _edited.clear()：那会把与模板无关的手改值（价格 / 标题）一并清掉。
      // 2026-10-17 真机实证：先补价格、再选分类 ⇒ 价格被打回「需你补充」。
      final staleTemplateKeys =
          _form.template.extraFields.map((field) => field.key).toSet();
      setState(() {
        _form = _form.withCategory(leafId);
        _edited.removeWhere((key, _) => staleTemplateKeys.contains(key));
        // 分类行要立即反映用户这次的新选择：否则仍取服务端旧 leaf_category_id，
        // 页面会显示「需你补充」（Bug B，同日真机暴露）。
        final categoryLabel = categoryPathLabel(leafId);
        if (categoryLabel != null) {
          _edited['category'] = categoryLabel;
        }
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
      // 展示覆盖层与表单必须同步写：发布载荷只认 [_form]（见 _applyGuessToForm）。
      if (value.isEmpty) {
        // 改成空 = 撤回这次修改，回到 AI 原猜测值。
        // 若存空串会得到「有值但是空」这种既不是猜出也不是未猜出的第三态。
        _edited.remove(guess.fieldKey);
        _form = _applyEditToForm(guess.fieldKey, guess.value ?? '');
      } else {
        _edited[guess.fieldKey] = value;
        _form = _applyEditToForm(guess.fieldKey, value);
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
    // 本地闸门：缺必填不请求。服务端会 40001 秒拒，用户只能得到
    // 「参数错误」这种无法指向动作的提示（2026-10-17 真机实证）。
    // 抢发模式按 §5.11 允许先发后补，不做此拦截。
    if (!widget.args.flashMode) {
      final missing = _missingRequiredText();
      if (missing.isNotEmpty) {
        _toast('还差$missing，补齐后才能发布');
        return;
      }
    }
    setState(() => _publishing = true);
    final payload = <String, Object?>{
      ..._form.postDraftPayload(),
      // B2-4：AI 辅助标记（服务端据此扣配额 + 落内容标识）。
      'ai_assisted': true,
    };
    // 诊断阶段标记：失败时据此判断断在 precheck / createPost / 转场。
    var stage = 'precheck';
    try {
      final repo = ref.read(postRepositoryProvider);
      final precheck = await repo.precheck(payload);
      if (!mounted) return;
      if (!precheck.passed) {
        if (precheck.blocks.isEmpty) {
          _toast('暂不满足发布条件');
          return;
        }
        // 阻断必须让用户看得见：与手动发布页共用同一弹层（一次性列全、
        // 必须点「知道了」才关闭）。4 秒即消失的 SnackBar 会被用户当成
        // 「点了没反应」（2026-10-17 真机实证）。
        await showPrecheckBlocks(
          context,
          precheck.blocks,
          phoneBound: ref.read(authSessionProvider)?.phoneBound ?? true,
        );
        return;
      }
      await repo.createPost(payload);
      if (!mounted) return;
      stage = 'navigate';
      // 成功必须有明确信号：
      // ① 先给一条 SnackBar 兜底 —— 即便页面转场被误触/打断，用户也能看到结果；
      // ② 用 pushReplacement 把确认页换成成功页：发布流程到此结束，
      //    返回键直接回地图，不会退回「还能再点一次确认发布」的旧页面。
      //    （2026-10-17 真机：push 后用户未看到成功页，也无任何提示。）
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('发布成功')),
      );
      GoRouter.of(context).pushReplacement(
        AppRoutes.publishSuccess,
        extra: _form,
      );
    } on ApiException catch (error) {
      // ignore: avoid_print
      print('[PUBLISH][$stage] ApiException code=${error.code} msg=${error.message}');
      if (mounted) await _showFailure(error.uiMessage);
    } catch (error, stack) {
      // 非信封异常此前会被静默吞掉：按钮从「发布中…」复原，用户却什么都看不到。
      // 拦截器链会把 ApiException 包进 DioException(type: unknown)，故解一层取原文。
      final cause = error is DioException ? error.error : null;
      // ignore: avoid_print
      print('[PUBLISH][$stage] unexpected error: $error | cause=$cause\n$stack');
      if (mounted) await _showFailure(_failureMessage(error));
    } finally {
      if (mounted) setState(() => _publishing = false);
    }
  }

  /// 发布失败对话框（模态，必须手动关闭）。
  ///
  /// 参数：[message] 用户可读文案。
  /// 返回：[Future] 关闭时完成。
  Future<void> _showFailure(String message) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('发布未完成'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  /// 从任意异常提取用户可读文案。
  ///
  /// 拦截器链把 [ApiException] 包进 `DioException(type: unknown, error: ...)`
  /// （envelope_interceptor 的既定设计），因此必须拆一层取内层原文，
  /// 否则用户只能看到「发布失败，请稍后重试」这种没有信息量的兜底文案。
  ///
  /// 参数：[error] 捕获到的任意异常。
  /// 返回：[String] 可直接展示的中文提示。
  String _failureMessage(Object error) {
    if (error is ApiException) return error.uiMessage;
    if (error is DioException && error.error is ApiException) {
      return (error.error as ApiException).uiMessage;
    }
    return '发布失败，请稍后重试';
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
              assessment: _assessment,
              allFilled: _result.allFilled,
              requiredReady: _requiredReady,
              busy: _publishing,
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
        // 拍的照片必须看得见：它已进 `media_ids` 随帖子发布，这里给出缩略图与张数，
        // 避免「确认页没有图 = 图被丢了」的错觉（2026-10-23 用户反馈）。
        if (_form.mediaIds.isNotEmpty) ...[
          _MediaGallery(
            count: _form.mediaIds.length,
            url: widget.args.initialMediaUrl,
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        // B2-4 内容标识落点一：AI 辅助生成显式标注（PRD §5.9 合规裁定）。
        const _AiAssistNote(),
        const SizedBox(height: AppSpacing.sm),
        for (final guess in result.guesses) ...[
          _GuessRow(guess: guess, onTap: () => _editField(guess)),
          const SizedBox(height: AppSpacing.sm),
        ],
        const SizedBox(height: AppSpacing.sm),
        _GreenSprint(
          assessment: _assessment,
          usesRoutePair: _form.usesRoutePair,
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
        // 契约必填区放在冲刺区之后：位置/联系方式是硬门槛，
        // 而「升 🟢」是可选的加成，顺序不能让可选项挡住必填项。
        _RequiredSection(
          hasLocation: _form.hasLocation,
          onUseCurrentLocation: _useCurrentLocation,
          contactController: _contactCtrl,
          onContactChanged: (v) => setState(() {
            _form = _form.copyWith(contact: v);
          }),
        ),
        const SizedBox(height: AppSpacing.md),
        _QuotaNote(
          verified: ref.watch(isLoggedInProvider),
          level: _assessment.level,
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

/// 发布必填区（位置 + 联系方式）。
///
/// AI 快速入口只带「图片 + 一句话」，位置与联系方式在表单里本就是空的；
/// 而契约 `PostCreateRequest` 把 `lng`/`lat`/`contact_value` 列为必填，
/// 缺任一项都被服务端 40001 秒拒（2026-10-17 真机：precheck 200、`POST /posts` 400）。
class _RequiredSection extends StatelessWidget {
  const _RequiredSection({
    required this.hasLocation,
    required this.onUseCurrentLocation,
    required this.contactController,
    required this.onContactChanged,
  });

  /// 是否已采集到坐标（表单 `hasLocation` 的唯一判据）。
  final bool hasLocation;

  /// 「使用当前位置」回调（权限判定在父级）。
  final VoidCallback onUseCurrentLocation;

  /// 联系方式控制器（父级持有并负责 dispose）。
  final TextEditingController contactController;

  /// 联系方式变更回调。
  final ValueChanged<String> onContactChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: const Color(AppColors.surface),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: const Color(AppColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '发布必填',
            style: TextStyle(
              fontSize: AppTypeScale.h3.size,
              fontWeight: FontWeight.w600,
              color: const Color(AppColors.textPrimary),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Icon(
                hasLocation ? Icons.place : Icons.place_outlined,
                size: 16,
                color: hasLocation
                    ? const Color(AppColors.success)
                    : const Color(AppColors.warningText),
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Text(
                  hasLocation ? '已获取当前位置' : '还未获取位置',
                  style: TextStyle(
                    fontSize: AppTypeScale.small.size,
                    color: const Color(AppColors.textSecondary),
                  ),
                ),
              ),
              TextButton(
                onPressed: onUseCurrentLocation,
                child: Text(
                  hasLocation ? '重新获取' : '使用当前位置',
                  style: TextStyle(fontSize: AppTypeScale.small.size),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          TextField(
            controller: contactController,
            keyboardType: TextInputType.phone,
            onChanged: onContactChanged,
            decoration: const InputDecoration(
              isDense: true,
              labelText: '联系方式',
              hintText: '手机号',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
    );
  }
}

/// 「再花 5 秒升完整」冲刺区（§5.9「确认页默认带 🟢 冲刺项」）。
///
/// §5.9 明确「只放 🟢 档差的两项 —— 位置精确项与三级类目」（位置精确项在
/// 拼车为起终点、其余分类为门牌号）。不放必填项：
/// 必填没齐的话「确认发布」本就是禁用的，那不叫冲刺，叫拦截。
class _GreenSprint extends StatelessWidget {
  const _GreenSprint({
    required this.assessment,
    required this.usesRoutePair,
    required this.doorController,
    required this.onDoorChanged,
    required this.onPickCategory,
    required this.categoryPath,
  });

  final CompletenessAssessment assessment;

  /// 该分类的位置精确是否走起终点 POI（拼车），决定是否还渲染门牌号输入。
  final bool usesRoutePair;
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

          // 冲刺项一：位置精确
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
            // 拼车按起终点 POI 判定（KTD3），本页没有起终点选择入口 —
            // 不再给一个对拼车用户无意义的门牌号输入框。
            if (usesRoutePair)
              Text(
                '回到发布页选择起终点即可升级',
                style: TextStyle(
                  fontSize: AppTypeScale.caption.size,
                  color: const Color(AppColors.textSecondary),
                ),
              )
            else
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

/// 媒体图集（确认页）：展示随帖提交的照片，证明它没有被丢弃。
///
/// 缩略图取上传返回的限时地址；地址缺失（历史草稿/重发态）时退化为占位图标，
/// 张数仍按 [count] 如实显示 —— 计数与提交载荷同源（[PublishFormState.mediaIds]）。
class _MediaGallery extends StatelessWidget {
  /// 构造媒体图集。
  ///
  /// 参数：[count] 已 commit 的图片张数；[url] 首张图片的访问地址（可空）。
  const _MediaGallery({required this.count, this.url});

  /// 已 commit 的图片张数。
  final int count;

  /// 首张图片的访问地址（可空）。
  final String? url;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: const Color(AppColors.surface),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: const Color(AppColors.border)),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            child: _buildThumbnail(),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              '媒体图集 $count / $kMaxImageCount · 随这条信息一起发布',
              style: TextStyle(
                fontSize: AppTypeScale.small.size,
                color: const Color(AppColors.textSecondary),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 缩略图：有地址走网络图（失败退占位），无地址直接占位。
  ///
  /// 返回：[Widget] 缩略图。
  Widget _buildThumbnail() {
    final imageUrl = url;
    if (imageUrl == null || imageUrl.isEmpty) {
      return const _MediaThumbPlaceholder();
    }
    return Image.network(
      imageUrl,
      width: 56,
      height: 56,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => const _MediaThumbPlaceholder(),
    );
  }
}

/// 缩略图占位（无地址或加载失败）。
class _MediaThumbPlaceholder extends StatelessWidget {
  const _MediaThumbPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 56,
      height: 56,
      color: const Color(AppColors.background),
      child: const Icon(
        Icons.image_outlined,
        size: 24,
        color: Color(AppColors.textPlaceholder),
      ),
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
    required this.requiredReady,
    required this.onConfirm,
    this.busy = false,
    this.allowIncomplete = false,
  });

  final CompletenessAssessment assessment;

  /// 是否所有字段都有值（§5.9「必填项未补齐时『确认发布』保持禁用」）。
  final bool allFilled;

  /// 契约必填（分类/标题/位置/联系方式）是否齐 —— 比 [allFilled] 更硬：
  /// AI 猜全不等于后端 `PostCreateRequest` 能过（位置与联系方式不在猜测集内）。
  final bool requiredReady;

  /// 发布中（防重入兼可见反馈，否则点击后界面毫无变化）。
  final bool busy;

  /// 是否允许「未补齐也发布」（抢发模式④：§5.9「只填标题 + 拍照就发布」，
  /// 落 🔴 并在 24h 内补全）。为 true 时按钮恒可点，提示改为抢发口径。
  final bool allowIncomplete;

  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    // 契约必填是硬门槛（普通模式）；抢发模式按 §5.11 先发后补。
    final bool canPublish = !busy &&
        (allFilled || allowIncomplete) &&
        (requiredReady || allowIncomplete);
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
          ] else if (!requiredReady && !allowIncomplete) ...[
            // 猜测已齐但位置/联系方式仍空（AI 入口不采集这两项）。
            const SizedBox(height: AppSpacing.xs),
            Text(
              '还差发布必填项（位置 / 联系方式），补齐后才能发布',
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
                busy ? '发布中…' : '确认发布',
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
