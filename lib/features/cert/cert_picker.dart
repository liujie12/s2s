/// 资质挂载选择（发布表单挂载位 + 「我的发布」补挂入口共用）。
///
/// 口径（帖子凭证方案 R1/R6/R7）：
///   - 默认「本次不展示」，不阻断发布、不产生 precheck 阻断码；
///   - 候选只列本人已添加（`approved`）的资质；
///   - 没有候选时不显示「本次不展示」——不选就是等价的表达，多一个同名选项
///     只是多一次点击（原型说明 §7）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_exception.dart';
import '../../design_tokens.dart';
import '../../router/app_router.dart';
import 'cert_models.dart';
import 'cert_repository.dart';

/// 可挂载候选（`approved`）。
final certCandidatesProvider = FutureProvider<List<CertQualification>>((ref) async {
  final status = await ref.watch(certRepositoryProvider).fetchCertStatus();
  return status.attachableQualifications;
});

/// 选证结果：`confirmed=false` 表示用户取消（不改变现状）。
typedef CertPickResult = ({bool confirmed, int? certId});

/// 发布表单的资质挂载位（内联单选）。
class CertMountSection extends ConsumerWidget {
  /// 构造挂载位。
  ///
  /// 参数：
  ///   [certId] 当前选中（null = 本次不展示）；
  ///   [onChanged] 选择变化回调（null 表示不展示）；
  ///   [enabled] 是否可交互（提交中禁用）。
  const CertMountSection({
    super.key,
    required this.certId,
    required this.onChanged,
    this.enabled = true,
  });

  /// 当前选中的资质 ID。
  final int? certId;

  /// 选择变化回调。
  final ValueChanged<int?> onChanged;

  /// 是否可交互。
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final candidatesAsync = ref.watch(certCandidatesProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '不影响发布；默认不展示',
          style: TextStyle(
            fontSize: AppTypeScale.small.size,
            color: const Color(AppColors.textSecondary),
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        candidatesAsync.when(
          loading: () => Text(
            '正在读取你的资质…',
            style: TextStyle(
              fontSize: AppTypeScale.small.size,
              color: const Color(AppColors.textSecondary),
            ),
          ),
          error: (error, _) => _EmptyEntry(
            hint: asApiException(error).uiMessage,
            onAdd: () => _openAddForm(context, ref),
          ),
          data: (items) {
            if (items.isEmpty) {
              return _EmptyEntry(
                hint: '还没有可用的资质',
                onAdd: () => _openAddForm(context, ref),
              );
            }
            return Column(
              children: [
                for (final item in items)
                  _PickRow(
                    label: item.displayName,
                    selected: certId == item.certId,
                    enabled: enabled,
                    onTap: () => onChanged(item.certId),
                  ),
                _PickRow(
                  label: '本次不展示',
                  selected: certId == null,
                  enabled: enabled,
                  onTap: () => onChanged(null),
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  /// 跳「添加资质」表单，返回后刷新候选。
  ///
  /// 参数：[context] 构建上下文；[ref] Provider 容器。
  /// 返回：[Future<void>]。
  static Future<void> _openAddForm(BuildContext context, WidgetRef ref) async {
    final changed = await context.push<bool>(AppRoutes.trustQualification);
    if (changed == true) ref.invalidate(certCandidatesProvider);
  }
}

/// 底部选证面板（「我的发布」补挂用）。
///
/// 参数：
///   [context] 构建上下文；
///   [candidates] 候选资质（调用方已从 [certCandidatesProvider] 取得）。
/// 返回：[CertPickResult]（取消时 `confirmed=false`）。
Future<CertPickResult> showCertPickerSheet(
  BuildContext context, {
  required List<CertQualification> candidates,
}) async {
  final result = await showModalBottomSheet<CertPickResult>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.sm,
            ),
            child: Text(
              '挂哪一张资质',
              style: TextStyle(
                fontSize: AppTypeScale.h3.size,
                fontWeight: FontWeight.w600,
                color: const Color(AppColors.textPrimary),
              ),
            ),
          ),
          for (final item in candidates)
            ListTile(
              title: Text(item.displayName),
              onTap: () => Navigator.pop(
                sheetContext,
                (confirmed: true, certId: item.certId),
              ),
            ),
          ListTile(
            title: const Text('本次不展示'),
            onTap: () => Navigator.pop(
              sheetContext,
              (confirmed: true, certId: null),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ),
    ),
  );
  return result ?? (confirmed: false, certId: null);
}

/// 候选行（单选圆点 + 名称）。
class _PickRow extends StatelessWidget {
  /// 构造候选行。
  ///
  /// 参数：[label] 名称；[selected] 是否选中；
  ///   [enabled] 是否可点；[onTap] 点按回调。
  const _PickRow({
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  /// 名称。
  final String label;

  /// 是否选中。
  final bool selected;

  /// 是否可点。
  final bool enabled;

  /// 点按回调。
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              size: 18,
              color: const Color(AppColors.primary),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: AppTypeScale.body.size,
                  color: const Color(AppColors.textPrimary),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 无候选时的入口行。
class _EmptyEntry extends StatelessWidget {
  /// 构造空态入口。
  ///
  /// 参数：[hint] 提示文案；[onAdd] 去添加资质回调。
  const _EmptyEntry({required this.hint, required this.onAdd});

  /// 提示文案。
  final String hint;

  /// 去添加回调。
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            hint,
            style: TextStyle(
              fontSize: AppTypeScale.small.size,
              color: const Color(AppColors.textSecondary),
            ),
          ),
        ),
        TextButton(
          onPressed: onAdd,
          style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: Size.zero),
          child: Text(
            '去添加资质 ›',
            style: TextStyle(fontSize: AppTypeScale.small.size, color: const Color(AppColors.primary)),
          ),
        ),
      ],
    );
  }
}
