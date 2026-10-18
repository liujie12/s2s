/// 发布页媒体段：编辑态既有媒体回显测试。
///
/// 锁两件事（2026-10-18 真机缺陷）：
/// 1. 编辑既有帖时，`initialMedia` 必须进入计数与缩略图（此前媒体段自持空列表，
///    页面显示 `0 / 9`，但表单里其实带着 media_ids）；
/// 2. 移除/新增后 `onChanged` 上报的是「既有 + 新增」的全量已 commit ID，
///    不能把原媒体 ID 冲掉（否则保存会静默丢图）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/features/publish/media_section.dart';

void main() {
  testWidgets('编辑态回显既有媒体：计数含既有项，移除后上报剩余 ID', (tester) async {
    final changed = <List<String>>[];
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: MediaSection(
              // 空 URL：跳过网络请求，只验证「入列 + 计数 + 上报」。
              initialMedia: const [
                (mediaId: 'm1', url: ''),
                (mediaId: 'm2', url: ''),
              ],
              onChanged: changed.add,
            ),
          ),
        ),
      ),
    );

    expect(find.text('2 / 9 · 支持图片'), findsOneWidget);
    expect(find.byIcon(Icons.image_outlined), findsNWidgets(2));

    // 移除第一条：应上报剩余的 m2，而不是空列表。
    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pump();

    expect(find.text('1 / 9 · 支持图片'), findsOneWidget);
    expect(changed, isNotEmpty);
    expect(changed.last, ['m2']);
  });
}
