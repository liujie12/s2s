/// 条件改值与追加（R8 / R9 / R10）。
///
/// 所有写入都经 `SearchConditionsNotifier`：编辑层只负责收集输入，
/// 不自己判断「该写哪个源」，否则搜索态下会写错源。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design_tokens.dart';
import '../../domain/listing_category.dart';
import 'condition_slots.dart';
import 'discovery_filter.dart';
import 'effective_filter.dart';
import 'effective_filter_provider.dart';
import 'search_conditions.dart';
import 'search_intent.dart';

/// 打开某枚 chip 的改值层。
///
/// 参数：[context] 页面上下文；[ref] 供门面与投影读取；[chip] 被点开的 chip。
/// 返回：[Future] 关闭信号。
Future<void> showConditionEditor(
  BuildContext context,
  WidgetRef ref,
  ConditionChip chip,
) async {
  switch (chip.slot) {
    case ConditionSlot.radius:
      await _showRadiusSheet(context, ref);
    case ConditionSlot.supplyDemand:
      await _showSupplySheet(context, ref);
    case ConditionSlot.price:
      await _showPriceSheet(context, ref);
    case ConditionSlot.category:
      await showCategorySheet(context, ref);
    case ConditionSlot.community:
      await _showCommunitySheet(context, ref);
    case ConditionSlot.anchor:
      // 地点没有改值入口：只能重新说一句或删除（Scope Boundaries）。
      break;
  }
}

/// 打开「＋ 条件」追加层。
///
/// 参数：[context] 页面上下文；[ref] 门面读取；返回：[Future] 关闭信号。
Future<void> showAddConditionSheet(BuildContext context, WidgetRef ref) async {
  final effective = ref.read(effectiveFilterProvider);
  await showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SheetTitle('追加条件'),
          for (final ConditionSlot slot in const [
            ConditionSlot.radius,
            ConditionSlot.category,
            ConditionSlot.supplyDemand,
            ConditionSlot.price,
          ])
            ListTile(
              dense: true,
              title: Text(_slotTitle(slot), style: _bodyStyle()),
              subtitle: Text(
                _slotValue(slot, effective),
                style: _captionStyle(),
              ),
              onTap: () {
                Navigator.of(sheetContext).pop();
                showConditionEditor(context, ref, _chipOf(slot, effective));
              },
            ),
        ],
      ),
    ),
  );
}

/// 半屏类目选择器：一级多选 + 确认（KTD6）。
///
/// 点为遮罩收起等于放弃未确认改动；已有结果保留在门面里，不会被清空。
///
/// 参数：[context] 页面上下文；[ref] 门面读取；返回：[Future] 关闭信号。
Future<void> showCategorySheet(BuildContext context, WidgetRef ref) async {
  final effective = ref.read(effectiveFilterProvider);
  final Set<ListingCategory> initial = {
    for (final ListingCategory c in ListingCategory.values)
      if (effective.includesCategory(c)) c,
  };
  Set<ListingCategory> draft = {...initial};

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => StatefulBuilder(
      builder: (context, setState) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
            _SheetTitle('选择分类（可多选）'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final ListingCategory c in ListingCategory.values)
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: draft.contains(c),
                      title: Text(c.label, style: _bodyStyle()),
                      onChanged: (on) => setState(() {
                        on == true ? draft.add(c) : draft.remove(c);
                      }),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(sheetContext).pop(),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  FilledButton(
                    onPressed: () {
                      ref.read(searchConditionsProvider.notifier).setCategories(draft);
                      Navigator.of(sheetContext).pop();
                    },
                    child: const Text('确认'),
                  ),
                ],
              ),
            ),
          ],
          ),
        ),
      ),
    ),
  );
}

/// 半径选档。
Future<void> _showRadiusSheet(BuildContext context, WidgetRef ref) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
          _SheetTitle('搜索范围'),
          for (final SearchRadius radius in SearchRadius.values)
            ListTile(
              dense: true,
              title: Text(radius.label, style: _bodyStyle()),
              onTap: () {
                ref.read(searchConditionsProvider.notifier).setRadius(radius);
                Navigator.of(sheetContext).pop();
              },
            ),
          ],
        ),
      ),
    ),
  );
}

/// 供需切换。
Future<void> _showSupplySheet(BuildContext context, WidgetRef ref) async {
  const Map<String, Set<SupplyDemand>> options = {
    '资源': {SupplyDemand.supply},
    '需求': {SupplyDemand.demand},
    '资源 + 需求': {SupplyDemand.supply, SupplyDemand.demand},
  };
  await showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SheetTitle('供需'),
          for (final MapEntry<String, Set<SupplyDemand>> entry in options.entries)
            ListTile(
              dense: true,
              title: Text(entry.key, style: _bodyStyle()),
              onTap: () {
                ref.read(searchConditionsProvider.notifier).setSupplyDemand(entry.value);
                Navigator.of(sheetContext).pop();
              },
            ),
        ],
      ),
    ),
  );
}

/// 价格输入。
Future<void> _showPriceSheet(BuildContext context, WidgetRef ref) async {
  final effective = ref.read(effectiveFilterProvider);
  final minController = TextEditingController(text: effective.priceMin?.toString() ?? '');
  final maxController = TextEditingController(text: effective.priceMax?.toString() ?? '');

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(sheetContext).bottom),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SheetTitle('价格区间（元）'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              child: Row(
                children: [
                  Expanded(
                    child: _PriceInput(controller: minController, hint: '下限'),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: _PriceInput(controller: maxController, hint: '上限'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () {
                      ref.read(searchConditionsProvider.notifier).setPrice();
                      Navigator.of(sheetContext).pop();
                    },
                    child: const Text('不限'),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  FilledButton(
                    onPressed: () {
                      final int? min = int.tryParse(minController.text);
                      final int? max = int.tryParse(maxController.text);
                      // 区间倒置不写入：静默交换会让人以为输入被接受。
                      if (min != null && max != null && min > max) return;
                      ref.read(searchConditionsProvider.notifier).setPrice(min: min, max: max);
                      Navigator.of(sheetContext).pop();
                    },
                    child: const Text('确认'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 小区候选重选（只从解析给出的候选里选，不调起地图选点）。
Future<void> _showCommunitySheet(BuildContext context, WidgetRef ref) async {
  final candidates = ref.read(searchIntentProvider).intent?.communityCandidates ??
      const <CommunityCandidate>[];
  if (candidates.isEmpty) return;
  await showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SheetTitle('选择小区'),
          for (final candidate in candidates)
            ListTile(
              dense: true,
              title: Text(candidate.name, style: _bodyStyle()),
              subtitle: Text(candidate.district, style: _captionStyle()),
              onTap: () {
                final intent = ref.read(searchIntentProvider).intent;
                if (intent != null) {
                  ref.read(searchIntentProvider.notifier).replace(
                        intent.selectCommunity(candidate),
                      );
                }
                Navigator.of(sheetContext).pop();
              },
            ),
        ],
      ),
    ),
  );
}

/// 槽位的中文名。
String _slotTitle(ConditionSlot slot) => switch (slot) {
  ConditionSlot.radius => '范围',
  ConditionSlot.category => '分类',
  ConditionSlot.supplyDemand => '供需',
  ConditionSlot.price => '价格',
  ConditionSlot.anchor => '地点',
  ConditionSlot.community => '小区',
};

/// 槽位当前值文案（追加层里显示「已设为 X」而非空白）。
String _slotValue(ConditionSlot slot, EffectiveFilter effective) => switch (slot) {
  ConditionSlot.radius => effective.radius.label,
  ConditionSlot.category => effective.isAllCategories
      ? '全部分类'
      : effective.categoryLabels.join('/'),
  ConditionSlot.supplyDemand => effective.chips
      .firstWhere((c) => c.slot == ConditionSlot.supplyDemand)
      .label,
  ConditionSlot.price => effective.hasPrice ? effective.chips
      .firstWhere((c) => c.slot == ConditionSlot.price)
      .label : '不限',
  ConditionSlot.anchor => effective.anchorName ?? '未设置',
  ConditionSlot.community => effective.communityName ?? '未设置',
};

/// 从投影里取某槽位的 chip，供追加层复用它打开编辑。
ConditionChip _chipOf(ConditionSlot slot, EffectiveFilter effective) {
  for (final ConditionChip chip in effective.chips) {
    if (chip.slot == slot) return chip;
  }
  return ConditionChip(
    slot: slot,
    label: _slotTitle(slot),
    source: ConditionSource.persistent,
    editable: true,
  );
}

/// 弹层标题。
class _SheetTitle extends StatelessWidget {
  const _SheetTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Text(
        text,
        style: TextStyle(
          fontSize: AppTypeScale.h3.size,
          fontWeight: FontWeight.w600,
          color: Color(AppColors.textPrimary),
        ),
      ),
    );
  }
}

/// 价格输入框。
class _PriceInput extends StatelessWidget {
  const _PriceInput({required this.controller, required this.hint});

  final TextEditingController controller;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      style: _bodyStyle(),
      decoration: InputDecoration(
        hintText: hint,
        isDense: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide(color: Color(AppColors.border)),
        ),
      ),
    );
  }
}

/// 正文样式。
TextStyle _bodyStyle() => TextStyle(
  fontSize: AppTypeScale.body.size,
  color: Color(AppColors.textPrimary),
);

/// 说明文字样式。
TextStyle _captionStyle() => TextStyle(
  fontSize: AppTypeScale.small.size,
  color: Color(AppColors.textSecondary),
);
