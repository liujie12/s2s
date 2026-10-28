/// 资质表单：未实名横幅与提交守卫测试。
///
/// 背景：账号未实名时，服务端对 `POST /cert/qualification` 回 `40302`。
/// 用户从「去添加资质」直接进表单时看不到实名前置要求，故表单顶部需明示并给入口，
/// 提交也先本地拦下（不打无意义的请求）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/features/cert/cert_models.dart';
import 'package:zhaoyazhao/features/cert/cert_provider.dart';
import 'package:zhaoyazhao/features/cert/qualification_form_screen.dart';

/// 假 trust 状态：不改网络、直接给出认证状态。
class _FakeTrustOverview extends TrustOverviewNotifier {
  _FakeTrustOverview(this._value);

  final TrustOverview _value;

  @override
  AsyncValue<TrustOverview> build() => AsyncValue.data(_value);
}

/// 构造只有认证状态的视图模型（完整度分布留空）。
///
/// 参数：[realnameStatus] 实名状态（`none` / `passed`）。
/// 返回：[TrustOverview]。
TrustOverview _overview(String realnameStatus) => TrustOverview(
      cert: CertStatus(realnameStatus: realnameStatus, qualifications: const []),
      distribution: const {},
    );

/// 铺开被测页面。
///
/// 参数：[realnameStatus] 实名状态。
/// 返回：[ProviderScope]。
Widget _app(String realnameStatus) {
  return ProviderScope(
    overrides: [
      trustOverviewProvider.overrideWith(
        () => _FakeTrustOverview(_overview(realnameStatus)),
      ),
    ],
    child: const MaterialApp(home: QualificationFormScreen()),
  );
}

void main() {
  testWidgets('未实名：表单顶部出现实名前置提示与入口', (tester) async {
    await tester.pumpWidget(_app('none'));
    await tester.pumpAndSettle();

    expect(find.text('添加资质前需先完成实名认证'), findsOneWidget);
    expect(find.text('去完成实名 ›'), findsOneWidget);
  });

  testWidgets('未实名：点提交先本地拦下，提示先完成实名', (tester) async {
    await tester.pumpWidget(_app('none'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('提交'));
    await tester.pumpAndSettle();

    expect(find.text('请先完成实名认证，再添加资质'), findsOneWidget);
  });

  testWidgets('已实名：不出现实名前置提示', (tester) async {
    await tester.pumpWidget(_app('passed'));
    await tester.pumpAndSettle();

    expect(find.text('添加资质前需先完成实名认证'), findsNothing);
    expect(find.text('去完成实名 ›'), findsNothing);
  });
}
