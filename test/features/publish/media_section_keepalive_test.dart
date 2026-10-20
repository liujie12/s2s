/// 媒体段 keep-alive 回归测试（2026-10-20 真机缺陷）。
///
/// 缺陷现场：发布页是 `ListView` 懒构建，媒体段滚出可视区超出 cacheExtent 后
/// State 被销毁，已上传列表 `_items` 随之丢失 —— 用户上滚补标题/描述再滚回来，
/// 缩略图变回 `0 / 9`，而父级 `_form.mediaIds` 仍是旧值。
/// 修复：`_MediaSectionState` 混入 `AutomaticKeepAliveClientMixin`。
///
/// 本用例锁的是「滚走再滚回，媒体段 State 不被销毁」——
/// 用 State 实例同一性判定，而不是比对张数文本：重建时 `_items` 会从
/// `initialMedia` 回填，文本比对在新建态下会误判为通过。
/// 不涉及上传网络链（`initialMedia` 的 url 传空串，缩略图走占位图标，不发请求）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/features/publish/media_section.dart';

void main() {
  testWidgets('媒体段滚出可视区再滚回，State 不被销毁（keep-alive）', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                MediaSection(
                  onChanged: (_) {},
                  initialMedia: const [(mediaId: 'm1', url: '')],
                ),
                const SizedBox(height: 2000),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('1 / 9'), findsOneWidget);
    final before = tester.state(find.byType(MediaSection));

    // 向下滚约 1800，让媒体段完全离开视口并超出 cacheExtent。
    await tester.drag(find.byType(ListView), const Offset(0, -1800));
    await tester.pumpAndSettle();
    expect(find.textContaining('1 / 9'), findsNothing);

    // 滚回顶部：State 被保活则实例不变；若被回收重建，则这里会拿到新实例，
    // 真机上表现为已上传的图变回 0 / 9（新建态 initialMedia 为空）。
    await tester.drag(find.byType(ListView), const Offset(0, 1800));
    await tester.pumpAndSettle();
    final after = tester.state(find.byType(MediaSection));
    expect(
      identical(before, after),
      isTrue,
      reason: '媒体段 State 必须 keep-alive：被 ListView 回收会丢掉已上传列表',
    );
  });
}
