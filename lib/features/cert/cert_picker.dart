/// 资质挂载选择（发布/编辑窗口的「资质栏」）。
///
/// 口径（帖子凭证方案 R1/R6/R7；2026-10-29 一帖多证）：
///   - 默认不勾选，不阻断发布、不产生 precheck 阻断码；
///   - 候选只列本人已添加（`approved`）的资质，可多选；
///   - 一个都不勾等价于「本次不展示」，故不再单列「本次不展示」选项。
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

/// 发布窗口的资质栏（内联多选）。
class CertMountSection extends ConsumerWidget {
  /// 构造资质栏。
  ///
  /// 参数：
  ///   [certIds] 当前已勾选的资质 ID 集合（空集 = 本次不展示）；
  ///   [onChanged] 勾选变化回调（返回新集合，调用方负责落到表单）；
  ///   [enabled] 是否可交互（提交中禁用）。
  const CertMountSection({
    super.key,
    required this.certIds,
    required this.onChanged,
    this.enabled = true,
  });

  /// 当前已勾选的资质 ID 集合。
  final Set<int> certIds;

  /// 勾选变化回调。
  final ValueChanged<Set<int>> onChanged;

  /// 是否可交互。
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final candidatesAsync = ref.watch(certCandidatesProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '可多选；不影响发布，不选则不展示',
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
                    selected: certIds.contains(item.certId),
                    enabled: enabled,
                    onTap: () => onChanged(_toggle(item.certId)),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  /// 切换某张资质的勾选态。
  ///
  /// 参数：[certId] 资质 ID。
  /// 返回：新集合（保持原有勾选顺序，新增追加在末尾）。
  Set<int> _toggle(int certId) {
    final next = <int>{...certIds};
    if (!next.remove(certId)) {
      next.add(certId);
    }
    return next;
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

/// 候选行（复选框 + 名称）。
class _PickRow extends StatelessWidget {
  /// 构造候选行。
  ///
  /// 参数：[label] 名称；[selected] 是否勾选；
  ///   [enabled] 是否可点；[onTap] 点按回调。
  const _PickRow({
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  /// 名称。
  final String label;

  /// 是否勾选。
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
              selected ? Icons.check_box : Icons.check_box_outline_blank,
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
