/// 发布页（PRD §5.4.1 八段表单 / §5.7 实现逻辑 / §5.8 边界表，页面 ID：publish-screen）。
///
/// 它是「发布」这条主闭环的入口，也是分类树（条目 [71]）与模板引擎
/// （`domain/publish_template.dart`）的第一个真实消费方。
///
/// **校验不写在本文件**：全部收在 [PublishFormState.blocker]。页面只做两件事 ——
/// 把输入回写进状态、把 blocker 的文案显示出来。这样「填完了按钮还是灰的」
/// 这类问题可以在单测里定位，而不是靠手点复现。唯一的例外是
/// [PublishBlocker.templateLoading]：模板拉取是异步事态，进不了同步 blocker
/// 链，由本页在 [PublishFormState.templatePending] 时合成（[124] B3）。
///
/// **§5.4.1 八段中的降级项，及原因**：
/// ① **第 2 段位置**：「使用当前位置」已接真 —— 从 [locationCenterProvider]
///    取 GCJ-02 坐标写入表单（`POST /posts` 契约要求 `lng`/`lat` 必填，
///    坐标随载荷上送）；「地图选点」（拖图选点）按钮保留但禁用并注明原因
///    —— 隐藏它会让验收时无法判断是漏做还是待前置。
/// ② **第 6 段媒体**：[B2-11] 已由占位转真（见 `media_section.dart`）——
///    选图（`image_picker`）→ OSS 直传 → commit，成功后的 mediaId 进
///    [PublishFormState.mediaIds] 随载荷上送。本轮**仅图片**（视频待单列）。
///
/// **本轮不做的两条产品能力**（说明文档本轮「不做」清单已列）：
/// - **记忆机制**（§5.7）：需云端存「user_id + category_leaf_id」的上次值。
///   模板里已留 `memoryHint` 展示位，本页照常渲染「上次：…」那行版面，
///   但值来自模板常量而非真实历史 —— 文案里不写「记忆带入」以免误认。
/// - **未实名每日 1 条 + 先发后审受限态**（§5.8 首行 / §3.7）：判定与计数都在
///   服务端，客户端自计的次数清缓存即失效，做出来是个假门槛。
///
/// **[B2-8] 三态入口与本地草稿**：
/// - **编辑态**（[PublishScreenArgs.editPostId] 非空）：表单由「我的发布」的
///   卡片经 `GET /posts/{id}` 预填，提交走 `PATCH /posts/{id}`，成功后 `pop(true)`
///   回列表刷新（**不进完成页**）。编辑态联系方式留空（明文不回显，服务端保留
///   原密文），故本地闸门对该态跳过 [PublishBlocker.noContact]。
/// - **重发态**：由「我的发布」经 `POST /posts/{id}/repost` 取草稿预填，属
///   **新建语义**（提交走 `POST /posts`），不传编辑参数。
/// - **本地草稿**（PRD §8.7，见 `draft_store.dart`）：仅新建/重发态启用 ——
///   进入时若本地有草稿则恢复，表单变更 3 秒防抖自动保存，提交成功后清空，
///   退出且未提交则询问「是否保存」。编辑态的连续性由服务端权威数据保证，
///   本地草稿对其无复用价值，故编辑态不存、不恢复草稿。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design_tokens.dart';
import '../../domain/category_tree.dart';
import '../../domain/publish_template.dart';
import '../../core/network/api_exception.dart';
import '../../router/app_router.dart';
import '../auth/auth_repository.dart';
import '../location/location_center.dart';
import '../location/location_permission.dart';
import '../post/post_dto.dart';
import '../post/post_repository.dart';
import 'draft_store.dart';
import 'media_section.dart';
import 'publish_form_state.dart';
import 'publish_screen_args.dart';
import 'publish_template_provider.dart';

/// 已选位置时的展示文案（§5.4.1 第 2 段）。
///
/// 不展示具体地名：本轮无逆地理编码（`address` 不上送，见
/// `PublishFormState.postDraftPayload`），凭空拼一个「XX 小区南门」
/// 会让验收误以为地名解析已接通。
const String _currentLocationLabel = '已使用当前位置';

/// 发布页。
class PublishScreen extends ConsumerStatefulWidget {
  /// 构造发布页。
  ///
  /// 参数：[args] 页面入参（初始表单 + 编辑态信息，见 [PublishScreenArgs]）。
  ///   生产由路由经 `extra` 透传；不传则为一张空白新建表单。
  const PublishScreen({super.key, this.args = const PublishScreenArgs()});

  /// 页面入参（新建/重发/编辑三态共用）。
  final PublishScreenArgs args;

  @override
  ConsumerState<PublishScreen> createState() => _PublishScreenState();
}

class _PublishScreenState extends ConsumerState<PublishScreen> {
  late PublishFormState _form = widget.args.initialForm;

  final TextEditingController _titleCtrl = TextEditingController();
  final TextEditingController _priceCtrl = TextEditingController();
  final TextEditingController _descCtrl = TextEditingController();
  final TextEditingController _contactCtrl = TextEditingController();

  /// 模板文本类字段的控制器，key 同 [TemplateFieldSpec.key]。
  ///
  /// 按需创建而非随模板一次性建好：换分类会换掉整组字段，
  /// 预建的控制器在新模板里无人使用，dispose 时也容易漏。
  final Map<String, TextEditingController> _templateCtrls = {};

  /// 草稿自动保存的防抖计时器（仅新建/重发态启用；见文件头）。
  Timer? _autosaveTimer;

  /// 本次提交是否已成功（成功后不再触发退出保存询问、不再自动保存）。
  bool _submitted = false;

  /// 编辑目标帖子 ID；null 表示新建/重发态。
  int? get _editPostId => widget.args.editPostId;

  /// 是否处于编辑态（提交走 `PATCH /posts/{id}`）。
  bool get _isEditing => _editPostId != null;

  @override
  void initState() {
    super.initState();
    // 用初始表单回填文本控制器：新建态为空白、重发/编辑态为预填内容。
    // 缺了这一步，预填表单的标题/价格等虽在状态里，输入框却是空的
    //（历史只把状态与控制器分离在「用户输入」路径上同步）。
    _syncControllersFromForm();
    // 新建/重发态尝试恢复本地草稿（编辑态不恢复，见文件头）。
    if (!_isEditing) {
      unawaited(_restoreDraftIfAny());
    }
  }

  @override
  void dispose() {
    _autosaveTimer?.cancel();
    _titleCtrl.dispose();
    _priceCtrl.dispose();
    _descCtrl.dispose();
    _contactCtrl.dispose();
    for (final c in _templateCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// 把当前表单回填到各文本控制器（仅初始一次性，不做双向绑定）。
  ///
  /// 返回：void。
  void _syncControllersFromForm() {
    _titleCtrl.text = _form.title;
    _priceCtrl.text = _form.priceText;
    _descCtrl.text = _form.description;
    _contactCtrl.text = _form.contact;
  }

  /// 更新表单并登记草稿自动保存（所有表单变更的统一入口）。
  ///
  /// 参数：[next] 新表单快照。
  /// 返回：void。
  void _updateForm(PublishFormState next) {
    setState(() => _form = next);
    _scheduleAutosave();
  }

  /// 登记一次草稿自动保存（3 秒防抖；编辑态不存草稿）。
  ///
  /// 返回：void。
  void _scheduleAutosave() {
    if (_isEditing) return;
    _autosaveTimer?.cancel();
    _autosaveTimer = Timer(kDraftAutosaveInterval, () {
      unawaited(ref.read(draftStoreProvider).save(DraftSnapshot.of(_form)));
    });
  }

  /// 进入发布页时若本地有草稿则恢复（仅新建/重发态调用）。
  ///
  /// 返回：[Future<void>]；无草稿则不动作。
  Future<void> _restoreDraftIfAny() async {
    final snapshot = await ref.read(draftStoreProvider).load();
    if (!mounted || snapshot == null) return;
    setState(() {
      _form = snapshot.form;
      _titleCtrl.text = snapshot.form.title;
      _priceCtrl.text = snapshot.form.priceText;
      _descCtrl.text = snapshot.form.description;
      _contactCtrl.text = snapshot.form.contact;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已恢复上次未发布的草稿')),
    );
  }

  /// 表单是否含有值得保存的内容（决定退出时是否弹「是否保存」）。
  ///
  /// 返回：[bool]；全空表单（用户只是打开又退出）不弹问。
  bool _hasDraftContent() {
    final f = _form;
    return f.leafCategoryId != null ||
        f.title.trim().isNotEmpty ||
        f.description.trim().isNotEmpty ||
        f.contact.trim().isNotEmpty ||
        f.mediaIds.isNotEmpty ||
        f.lng != null ||
        f.lat != null ||
        f.templateValues.values.any((v) => v.trim().isNotEmpty);
  }

  /// 处理返回/退出：未提交且有内容时询问是否保存草稿，再退出。
  ///
  /// 返回：[Future<void>]。
  Future<void> _handleExit() async {
    final router = GoRouter.of(context);

    if (_isEditing || _submitted || !_hasDraftContent()) {
      _autosaveTimer?.cancel();
      router.canPop() ? router.pop() : router.go(AppRoutes.home);
      return;
    }

    final keep = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        content: const Text('有未发布草稿，是否保存？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('不保存'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    _autosaveTimer?.cancel();
    if (keep == true) {
      await ref.read(draftStoreProvider).save(DraftSnapshot.of(_form));
    } else {
      await ref.read(draftStoreProvider).clear();
    }
    if (!mounted) return;
    router.canPop() ? router.pop() : router.go(AppRoutes.home);
  }

  /// 组装按钮闸门（模板异步闸门优先，编辑态跳过发布仪式闸门）。
  ///
  /// 返回：[PublishBlocker?]；null 表示可提交。
  PublishBlocker? _effectiveBlocker() {
    final base = _form.templatePending
        ? PublishBlocker.templateLoading
        : _form.blocker;
    if (!_isEditing) return base;
    // 编辑态跳过两条「发布仪式」闸门，否则编辑既有帖会被本地拦死在提交前：
    // - noContact：明文不回显，编辑不改联系方式时输入框本应为空
    //   （服务端按「空 = 保留原密文」处理，见文件头）；
    // - agreementUnchecked：该帖当初已按协议发布，编辑不要求重勾。
    if (base == PublishBlocker.noContact ||
        base == PublishBlocker.agreementUnchecked) {
      return null;
    }
    return base;
  }

  /// 当前是否可提交（含编辑态联系方式豁免）。
  bool get _canSubmit => _effectiveBlocker() == null;

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
    _scheduleAutosave();
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
    _updateForm(
      _form.copyWith(templateValues: {..._form.templateValues, key: value}),
    );
  }

  /// 提交发布（§5.5 S6 / §5.8「强制认证拦截」/ §12.3 precheck）。
  ///
  /// 顺序：本地必填闸门 → 登录引导 → 本地资质拦截 → 服务端 precheck
  ///（[124] B4，提前暴露服务端口径阻断项）→ 通过后进完成页
  ///（正式 `POST /posts` 为 B5 接线）。
  Future<void> _submit() async {
    if (!_canSubmit || _precheckInFlight) return;
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

    // [124] B4：提交前 precheck。填完长表单才在 POST /posts 被打回是
    // 最挫败的路径；precheck 把服务端口径（敏感词/图片/禁发/资质/
    // 未实名上限）提前到提交前，blocks 一次性给全不逐条打断。
    setState(() => _precheckInFlight = true);
    // 单一出口：成功、阻断、传输错、乃至任何未预期异常，都必须在 finally 里
    // 复位 [_precheckInFlight]。历史缺陷：precheck 段的 try 没有 finally，
    // 一旦 precheck 抛出非 ApiException，标志便永不归位——发布按钮被永久禁用
    // 且不显示任何原因（用户侧表现为「点了没反应」）。
    try {
      final result = await ref
          .read(postRepositoryProvider)
          .precheck(_form.postDraftPayload());
      if (!mounted) return;
      if (!result.passed) {
        await _showPrecheckBlocks(result.blocks);
        return;
      }

      // [125] B5 / [B2-8]：正式提交。precheck 与写接口之间的时间差内服务端
      // 口径可能变化（如审核策略调整），仍可能回发布阻断五码——按同款弹层
      // 处理（复用动作入口），其余错误按 §11.4 提示。
      // 编辑态走 PATCH（须带 version，contact 留空 = 保留原密文）；
      // 新建/重发态走 POST。两者回执字段子集同构（PostCreatedDto）。
      try {
        if (_isEditing) {
          await ref.read(postRepositoryProvider).updatePost(
                _editPostId!,
                <String, Object?>{
                  ..._form.postDraftPayload(),
                  'version': widget.args.editVersion,
                },
              );
        } else {
          await ref
              .read(postRepositoryProvider)
              .createPost(_form.postDraftPayload());
        }
      } on ApiException catch (error) {
        if (!mounted) return;
        if (_isPublishBlockCode(error.code.code)) {
          await _showPrecheckBlocks([
            PrecheckBlockDto(code: error.code.code, message: error.message),
          ]);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(error.uiMessage)),
          );
        }
        return;
      }

      // TODO([130] 埋点队列)：post_published 事件入队（事件体 interaction_id
      // 取本次提交交互、ts 取此刻毫秒精度）；队列与上报实现属 [130]，
      // 本轮只留调用点，不引入 TrackReporter 依赖。

      // 提交已成功：置位以关闭退出二次确认，并撤销待触发的自动保存。
      _submitted = true;
      _autosaveTimer?.cancel();
      if (!_isEditing) {
        // 草稿已被本次发布消费，清掉避免下次进页面又被恢复。
        await ref.read(draftStoreProvider).clear();
      }
      if (!mounted) return;
      if (_isEditing) {
        // 编辑成功回「我的发布」并刷新（pop(true)），**不进完成页** ——
        // 完成页是「新发布」的闭环，编辑没有「发布成功」这一步。
        router.canPop() ? router.pop(true) : router.go(AppRoutes.myPublish);
      } else {
        // 发布成功进完成页（带上表单快照供完成页算 §9.8 档位）。
        router.push(AppRoutes.publishSuccess, extra: _form);
      }
    } on ApiException catch (error) {
      // precheck 链路失败（传输/信封错误）与「校验不通过」是两种语义：
      // 后者在 blocks 里（上方弹层），前者按 §11.4 唯一格式提示，
      // 不静默进完成页。
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.uiMessage)),
        );
      }
    } finally {
      if (mounted) setState(() => _precheckInFlight = false);
    }
  }

  /// 是否为发布阻断五码（40901/40902/40302/40303/40304，§12.5）。
  ///
  /// precheck 的 blocks 与 POST 的错误码共用这五码语义，POST 侧收到
  /// 时复用阻断弹层（含 40302/40304 动作入口）。
  ///
  /// 参数 [code] 信封错误码数值。
  /// 返回：[bool] 五码之一为 true。
  bool _isPublishBlockCode(int code) =>
      code == 40901 || code == 40902 || code == 40302 || code == 40303 || code == 40304;

  /// precheck 进行中标志（防重入）：网络往返期间主按钮仍可点，
  /// 双发请求虽无害（不写库）但会弹两次结果，且用户无从知道第一次
  /// 还在路上。
  bool _precheckInFlight = false;

  /// 弹出 precheck 阻断项列表（[124] B4）。
  ///
  /// 参数 [blocks] 服务端一次性给全的阻断项（契约语义「不逐条打断
  /// 用户」—— 这里也一次性列全，不逐条弹）。
  /// 返回：[Future]，弹层关闭时完成。
  Future<void> _showPrecheckBlocks(List<PrecheckBlockDto> blocks) {
    return showModalBottomSheet<void>(
      context: context,
      builder: (_) => _PrecheckSheet(blocks: blocks),
    );
  }

  /// 采集当前位置写入表单（§5.4.1 第 2 段「使用当前位置」）。
  ///
  /// 坐标取自 [locationCenterProvider]（地图侧已取到的定位中心，GCJ-02），
  /// 一次写入 [PublishFormState.lng]/[PublishFormState.lat] —— 位置是否就绪
  /// 以坐标为准（见 `PublishFormState.hasLocation`）。
  ///
  /// **为什么先判权限**：该 Provider 在从未取到真实定位时停在默认城市中心，
  /// 直接拿它当用户位置发布等于伪造一条坐标。故仅在定位已授权时采集；
  /// 未授权时提示先开启，而不是塞一个假点把 [PublishBlocker.noLocation] 蒙过去。
  void _useCurrentLocation() {
    if (ref.read(locationPermissionProvider) != LocationPermissionPhase.granted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先开启定位权限，再使用当前位置')),
      );
      return;
    }
    final center = ref.read(locationCenterProvider);
    _updateForm(_form.copyWith(lng: center.lng, lat: center.lat));
  }

  @override
  Widget build(BuildContext context) {
    // [124] B3：watch 服务端模板，数据到达后回写表单。不用 ref.listen ——
    // WidgetRef.listen 无 fireImmediately，family 缓存命中（再次进入发布页
    // 选同一叶子）时 provider 已是 data、不再有「下一次变化」，loadedTemplate
    // 会永远等不到。watch 在每次 build 核对一次：有数据且未回写则帧后
    // setState（build 中不可 setState）；已回写（同一实例）不再调度。
    final leafId = _form.leafCategoryId;
    if (leafId != null) {
      ref
          .watch(publishTemplateProvider(leafId))
          .whenData((template) {
            if (_form.loadedTemplate == template) return;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _form.loadedTemplate != template) {
                setState(() => _form = _form.withTemplate(template));
              }
            });
          });
    }

    final template = _form.template;
    // 提交闸门（模板异步闸门优先；编辑态另跳过发布仪式闸门）——唯一真源在
    // [_effectiveBlocker]，本页不再就地拼一次（两处拼装必然漂移）。
    final blocker = _effectiveBlocker();

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
          // 返回走 _handleExit：未提交且有内容时先问「是否保存草稿」（§8.7）。
          onPressed: _handleExit,
        ),
        title: Text(
          // 编辑态标题为「编辑」：同一张表单承载新建/重发/编辑三态，
          // 标题是用户判断「我这次到底在干什么」的唯一线索（[B2-8]）。
          _isEditing ? '编辑' : '发布',
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
            // precheck 进行中同样禁用（防重入，见 _precheckInFlight 注释）
            onPressed: _canSubmit && !_precheckInFlight ? _submit : null,
            child: Text(
              // 编辑态主按钮为「保存」：提交语义是更新而非新发布。
              _isEditing ? '保存' : '发布',
              style: TextStyle(
                fontSize: AppTypeScale.body.size,
                fontWeight: FontWeight.w600,
                color: _canSubmit
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
            onChanged: (k) => _updateForm(_form.copyWith(kind: k)),
          ),
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
              onUseCurrent: _useCurrentLocation,
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
              onChanged: (v) => _updateForm(_form.copyWith(title: v)),
            ),
          ),
          _SectionCard(
            index: 4,
            title: '价格',
            done: _form.priceSettled,
            child: _PriceRow(
              form: _form,
              controller: _priceCtrl,
              onPriceChanged: (v) => _updateForm(_form.copyWith(priceText: v)),
              onUnitChanged: (u) => _updateForm(_form.copyWith(priceUnit: u)),
              onNegotiableChanged: (v) =>
                  _updateForm(_form.copyWith(negotiable: v)),
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
                  onChanged: (v) => _updateForm(_form.copyWith(description: v)),
                ),
                const SizedBox(height: AppSpacing.xs),
                // 字数提示只提示不拦截（§5.4.1 写的是「建议 30-200 字」）
                _HintText(_form.descriptionHint),
              ],
            ),
          ),
          // 模板附加字段（§5.4.3「附加字段」列）。通用模板无附加字段，
          // 此段自然不出现 —— 空标题的空卡片比不显示更让人以为是加载失败。
          // [124] B3：模板加载中渲染骨架（§5.6 loading 骨架屏而非转圈），
          // 此时不渲染本地字段 —— 服务端字段集合一到就整体替换，用户
          // 在本地字段上的输入可能落进不复存在的键。
          if (_form.templatePending)
            const _SectionCard(
              index: null,
              title: '分类专属信息',
              done: false,
              child: _TemplateFieldsSkeleton(),
            )
          else if (template.extraFields.isNotEmpty)
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
            done: _form.imageCount > 0,
            child: MediaSection(
              onChanged: (ids) => _updateForm(_form.copyWith(mediaIds: ids)),
            ),
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
              onChanged: (v) => _updateForm(_form.copyWith(contact: v)),
            ),
          ),
        ],
      ),
      bottomNavigationBar: _SubmitBar(
        agreed: _form.agreed,
        blocker: blocker,
        onAgreedChanged: (v) => _updateForm(_form.copyWith(agreed: v)),
        // null 表示提交链路进行中（precheck 网络往返），与 blocker 禁用
        // 同效但不出禁用文案 —— 期间文案继续显示「差什么」没有意义。
        onSubmit: _precheckInFlight ? null : _submit,
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
                hasLocation ? _currentLocationLabel : '尚未选择位置',
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
              // 高德 Key 已配置（[149] 后），缺的是拖图选点页（mapSelector 路由）本身。
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
        _HintText('可见范围默认 5km；「地图选点」（拖图微调）待接入'),
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

/// 模板字段加载中的骨架占位（[124] B3，§5.6「loading 骨架屏，首屏不转圈」）。
///
/// 两行「标签条 + 输入框条」示意字段版面，不渲染真实字段控件 —— 服务端
/// 字段集合到达后整体替换，此时可输入的控件会让值落进不复存在的键。
class _TemplateFieldsSkeleton extends StatelessWidget {
  const _TemplateFieldsSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < 2; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 72,
                  height: 12,
                  color: const Color(AppColors.background),
                ),
                const SizedBox(height: AppSpacing.sm),
                Container(
                  height: 48,
                  decoration: BoxDecoration(
                    color: const Color(AppColors.background),
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 第 6 段媒体已由占位转真，见 `media_section.dart`（[B2-11]）。

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

  /// 提交回调；null 表示提交链路进行中（precheck 防重入），按钮禁用。
  final VoidCallback? onSubmit;

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
              // blocker 存在按原禁用语义；onSubmit 为 null 是提交进行中
              onPressed: blocker == null && onSubmit != null
                  ? onSubmit
                  : null,
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

/// precheck 阻断项弹层（[124] B4，§12.3「blocks[] 一次性给全」的呈现侧）。
///
/// 每项展示服务端 [PrecheckBlockDto.message]（契约「可直接呈现的中文
/// 提示」，逐字照贴不重写——文案口径在服务端，客户端重写会出现两套
/// 说法）。五码中两码带动作入口（PRD §12.5）：40302「去认证」、
/// 40304「去实名」，其余码只陈述（40901 改文案、40902 本轮无媒体不
/// 出现、40303 禁发无出口）。
class _PrecheckSheet extends StatelessWidget {
  const _PrecheckSheet({required this.blocks});

  /// 服务端一次性给全的阻断项。
  final List<PrecheckBlockDto> blocks;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.lg,
          AppSpacing.lg,
          AppSpacing.md,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '发布前需处理以下问题',
              style: TextStyle(
                fontSize: AppTypeScale.h3.size,
                fontWeight: FontWeight.w600,
                color: const Color(AppColors.textPrimary),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            for (final block in blocks)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.md),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 18,
                      color: const Color(AppColors.warningText),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        block.message,
                        style: TextStyle(
                          fontSize: AppTypeScale.body.size,
                          height: AppTypeScale.body.lineHeight,
                          color: const Color(AppColors.textPrimary),
                        ),
                      ),
                    ),
                    if (_actionRouteOf(block) != null)
                      Padding(
                        padding: const EdgeInsets.only(left: AppSpacing.sm),
                        child: TextButton(
                          // 关弹层再跳：sheet 挂在 root navigator 上，
                          // 不关直接 push 会叠在弹层下面
                          onPressed: () {
                            Navigator.of(context).pop();
                            GoRouter.of(context).push(_actionRouteOf(block)!);
                          },
                          child: Text(
                            _actionLabelOf(block),
                            style: const TextStyle(
                              color: Color(AppColors.primary),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: AppSpacing.sm),
            SizedBox(
              height: 44,
              child: OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('知道了'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 五码 → 动作路由映射（[124] B4 唯一实现处；PRD §12.5 客户端行为列）。
  ///
  /// 参数 [block] 阻断项。
  /// 返回：[String?] 路由路径；无动作码（40901/40902/40303）为 null。
  String? _actionRouteOf(PrecheckBlockDto block) {
    return switch (block.code) {
      40302 => AppRoutes.trust, // 高敏未认证 → 信任与认证中心
      40304 => AppRoutes.trust, // 未实名上限 → 同上（实名在认证中心）
      _ => null,
    };
  }

  /// 五码 → 动作按钮文案。
  ///
  /// 参数 [block] 阻断项。
  /// 返回：[String] 按钮文案（仅 [_actionRouteOf] 非 null 的码会取到）。
  String _actionLabelOf(PrecheckBlockDto block) {
    return switch (block.code) {
      40302 => '去认证',
      40304 => '去实名',
      _ => '',
    };
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
