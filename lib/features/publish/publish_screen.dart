/// 发布页（PRD §5.4.1 八段表单 / §5.7 实现逻辑 / §5.8 边界表，页面 ID：publish-screen）。
///
/// 它是「发布」这条主闭环的入口，也是分类树（条目 [71]）与模板引擎
/// （`domain/publish_template.dart`）的第一个真实消费方。
///
/// **校验不写在本文件**：全部收在 [PublishFormState.blocker]。页面只做两件事 ——
/// 把输入回写进状态、把 blocker 的文案显示出来。这样「填完了按钮还是灰的」
/// 这类问题可以在单测里定位，而不是靠手点复现。
///
/// **§5.4.1 八段中降级处理的两段，及原因**：
/// ① **第 2 段位置**：地图选点依赖高德 Key（未申请，说明文档 M4-1b 已记）。
///    本页给「使用当前位置（演示）」把 `hasLocation` 置真，让后面六段的校验
///    可被完整走通；「地图选点」按钮保留但禁用并注明原因 —— 隐藏它会让
///    验收时无法判断是漏做还是待前置。
/// ② **第 6 段媒体**：上传依赖 §13.2 `post_media` 与 CDN（详情页同因）。
///    本页只呈现 `0 / 9` 计数与上传区占位，不做选图。
///
/// **本轮不做的两条产品能力**（说明文档本轮「不做」清单已列）：
/// - **记忆机制**（§5.7）：需云端存「user_id + category_leaf_id」的上次值。
///   模板里已留 `memoryHint` 展示位，本页照常渲染「上次：…」那行版面，
///   但值来自模板常量而非真实历史 —— 文案里不写「记忆带入」以免误认。
/// - **未实名每日 1 条 + 先发后审受限态**（§5.8 首行 / §3.7）：判定与计数都在
///   服务端，客户端自计的次数清缓存即失效，做出来是个假门槛。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design_tokens.dart';
import '../../domain/category_tree.dart';
import '../../domain/publish_template.dart';
import '../../router/app_router.dart';
import '../auth/auth_repository.dart';
import 'publish_form_state.dart';

/// 位置演示值（§5.4.1 第 2 段示例「XX 小区南门·300m」）。
///
/// 写成常量并在 UI 上标注「演示」：一个看起来像真定位的假地址，
/// 在验收时会被当成定位已接通。
const String _demoLocationLabel = 'XX 小区南门 · 300m（演示位置）';

/// 发布页。
class PublishScreen extends ConsumerStatefulWidget {
  const PublishScreen({super.key});

  @override
  ConsumerState<PublishScreen> createState() => _PublishScreenState();
}

class _PublishScreenState extends ConsumerState<PublishScreen> {
  PublishFormState _form = const PublishFormState();

  final TextEditingController _titleCtrl = TextEditingController();
  final TextEditingController _priceCtrl = TextEditingController();
  final TextEditingController _descCtrl = TextEditingController();
  final TextEditingController _contactCtrl = TextEditingController();

  /// 模板文本类字段的控制器，key 同 [TemplateFieldSpec.key]。
  ///
  /// 按需创建而非随模板一次性建好：换分类会换掉整组字段，
  /// 预建的控制器在新模板里无人使用，dispose 时也容易漏。
  final Map<String, TextEditingController> _templateCtrls = {};

  @override
  void dispose() {
    _titleCtrl.dispose();
    _priceCtrl.dispose();
    _descCtrl.dispose();
    _contactCtrl.dispose();
    for (final c in _templateCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// 打开分类级联选择器并接收叶子 ID（§5.4.2）。
  Future<void> _pickCategory() async {
    final leafId = await context.push<int>(
      AppRoutes.categorySelector,
      extra: _form.leafCategoryId,
    );
    if (leafId == null || !mounted) return;
    setState(() {
      // 用 withCategory 而非 copyWith：换分类要连带清掉旧模板字段值
      // （理由见 publish_form_state.dart 的 withCategory 注释）。
      _form = _form.withCategory(leafId);
      // 控制器也要一起清，否则输入框里还留着上一个模板的文字，
      // 而状态里已经是空 —— 用户看到有字，按钮却说「模板必填项未填完」。
      for (final c in _templateCtrls.values) {
        c.dispose();
      }
      _templateCtrls.clear();
    });
  }

  /// 取（或懒建）某个模板字段的控制器。
  ///
  /// 参数 [key] 字段键。返回该字段的控制器，首次调用时用当前值初始化。
  TextEditingController _templateCtrl(String key) {
    return _templateCtrls.putIfAbsent(
      key,
      () => TextEditingController(text: _form.templateValues[key] ?? ''),
    );
  }

  void _setTemplateValue(String key, String value) {
    setState(() {
      _form = _form.copyWith(
        templateValues: {..._form.templateValues, key: value},
      );
    });
  }

  /// 提交发布（§5.5 S6 / §5.8「强制认证拦截」）。
  Future<void> _submit() async {
    if (!_form.canSubmit) return;
    final router = GoRouter.of(context);

    // 未登录先引导登录（§5.5 S1「或首次弹未登录引导」）。
    // 放在资质判定之前：没有用户身份就无从判断他持有哪些资质。
    if (!ref.read(isLoggedInProvider)) {
      final ok = await router.push<bool>(AppRoutes.login);
      if (!mounted || ok != true) return;
    }

    // §5.8「强制认证拦截」：高敏类目需资质。
    // TODO(接后端 §12.4)：用户已持资质列表无本地来源，当前一律视为未持有，
    // 故需资质的类目必然拦截。接口接通后此处应改为「已持有则放行」。
    final cert = _form.requiredCert;
    if (cert != RequiredCert.none) {
      final goCertify = await router.push<bool>(
        AppRoutes.certModal,
        extra: cert,
      );
      if (!mounted) return;
      if (goCertify == true) router.push(AppRoutes.trust);
      // 无论用户选哪个都不放行 —— 拦截的意义就在于资质没到位不能发。
      return;
    }

    // 真正的提交需 §12.3 `POST /posts`。无服务端时直接进完成页，
    // 带上表单快照供完成页算 §9.8 档位。
    router.push(AppRoutes.publishSuccess, extra: _form);
  }

  /// 临时入口：走 AI 确认页（§5.9）。
  ///
  /// **为什么这个入口在发布页而不在首页**：§5.9 的确认页正路入口是 §6.13 T6-①
  /// 首页 FAB「AI 帮我发」→ 弹四模式，而该 FAB 属 §6.13，M4 未排。
  /// 用户 2026-09-01 裁定先在此加临时入口，**FAB 做出来后须移除本方法与按钮**。
  ///
  /// 与 [_submit] 的区别：本入口不要求必填齐全 —— §5.9 的确认页本就是
  /// 用来补齐 AI 没猜出的字段的，要求填完再去反而本末倒置。
  Future<void> _openAiConfirm() async {
    final router = GoRouter.of(context);
    if (!ref.read(isLoggedInProvider)) {
      final ok = await router.push<bool>(AppRoutes.login);
      if (!mounted || ok != true) return;
    }
    router.push(AppRoutes.aiConfirm, extra: _form);
  }

  @override
  Widget build(BuildContext context) {
    final template = _form.template;
    final blocker = _form.blocker;

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
          onPressed: () {
            final router = GoRouter.of(context);
            router.canPop() ? router.pop() : router.go(AppRoutes.home);
          },
        ),
        title: Text(
          '发布',
          style: TextStyle(
            fontSize: AppTypeScale.h3.size,
            fontWeight: FontWeight.w600,
            color: const Color(AppColors.textPrimary),
          ),
        ),
        actions: [
          // §5.4.1 顶部栏右上主按钮，禁用直到必填齐全。与底部主按钮同一动作 ——
          // 长表单滚到中段时顶部按钮省一次回滚。
          TextButton(
            onPressed: _form.canSubmit ? _submit : null,
            child: Text(
              '发布',
              style: TextStyle(
                fontSize: AppTypeScale.body.size,
                fontWeight: FontWeight.w600,
                color: _form.canSubmit
                    ? const Color(AppColors.primary)
                    : const Color(AppColors.textPlaceholder),
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        // 底部留白避开常驻主按钮条，否则最后一段会被压住（详情页同做法）
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          _KindSwitch(
            kind: _form.kind,
            onChanged: (k) => setState(() => _form = _form.copyWith(kind: k)),
          ),
          _TempAiEntry(onTap: _openAiConfirm),
          _SectionCard(
            index: 1,
            title: '选择分类',
            done: _form.leafCategoryId != null,
            child: _CategoryRow(
              leafId: _form.leafCategoryId,
              onTap: _pickCategory,
            ),
          ),
          _SectionCard(
            index: 2,
            title: '位置',
            done: _form.hasLocation,
            child: _LocationRow(
              hasLocation: _form.hasLocation,
              onUseCurrent: () =>
                  setState(() => _form = _form.copyWith(hasLocation: true)),
            ),
          ),
          _SectionCard(
            index: 3,
            title: '标题',
            done: _form.title.trim().isNotEmpty,
            child: TextField(
              controller: _titleCtrl,
              maxLength: 40,
              decoration: _fieldDecoration(
                hint: template.titlePlaceholder,
                // 需求态的标题前缀由分类自动推导（§7.4.3），做成不可编辑前缀
                // 而非替用户改标题文本：改了他的输入，他下次编辑时会看到
                // 一个自己没打过的方括号。
                prefix: demandPrefixFor(_form.kind, _form.leafCategoryId),
              ).copyWith(counterText: ''),
              onChanged: (v) => setState(() => _form = _form.copyWith(title: v)),
            ),
          ),
          _SectionCard(
            index: 4,
            title: '价格',
            done: _form.priceSettled,
            child: _PriceRow(
              form: _form,
              controller: _priceCtrl,
              onPriceChanged: (v) =>
                  setState(() => _form = _form.copyWith(priceText: v)),
              onUnitChanged: (u) =>
                  setState(() => _form = _form.copyWith(priceUnit: u)),
              onNegotiableChanged: (v) =>
                  setState(() => _form = _form.copyWith(negotiable: v)),
            ),
          ),
          _SectionCard(
            index: 5,
            title: '描述',
            done: _form.description.trim().isNotEmpty,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _HintText(template.descriptionGuide),
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  controller: _descCtrl,
                  maxLines: 5,
                  minLines: 3,
                  decoration: _fieldDecoration(hint: '填得越具体越容易被联系'),
                  onChanged: (v) =>
                      setState(() => _form = _form.copyWith(description: v)),
                ),
                const SizedBox(height: AppSpacing.xs),
                // 字数提示只提示不拦截（§5.4.1 写的是「建议 30-200 字」）
                _HintText(_form.descriptionHint),
              ],
            ),
          ),
          // 模板附加字段（§5.4.3「附加字段」列）。通用模板无附加字段，
          // 此段自然不出现 —— 空标题的空卡片比不显示更让人以为是加载失败。
          if (template.extraFields.isNotEmpty)
            _SectionCard(
              index: null,
              title: '分类专属信息',
              done: blocker != PublishBlocker.templateFieldMissing,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final field in template.extraFields)
                    _TemplateField(
                      spec: field,
                      value: _form.templateValues[field.key] ?? '',
                      controller: field.type == TemplateFieldType.select
                          ? null
                          : _templateCtrl(field.key),
                      onChanged: (v) => _setTemplateValue(field.key, v),
                    ),
                ],
              ),
            ),
          _SectionCard(
            index: 6,
            title: '媒体',
            done: false,
            child: _MediaPlaceholder(count: _form.imageCount),
          ),
          _SectionCard(
            index: 7,
            title: '有效期',
            done: true,
            child: _HintText(
              // §5.11「默认 7 天，不提供其他可选值」—— 故这里是一行说明而非选择器。
              '默认 $kDefaultValidDays 天，到期可一键刷新续 $kDefaultValidDays 天（不提供其他选项）',
            ),
          ),
          _SectionCard(
            index: 8,
            title: '联系方式',
            done: _form.contact.trim().isNotEmpty,
            child: TextField(
              controller: _contactCtrl,
              keyboardType: TextInputType.phone,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              maxLength: 11,
              decoration: _fieldDecoration(
                hint: '请输入可联系到你的手机号',
              ).copyWith(counterText: ''),
              onChanged: (v) =>
                  setState(() => _form = _form.copyWith(contact: v)),
            ),
          ),
        ],
      ),
      bottomNavigationBar: _SubmitBar(
        agreed: _form.agreed,
        blocker: blocker,
        onAgreedChanged: (v) =>
            setState(() => _form = _form.copyWith(agreed: v)),
        onSubmit: _submit,
      ),
    );
  }
}

/// 资源 / 需求胶囊切换（§5.4.1 第二行）。
class _KindSwitch extends StatelessWidget {
  const _KindSwitch({required this.kind, required this.onChanged});

  final PublishKind kind;
  final ValueChanged<PublishKind> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(AppColors.surface),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        children: [
          for (final k in PublishKind.values)
            Expanded(
              child: GestureDetector(
                onTap: () => onChanged(k),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: k == kind
                        ? const Color(AppColors.primary)
                        : const Color(AppColors.background),
                    borderRadius: BorderRadius.circular(AppRadius.full),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // 资源实心 / 需求空心，与地图 Marker 的双向语义一致
                      //（§5.4.1「资源实心 / 需求空心图标示意」）
                      Icon(
                        k == PublishKind.supply
                            ? Icons.circle
                            : Icons.circle_outlined,
                        size: 12,
                        color: k == kind
                            ? Colors.white
                            : const Color(AppColors.textSecondary),
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      Text(
                        k.label,
                        style: TextStyle(
                          fontSize: AppTypeScale.body.size,
                          fontWeight: k == kind
                              ? FontWeight.w600
                              : FontWeight.w400,
                          color: k == kind
                              ? Colors.white
                              : const Color(AppColors.textSecondary),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 临时 AI 入口（§5.9 确认页的代入口）。
///
/// **它不属于 §5.4.1 八段**，故不用 [_SectionCard]（无段序号、无「已填」勾），
/// 并在副文案里写明「临时入口」—— 否则下一个人打开发布页会以为
/// §5.4.1 漏写了这一段，进而把它当既成事实继续加码。
///
/// **移除条件**：§6.13 T6-① 首页 FAB「AI 帮我发」上线后删除本类与
/// [_PublishScreenState._openAiConfirm]。
class _TempAiEntry extends StatelessWidget {
  const _TempAiEntry({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: AppSpacing.sm),
      color: const Color(AppColors.surface),
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: onTap,
            child: Row(
              children: [
                const Icon(
                  Icons.auto_awesome_outlined,
                  size: 18,
                  color: Color(AppColors.accent),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    'AI 帮我补齐',
                    style: TextStyle(
                      fontSize: AppTypeScale.body.size,
                      fontWeight: FontWeight.w600,
                      color: const Color(AppColors.textPrimary),
                    ),
                  ),
                ),
                const Icon(
                  Icons.chevron_right,
                  size: 20,
                  color: Color(AppColors.textPlaceholder),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          const _HintText('临时入口：正式入口是首页「AI 帮我发」（待做）。可随时改，改完再发'),
        ],
      ),
    );
  }
}

/// 表单分段卡片。
///
/// 每段带序号与「已填」标记：§5.4.1 是编号八段，而八段挤在一张连续的白底上
/// 会让用户分不清自己填到第几项。已填标记用矢量勾 + 文字，不用 emoji（§1）。
class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.index,
    required this.title,
    required this.done,
    required this.child,
  });

  /// 段序号。null 表示不属 §5.4.1 编号八段（如模板附加字段段）。
  final int? index;
  final String title;
  final bool done;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: AppSpacing.sm),
      color: const Color(AppColors.surface),
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (index != null) ...[
                Text(
                  '$index',
                  style: TextStyle(
                    fontSize: AppTypeScale.small.size,
                    fontWeight: FontWeight.w600,
                    color: const Color(AppColors.textPlaceholder),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
              ],
              Text(
                title,
                style: TextStyle(
                  fontSize: AppTypeScale.body.size,
                  fontWeight: FontWeight.w600,
                  color: const Color(AppColors.textPrimary),
                ),
              ),
              const Spacer(),
              if (done)
                Icon(
                  Icons.check_circle,
                  size: 16,
                  color: const Color(AppColors.success),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          child,
        ],
      ),
    );
  }
}

/// 第 1 段：分类选择行，选中后回显面包屑（§5.4.1「级联 + 面包屑」）。
class _CategoryRow extends StatelessWidget {
  const _CategoryRow({required this.leafId, required this.onTap});

  final int? leafId;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final path = leafId == null
        ? const <String>[]
        : [for (final n in categoryPathOf(leafId!)) n.name];
    final cert = leafId == null
        ? RequiredCert.none
        : requiredCertForLeaf(leafId!);

    return InkWell(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  path.isEmpty ? '请选择分类' : path.join(' > '),
                  style: TextStyle(
                    fontSize: AppTypeScale.body.size,
                    color: path.isEmpty
                        ? const Color(AppColors.textPlaceholder)
                        : const Color(AppColors.textPrimary),
                  ),
                ),
              ),
              const Icon(
                Icons.chevron_right,
                size: 20,
                color: Color(AppColors.textPlaceholder),
              ),
            ],
          ),
          // 需资质的类目在这里先说一次，用户提交时的拦截才不显得突然（§4.4）
          if (cert != RequiredCert.none) ...[
            const SizedBox(height: AppSpacing.sm),
            _HintText('该分类发布前需完成${cert.label}认证'),
          ],
        ],
      ),
    );
  }
}

/// 第 2 段：位置。
class _LocationRow extends StatelessWidget {
  const _LocationRow({required this.hasLocation, required this.onUseCurrent});

  final bool hasLocation;
  final VoidCallback onUseCurrent;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.place_outlined,
              size: 18,
              color: hasLocation
                  ? const Color(AppColors.primary)
                  : const Color(AppColors.textPlaceholder),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                hasLocation ? _demoLocationLabel : '尚未选择位置',
                style: TextStyle(
                  fontSize: AppTypeScale.body.size,
                  color: hasLocation
                      ? const Color(AppColors.textPrimary)
                      : const Color(AppColors.textPlaceholder),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            OutlinedButton(
              onPressed: hasLocation ? null : onUseCurrent,
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Color(AppColors.primary)),
                foregroundColor: const Color(AppColors.primary),
                shape: const StadiumBorder(),
              ),
              child: Text(
                '使用当前位置',
                style: TextStyle(fontSize: AppTypeScale.small.size),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            OutlinedButton(
              // 禁用而非隐藏：§5.4.1 明列「地图选点」，隐藏后无从确认它是待做还是不做。
              // TODO(高德 Key 到位后)：跳 AppRoutes.mapSelector 并回传真实坐标。
              onPressed: null,
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Color(AppColors.border)),
                shape: const StadiumBorder(),
              ),
              child: Text(
                '地图选点',
                style: TextStyle(fontSize: AppTypeScale.small.size),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        _HintText('可见范围默认 5km；地图选点待地图服务接入'),
      ],
    );
  }
}

/// 第 4 段：价格 + 单位 + 可议价（§5.4.1「模板决定价格单位」）。
class _PriceRow extends StatelessWidget {
  const _PriceRow({
    required this.form,
    required this.controller,
    required this.onPriceChanged,
    required this.onUnitChanged,
    required this.onNegotiableChanged,
  });

  final PublishFormState form;
  final TextEditingController controller;
  final ValueChanged<String> onPriceChanged;
  final ValueChanged<String> onUnitChanged;
  final ValueChanged<bool> onNegotiableChanged;

  @override
  Widget build(BuildContext context) {
    final units = form.template.priceUnits;
    final unit = form.priceUnit ?? units.first;
    // 选了「面议」就不需要数字（§5.8「允许选『面议』不填数字」），
    // 此时把输入框禁掉而不是留着它可填 —— 可填又不算数最让人困惑。
    final needNumber = unit != '面议';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                enabled: needNumber,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: _fieldDecoration(
                  hint: needNumber ? '请输入价格' : '面议无需填写',
                ),
                onChanged: onPriceChanged,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Container(
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              decoration: BoxDecoration(
                color: const Color(AppColors.surface),
                border: Border.all(color: const Color(AppColors.border)),
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: unit,
                  isDense: true,
                  items: [
                    for (final u in units)
                      DropdownMenuItem(
                        value: u,
                        child: Text(
                          u,
                          style: TextStyle(fontSize: AppTypeScale.small.size),
                        ),
                      ),
                  ],
                  onChanged: (v) => v == null ? null : onUnitChanged(v),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: Checkbox(
                value: form.negotiable,
                onChanged: (v) => onNegotiableChanged(v ?? false),
                activeColor: const Color(AppColors.primary),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            GestureDetector(
              onTap: () => onNegotiableChanged(!form.negotiable),
              child: Text(
                // 与「面议」不同：可议价 = 有标价但可谈。两者并存是 §5.4.1
                // 的原样（第 4 段既有单位选项也有「⬜可议价」）。
                '可议价',
                style: TextStyle(
                  fontSize: AppTypeScale.small.size,
                  color: const Color(AppColors.textSecondary),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 模板附加字段的通用渲染（§5.4.3「附加字段」列）。
class _TemplateField extends StatelessWidget {
  const _TemplateField({
    required this.spec,
    required this.value,
    required this.controller,
    required this.onChanged,
  });

  final TemplateFieldSpec spec;
  final String value;

  /// 文本类字段的控制器；[TemplateFieldType.select] 传 null。
  final TextEditingController? controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                spec.label,
                style: TextStyle(
                  fontSize: AppTypeScale.small.size,
                  color: const Color(AppColors.textSecondary),
                ),
              ),
              if (spec.required) ...[
                const SizedBox(width: AppSpacing.xs),
                // 必填标记用文字「必填」而非星号：星号需要图例才知道含义
                Text(
                  '必填',
                  style: TextStyle(
                    fontSize: AppTypeScale.caption.size,
                    color: const Color(AppColors.errorText),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          if (spec.type == TemplateFieldType.select)
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                for (final option in spec.options)
                  ChoiceChip(
                    label: Text(
                      option,
                      style: TextStyle(fontSize: AppTypeScale.small.size),
                    ),
                    selected: option == value,
                    selectedColor: const Color(AppColors.primaryLight),
                    // 再点一次可取消：选错了又没有「清空」入口时，
                    // 用户只能靠换分类来复位。
                    onSelected: (on) => onChanged(on ? option : ''),
                  ),
              ],
            )
          else
            TextField(
              controller: controller,
              keyboardType: spec.type == TemplateFieldType.number
                  ? TextInputType.number
                  : TextInputType.text,
              inputFormatters: spec.type == TemplateFieldType.number
                  ? [FilteringTextInputFormatter.digitsOnly]
                  : null,
              maxLines: spec.type == TemplateFieldType.multiline ? 3 : 1,
              maxLength: spec.maxLength,
              decoration: _fieldDecoration(
                hint: spec.placeholder ?? '',
              ).copyWith(counterText: spec.maxLength == null ? '' : null),
              onChanged: onChanged,
            ),
          if (spec.memoryHint != null) ...[
            const SizedBox(height: AppSpacing.xs),
            // 只显示模板给的示例值，不自称「记忆带入」：真记忆需云端（见文件头）。
            _HintText('示例：${spec.memoryHint}'),
          ],
        ],
      ),
    );
  }
}

/// 第 6 段：媒体上传占位（§5.4.1「0 / 9 · 支持图片/视频」）。
class _MediaPlaceholder extends StatelessWidget {
  const _MediaPlaceholder({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 88,
          decoration: BoxDecoration(
            color: const Color(AppColors.background),
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(
              color: const Color(AppColors.border),
              style: BorderStyle.solid,
            ),
          ),
          alignment: Alignment.center,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.add_photo_alternate_outlined,
                size: 24,
                color: Color(AppColors.textPlaceholder),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                '$count / $kMaxImageCount · 支持图片 / 视频',
                style: TextStyle(
                  fontSize: AppTypeScale.small.size,
                  color: const Color(AppColors.textPlaceholder),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        _HintText('媒体上传待对象存储接入；不影响本页其他字段的发布校验'),
      ],
    );
  }
}

/// 底部主按钮条（§5.4.1 末行「同意协议并发布」+ §5.8「协议未勾选 → Disabled」）。
class _SubmitBar extends StatelessWidget {
  const _SubmitBar({
    required this.agreed,
    required this.blocker,
    required this.onAgreedChanged,
    required this.onSubmit,
  });

  final bool agreed;

  /// 当前阻塞原因，null 表示可提交。
  final PublishBlocker? blocker;
  final ValueChanged<bool> onAgreedChanged;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
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
          Row(
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: Checkbox(
                  value: agreed,
                  onChanged: (v) => onAgreedChanged(v ?? false),
                  activeColor: const Color(AppColors.primary),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: GestureDetector(
                  onTap: () => onAgreedChanged(!agreed),
                  child: Text(
                    '我已阅读并同意发布协议与信息真实性承诺',
                    style: TextStyle(
                      fontSize: AppTypeScale.small.size,
                      color: const Color(AppColors.textSecondary),
                    ),
                  ),
                ),
              ),
            ],
          ),
          // 禁用原因写在按钮上方而不是点了才提示：灰按钮点不动，
          // 「点了才说」这条路径在禁用态根本走不到。
          if (blocker != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              blocker!.message,
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
              onPressed: blocker == null ? onSubmit : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(AppColors.primary),
                foregroundColor: Colors.white,
                disabledBackgroundColor: const Color(AppColors.border),
                disabledForegroundColor: const Color(AppColors.textPlaceholder),
                elevation: 0,
                shape: const StadiumBorder(),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.verified_user_outlined, size: 18),
                  const SizedBox(width: AppSpacing.sm),
                  Text(
                    '同意协议并发布',
                    style: TextStyle(
                      fontSize: AppTypeScale.body.size,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 次要说明文字。
class _HintText extends StatelessWidget {
  const _HintText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: AppTypeScale.caption.size,
        height: AppTypeScale.caption.lineHeight,
        color: const Color(AppColors.textPlaceholder),
      ),
    );
  }
}

/// 输入框统一装饰。
///
/// 参数 [hint] 占位文案；[prefix] 不可编辑前缀（需求态标题用）。
/// 返回与登录页同风格的 [InputDecoration]，避免两页边框不一致。
InputDecoration _fieldDecoration({required String hint, String? prefix}) {
  const border = OutlineInputBorder(
    borderRadius: BorderRadius.all(Radius.circular(AppRadius.md)),
    borderSide: BorderSide(color: Color(AppColors.border)),
  );
  return InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(color: Color(AppColors.textPlaceholder)),
    prefixText: prefix,
    prefixStyle: const TextStyle(
      color: Color(AppColors.primary),
      fontWeight: FontWeight.w600,
    ),
    filled: true,
    fillColor: const Color(AppColors.surface),
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(
      horizontal: AppSpacing.md,
      vertical: AppSpacing.md,
    ),
    border: border,
    enabledBorder: border,
    disabledBorder: border,
    focusedBorder: const OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(AppRadius.md)),
      borderSide: BorderSide(color: Color(AppColors.primary), width: 1.5),
    ),
  );
}
