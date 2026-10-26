import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/domain/listing_category.dart';
import 'package:zhaoyazhao/features/discovery/condition_editor.dart';
import 'package:zhaoyazhao/features/discovery/condition_slots.dart';
import 'package:zhaoyazhao/features/discovery/discovery_filter.dart';
import 'package:zhaoyazhao/features/discovery/effective_filter.dart';

/// 改值层的交互单测（U7）。
///
/// 覆盖两条最容易写错的语义：确认才写入、点遮罩等于放弃。
void main() {
  ProviderContainer container() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  Future<void> pumpLauncher(
    WidgetTester tester,
    ProviderContainer c, {
    required Future<void> Function(BuildContext, WidgetRef) open,
  }) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => Center(
                child: ElevatedButton(
                  onPressed: () => open(context, ref),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('类目半屏：确认保留已选分类，不清空', (tester) async {
    final c = container();
    c.read(discoveryFilterProvider.notifier).setCategories({ListingCategory.house});
    await pumpLauncher(tester, c, open: showCategorySheet);

    await tester.tap(find.widgetWithText(FilledButton, '确认'));
    await tester.pumpAndSettle();

    expect(c.read(discoveryFilterProvider).categories, {ListingCategory.house});
  });

  testWidgets('类目半屏：取消或点遮罩都不改动已选分类', (tester) async {
    final c = container();
    c.read(discoveryFilterProvider.notifier).setCategories({ListingCategory.house});
    await pumpLauncher(tester, c, open: showCategorySheet);

    // 点半屏外（遮罩）收起。
    await tester.tapAt(const Offset(200, 20));
    await tester.pumpAndSettle();

    expect(c.read(discoveryFilterProvider).categories, {ListingCategory.house});
  });

  testWidgets('价格改值：确认后写入持久筛选，区间倒置不写入', (tester) async {
    final c = container();
    const chip = ConditionChip(
      slot: ConditionSlot.price,
      label: '≤2000 元',
      source: ConditionSource.persistent,
      editable: true,
    );
    await pumpLauncher(
      tester,
      c,
      open: (context, ref) => showConditionEditor(context, ref, chip),
    );

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '2000');
    await tester.enterText(fields.at(1), '500');
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();

    // 下限大于上限：不写入，遮罩仍在。
    expect(c.read(discoveryFilterProvider).hasPrice, isFalse);

    await tester.enterText(fields.at(0), '500');
    await tester.enterText(fields.at(1), '2000');
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();

    expect(c.read(discoveryFilterProvider).priceMin, 500);
    expect(c.read(discoveryFilterProvider).priceMax, 2000);
  });
}
