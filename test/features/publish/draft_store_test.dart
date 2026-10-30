/// 草稿存储的起终点兼容测试（计划 U5）。
///
/// **这些断言防的是什么**：草稿是「尽力恢复」的本地数据，旧版本写下的 JSON
/// 里没有 `route_pair` 键。若读取端把缺键当成坏数据整份丢弃，用户升级一次
/// App 就丢一次正在编辑的草稿；而若起终点没有被持久化，恢复后表单摘要仍显示
/// 「选择起终点」，用户会以为自己白选了。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhaoyazhao/domain/route_pair.dart';
import 'package:zhaoyazhao/features/publish/draft_store.dart';
import 'package:zhaoyazhao/features/publish/publish_form_state.dart';

void main() {
  const store = DraftStore();

  setUp(() {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
  });

  test('保存再读取：routePair 完整还原（名称 / 地址 / 坐标 / 距离）', () async {
    const pair = RoutePair(
      origin: RoutePlace(
        name: '回龙观',
        address: '北京市昌平区回龙观',
        lng: 116.337,
        lat: 40.071,
      ),
      destination: RoutePlace(
        name: '中关村',
        address: '北京市海淀区中关村大街',
        lng: 116.316,
        lat: 39.983,
      ),
      distanceM: 18500,
      durationS: 2100,
    );
    const form = PublishFormState(
      leafCategoryId: 30101,
      title: '工作日拼车',
      routePair: pair,
    );

    await store.save(DraftSnapshot.of(form));
    final loaded = await store.load();

    expect(loaded, isNotNull);
    expect(loaded!.form.routePair, pair);
    expect(loaded.form.leafCategoryId, 30101);
  });

  test('旧草稿缺 route_pair 键 → routePair 为 null，文本键仍保留', () async {
    // 键名与 DraftStore 内部实现一致；这里刻意用字面量钉死，改键时本用例
    // 会失败，提醒同步升级草稿格式而不是静默丢数据。
    SharedPreferences.setMockInitialValues(<String, Object>{
      's2s.publish.draft':
          '{"draft_id":"publish-draft","saved_at":"2026-10-30T00:00:00.000",'
              '"form":{"leaf_category_id":30101,"title":"旧草稿",'
              '"template_values":{"route":"回龙观 → 中关村"}}}',
    });

    final loaded = await store.load();

    expect(loaded, isNotNull);
    expect(loaded!.form.routePair, isNull);
    expect(loaded.form.templateValues['route'], '回龙观 → 中关村');
  });
}
