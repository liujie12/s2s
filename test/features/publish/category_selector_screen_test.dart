/// 分类级联选择器页面接线测试（[124] 前端段 / B2）。
///
/// 为什么用 fake repository 而非 NetworkChainHarness 真 HTTP：testWidgets
/// 的 fake async 不推进真实 IO（网络链已由 category_tree_provider_test
/// 在纯 Dart test() 里覆盖）；本文件聚焦「AsyncValue 三态 → 页面渲染」
/// 这一层——fake 只走微任务，pumpAndSettle 可完整推进状态机。
library;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhaoyazhao/core/network/api_error_code.dart';
import 'package:zhaoyazhao/core/network/api_exception.dart';
import 'package:zhaoyazhao/features/category/category_dto.dart';
import 'package:zhaoyazhao/features/category/category_repository.dart';
import 'package:zhaoyazhao/features/category/category_tree_provider.dart';
import 'package:zhaoyazhao/features/publish/category_selector_screen.dart';

import '../../support/category_fixtures.dart';

/// 内存版 category 仓库：fetchTree 走纯微任务（fake async 兼容）。
///
/// 继承生产 [CategoryRepository] 而非另造接口：保证 override 的方法就是
/// 生产调用面（签名漂移编译期即炸，编码规范 §1.1 单一调用面）。
class _FakeCategoryRepository extends CategoryRepository {
  _FakeCategoryRepository() : super(Dio());

  /// 失败注入：非 null 时 [fetchTree] 原样抛出（模拟链上归一后的异常）。
  Object? errorToThrow;

  /// [fetchTree] 调用次数（「重新加载」触发重新协商的断言依据）。
  var fetchCount = 0;

  @override
  Future<CategoryTreeResult> fetchTree({
    String? localVersion,
    String? interactionId,
  }) async {
    fetchCount++;
    final error = errorToThrow;
    if (error != null) throw error;
    return CategoryTreeResult.full(
      CategoryTreeDto.fromJson(serverCategoryTreePayload()),
    );
  }
}

/// 装配被测页面（ProviderScope 在上，保证 push 出的路由同容器）。
///
/// 参数：[repo] 内存仓库；[prefs] mock 持久化实例；[home] 首页 widget。
/// 返回：[Widget] 可 pump 的树根。
Widget _app({
  required _FakeCategoryRepository repo,
  required SharedPreferences prefs,
  required Widget home,
}) {
  return ProviderScope(
    overrides: [
      categoryRepositoryProvider.overrideWithValue(repo),
      categoryTreeStoreProvider.overrideWithValue(CategoryTreeStore(prefs: prefs)),
    ],
    child: MaterialApp(home: home),
  );
}

void main() {
  late _FakeCategoryRepository repo;
  late SharedPreferences prefs;

  setUp(() async {
    // testWidgets 自带 binding，无需 ensureInitialized；
    // 每次用例重置空缓存（首启形态）。
    SharedPreferences.setMockInitialValues(const {});
    prefs = await SharedPreferences.getInstance();
    repo = _FakeCategoryRepository();
  });

  testWidgets('骨架 → 三列渲染：默认展开首个分支，高敏叶子带资质 chip',
      (tester) async {
    await tester.pumpWidget(
      _app(repo: repo, prefs: prefs, home: const CategorySelectorScreen()),
    );

    // 首帧（pumpWidget 内建帧绘制时微任务未推进）：骨架态，三列内容不存在。
    expect(find.text('选择分类'), findsOneWidget); // AppBar 常驻
    expect(find.text('餐饮服务'), findsNothing);

    await tester.pumpAndSettle();

    // 三列默认展开第一个分支：工作 > 全职招聘 > [餐饮服务, 零售导购]。
    expect(find.text('工作'), findsOneWidget);
    expect(find.text('全职招聘'), findsOneWidget);
    expect(find.text('餐饮服务'), findsOneWidget);
    expect(find.text('零售导购'), findsOneWidget);
    // 10101/10102 均为 enterprise（内置常量树映射）：两个资质 chip。
    expect(find.text('需企业认证'), findsNWidgets(2));
    // 未点选叶子：面包屑占位 + 确认按钮禁用。
    expect(find.text('未选择分类'), findsOneWidget);
    final confirm = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, '确认选择'),
    );
    expect(confirm.onPressed, isNull);
  });

  testWidgets('点选叶子 → 面包屑实时回显 → 确认选择 pop 返回叶子 id',
      (tester) async {
    int? result;
    await tester.pumpWidget(
      _app(
        repo: repo,
        prefs: prefs,
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                result = await Navigator.of(context).push<int>(
                  MaterialPageRoute(
                    builder: (_) => const CategorySelectorScreen(),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('餐饮服务'));
    await tester.pump();

    // 面包屑实时回显（§5.4.2：滚动几屏后仍看得到自己选了哪项）。
    expect(find.text('工作 > 全职招聘 > 餐饮服务'), findsOneWidget);

    await tester.tap(find.text('确认选择'));
    await tester.pumpAndSettle();
    // 回传的是契约叶子 id（§13.2 post.leaf_category_id），不是节点对象。
    expect(result, 10101);
  });

  testWidgets('initialLeafId 预选回填：展开到所在分支，确认按钮即可用',
      (tester) async {
    await tester.pumpWidget(
      _app(
        repo: repo,
        prefs: prefs,
        home: const CategorySelectorScreen(initialLeafId: 10102),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('工作 > 全职招聘 > 零售导购'), findsOneWidget);
    final confirm = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, '确认选择'),
    );
    expect(confirm.onPressed, isNotNull);
  });

  testWidgets('首启无缓存 + 拉取失败：error 态只显 message，重新加载恢复',
      (tester) async {
    repo.errorToThrow = const ApiException(
      code: ApiErrorCode.networkFailure,
      message: '网络连接失败，请检查网络后重试',
    );
    await tester.pumpWidget(
      _app(repo: repo, prefs: prefs, home: const CategorySelectorScreen()),
    );
    await tester.pumpAndSettle();

    // requestId 为 null → §11.4 唯一格式退化为只显 message（不带括号）。
    expect(find.text('网络连接失败，请检查网络后重试'), findsOneWidget);
    expect(find.text('餐饮服务'), findsNothing);
    expect(repo.fetchCount, 1);

    // 恢复后点「重新加载」：invalidate → 重新协商 → 三列到达。
    repo.errorToThrow = null;
    await tester.tap(find.text('重新加载'));
    await tester.pumpAndSettle();

    expect(find.text('餐饮服务'), findsOneWidget);
    expect(repo.fetchCount, 2);
  });
}
