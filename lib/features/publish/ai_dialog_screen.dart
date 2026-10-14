/// 模式③ 对话式一问一答（PRD §5.9「每屏 1 问，新手首选用」）。
///
/// **口径裁定（2026-10-14，用户）**：
/// - **问哪些**：只问必填，8 问 —— 类型 → 分类 → 位置 → 标题 → 价格 → 描述 →
///   联系方式 → 协议勾选（对齐 §5.4.1 必填顺序与 [PublishBlocker] 顺序）；
/// - **问完去哪**：进 `ai-confirm-screen`（§5.9「四模式共用确认页」），由 AI 补全
///   其余字段并逐项核对；
/// - **导航**：可「上一步」；必答项未答不允许进入下一问（与发布页主按钮禁用同一取向）。
///
/// **为什么复用 [PublishFormState] 累积答案**：本模式与发布页填的是同一份表单，
/// 最后交给同一个确认页与同一套校验。另立一套「问答态」模型会让两处校验漂移。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design_tokens.dart';
import '../../domain/category_tree.dart';
import '../../router/app_router.dart';
import '../location/location_center.dart';
import '../location/location_permission.dart';
import 'ai_confirm_args.dart';
import 'publish_form_state.dart';

/// 八个必答步骤（顺序即 §5.4.1 必填顺序）。
enum _DialogStep {
  /// 类型：资源 / 需求。
  kind,

  /// 分类（三级叶子）。
  category,

  /// 位置（坐标）。
  location,

  /// 标题。
  title,

  /// 价格与单位。
  price,

  /// 描述。
  description,

  /// 联系方式。
  contact,

  /// 协议勾选。
  agreement,
}

/// 步骤展示属性。
extension on _DialogStep {
  /// 提问文案（新手引导语气）。
  String get question => switch (this) {
    _DialogStep.kind => '你想发布什么？',
    _DialogStep.category => '它属于哪个分类？',
    _DialogStep.location => '大概在哪儿？',
    _DialogStep.title => '一句话说清它是什么',
    _DialogStep.price => '价格怎么算？',
    _DialogStep.description => '还有什么要补充的？',
    _DialogStep.contact => '别人怎么联系你？',
    _DialogStep.agreement => '确认并同意协议',
  };

  /// 追问副文案（为什么问这一项）。
  String get hint => switch (this) {
    _DialogStep.kind => '决定这条信息是「提供」还是「寻找」',
    _DialogStep.category => '分类决定要填哪些字段，选到第三级最准',
    _DialogStep.location => '只会显示大概范围，不会暴露门牌号',
    _DialogStep.title => '越具体，附近的人越容易搜到',
    _DialogStep.price => '不确定可以选「面议」',
    _DialogStep.description => '写清细节能少一堆来回问答',
    _DialogStep.contact => '只有想联系你的人才会看到',
    _DialogStep.agreement => '勾选后才能发布',
  };
}

/// 模式③ 对话式引导页。
class AiDialogScreen extends ConsumerStatefulWidget {
  /// 构造引导页。
  const AiDialogScreen({super.key});

  @override
  ConsumerState<AiDialogScreen> createState() => _AiDialogScreenState();
}

class _AiDialogScreenState extends ConsumerState<AiDialogScreen> {
  /// 累积的表单（与发布页同一份模型）。
  PublishFormState _form = const PublishFormState();

  /// 当前步骤下标（0..7）。
  int _index = 0;

  final TextEditingController _titleCtrl = TextEditingController();
  final TextEditingController _priceCtrl = TextEditingController();
  final TextEditingController _descCtrl = TextEditingController();
  final TextEditingController _contactCtrl = TextEditingController();

  /// 步骤总数（8 问）。
  static const int _stepCount = 8;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _priceCtrl.dispose();
    _descCtrl.dispose();
    _contactCtrl.dispose();
    super.dispose();
  }

  /// 当前步骤。
  _DialogStep get _step => _DialogStep.values[_index];

  /// 当前步骤是否已答（决定「下一步」是否可点）。
  ///
  /// 返回：[bool] 是否满足进入下一问的条件。
  bool get _answered => switch (_step) {
    // 类型恒有默认值（supply），无需额外条件
    _DialogStep.kind => true,
    _DialogStep.category => _form.leafCategoryId != null,
    _DialogStep.location => _form.hasLocation,
    _DialogStep.title => _form.title.trim().isNotEmpty,
    _DialogStep.price => _form.priceSettled,
    _DialogStep.description => _form.description.trim().isNotEmpty,
    _DialogStep.contact => _form.contact.trim().isNotEmpty,
    _DialogStep.agreement => _form.agreed,
  };

  /// 前进一问；末问则进确认页。
  ///
  /// 返回：[Future] 完成信号。
  Future<void> _next() async {
    if (!_answered) return;
    if (_index < _stepCount - 1) {
      setState(() => _index++);
      return;
    }
    // 末问：把答案交给四模式共用的确认页（§5.9）。
    await context.push<void>(
      AppRoutes.aiConfirm,
      extra: AiConfirmArgs(form: _form),
    );
  }

  /// 回上一问（首问退回上一页）。
  void _prev() {
    if (_index == 0) {
      GoRouter.of(context).pop();
      return;
    }
    setState(() => _index--);
  }

  /// 选分类（复用全屏级联模态，返回叶子 ID）。
  Future<void> _pickCategory() async {
    final leafId = await context.push<int>(
      AppRoutes.categorySelector,
      extra: _form.leafCategoryId,
    );
    if (leafId == null || !mounted) return;
    setState(() => _form = _form.withCategory(leafId));
  }

  /// 采集当前位置（与发布页同一口径：定位未授权不塞假点）。
  void _useCurrentLocation() {
    if (ref.read(locationPermissionProvider) != LocationPermissionPhase.granted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先开启定位权限，再使用当前位置')),
      );
      return;
    }
    final center = ref.read(locationCenterProvider);
    setState(() => _form = _form.copyWith(lng: center.lng, lat: center.lat));
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
          icon: const Icon(Icons.arrow_back, color: Color(AppColors.textPrimary)),
          onPressed: _prev,
        ),
        title: Text(
          '第 ${_index + 1} / $_stepCount 问',
          style: TextStyle(
            fontSize: AppTypeScale.body.size,
            color: const Color(AppColors.textSecondary),
          ),
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LinearProgressIndicator(
            value: (_index + 1) / _stepCount,
            minHeight: 3,
            backgroundColor: const Color(AppColors.border),
            valueColor: const AlwaysStoppedAnimation(Color(AppColors.primary)),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(AppSpacing.xl),
              children: [
                Text(
                  _step.question,
                  style: TextStyle(
                    fontSize: AppTypeScale.h2.size,
                    fontWeight: FontWeight.w600,
                    color: const Color(AppColors.textPrimary),
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  _step.hint,
                  style: TextStyle(
                    fontSize: AppTypeScale.small.size,
                    color: const Color(AppColors.textSecondary),
                  ),
                ),
                const SizedBox(height: AppSpacing.xl),
                _buildStepBody(),
              ],
            ),
          ),
          _BottomBar(
            answered: _answered,
            isLast: _index == _stepCount - 1,
            onPrev: _prev,
            onNext: _next,
          ),
        ],
      ),
    );
  }

  /// 当前步骤的作答区。
  ///
  /// 返回：[Widget] 该问的输入控件。
  Widget _buildStepBody() {
    switch (_step) {
      case _DialogStep.kind:
        return Column(
          children: [
            for (final kind in PublishKind.values)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: _ChoiceCard(
                  label: kind == PublishKind.supply ? '我有资源要发布' : '我需要找点什么',
                  selected: _form.kind == kind,
                  onTap: () => setState(() => _form = _form.copyWith(kind: kind)),
                ),
              ),
          ],
        );
      case _DialogStep.category:
        final leafId = _form.leafCategoryId;
        // categoryPathLabel 返回可空（未知 ID 时无路径），此处兜底为提示文案。
        final String path =
            leafId == null ? '选择分类' : (categoryPathLabel(leafId) ?? '选择分类');
        return _ChoiceCard(
          label: path,
          selected: leafId != null,
          onTap: _pickCategory,
        );
      case _DialogStep.location:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ChoiceCard(
              label: _form.hasLocation ? '已获取当前位置' : '使用当前位置',
              selected: _form.hasLocation,
              onTap: _useCurrentLocation,
            ),
          ],
        );
      case _DialogStep.title:
        return TextField(
          controller: _titleCtrl,
          maxLength: 30,
          autofocus: true,
          onChanged: (v) => setState(() => _form = _form.copyWith(title: v)),
          decoration: const InputDecoration(
            hintText: '例如：九成新实木餐桌',
            border: OutlineInputBorder(),
          ),
        );
      case _DialogStep.price:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _priceCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              onChanged: (v) =>
                  setState(() => _form = _form.copyWith(priceText: v)),
              decoration: InputDecoration(
                hintText: '填数字，或选「面议」',
                border: const OutlineInputBorder(),
                suffixText: _form.priceUnit,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                for (final unit in _form.template.priceUnits)
                  _Chip(
                    label: unit,
                    selected: _form.priceUnit == unit,
                    onTap: () =>
                        setState(() => _form = _form.copyWith(priceUnit: unit)),
                  ),
              ],
            ),
          ],
        );
      case _DialogStep.description:
        return TextField(
          controller: _descCtrl,
          maxLines: 5,
          onChanged: (v) =>
              setState(() => _form = _form.copyWith(description: v)),
          decoration: const InputDecoration(
            hintText: '例如：搬家出售，无磕碰，可上门自取',
            border: OutlineInputBorder(),
          ),
        );
      case _DialogStep.contact:
        return TextField(
          controller: _contactCtrl,
          keyboardType: TextInputType.phone,
          onChanged: (v) => setState(() => _form = _form.copyWith(contact: v)),
          decoration: const InputDecoration(
            hintText: '手机号',
            border: OutlineInputBorder(),
          ),
        );
      case _DialogStep.agreement:
        return _ChoiceCard(
          label: '我已阅读并同意《用户协议》与《隐私政策》',
          selected: _form.agreed,
          onTap: () => setState(() => _form = _form.copyWith(agreed: !_form.agreed)),
        );
    }
  }
}

/// 单选卡片（类型 / 分类 / 位置 / 协议四问共用）。
class _ChoiceCard extends StatelessWidget {
  const _ChoiceCard({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.lg),
        decoration: BoxDecoration(
          color: selected
              ? const Color(AppColors.primaryLight)
              : const Color(AppColors.surface),
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(
            color: selected
                ? const Color(AppColors.primary)
                : const Color(AppColors.border),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: AppTypeScale.body.size,
                  // 浅青底文字取色规则（PRD §1.4）：只能用 primary-dark / text-primary
                  color: selected
                      ? const Color(AppColors.textPrimary)
                      : const Color(AppColors.textSecondary),
                ),
              ),
            ),
            if (selected)
              const Icon(Icons.check, size: 18, color: Color(AppColors.primary)),
          ],
        ),
      ),
    );
  }
}

/// 价格单位选项片。
class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.full),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: selected
              ? const Color(AppColors.primaryLight)
              : const Color(AppColors.surface),
          borderRadius: BorderRadius.circular(AppRadius.full),
          border: Border.all(
            color: selected
                ? const Color(AppColors.primary)
                : const Color(AppColors.border),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: AppTypeScale.small.size,
            color: const Color(AppColors.textPrimary),
          ),
        ),
      ),
    );
  }
}

/// 底部「上一步 / 下一步」栏。
class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.answered,
    required this.isLast,
    required this.onPrev,
    required this.onNext,
  });

  final bool answered;
  final bool isLast;
  final VoidCallback onPrev;
  final Future<void> Function() onNext;

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
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 48,
              child: OutlinedButton(
                onPressed: onPrev,
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(AppColors.border)),
                  shape: const StadiumBorder(),
                ),
                child: Text(
                  '上一步',
                  style: TextStyle(
                    fontSize: AppTypeScale.body.size,
                    color: const Color(AppColors.textSecondary),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            flex: 2,
            child: SizedBox(
              height: 48,
              child: ElevatedButton(
                onPressed: answered ? () => onNext() : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(AppColors.primary),
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: const Color(AppColors.border),
                  disabledForegroundColor: const Color(AppColors.textPlaceholder),
                  elevation: 0,
                  shape: const StadiumBorder(),
                ),
                child: Text(
                  isLast ? '开始识别并发布' : '下一步',
                  style: TextStyle(
                    fontSize: AppTypeScale.body.size,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
