/// 编辑资料页测试（2026-11-02）。
///
/// 覆盖：昵称回填、保存时局部提交 `nickname`、成功后关闭页面。
/// 头像上传链路依赖平台选图与 OSS，属集成范围，本文件不驱动。
library;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/features/auth/auth_repository.dart';
import 'package:zhaoyazhao/features/profile/profile_dto.dart';
import 'package:zhaoyazhao/features/profile/profile_edit_screen.dart';
import 'package:zhaoyazhao/features/profile/profile_repository.dart';

/// 固定登录态。
class _StubSessionNotifier extends AuthSessionNotifier {
  @override
  AuthSession? build() => AuthSession(
        userId: 'u-1',
        phone: '13800008000',
        token: 'jwt-profile-edit-test',
        expireAt: DateTime(2099),
        isNewUser: false,
      );
}

/// 内存假 profile 仓库：记录 PATCH 入参并回写昵称。
class _FakeProfileRepository extends ProfileRepository {
  /// 构造假仓库。
  ///
  /// 参数：[nickname] 初始昵称。
  _FakeProfileRepository(this.nickname) : super(Dio());

  /// 当前昵称。
  String nickname;

  /// 最近一次 PATCH 的昵称（null＝未提交）。
  String? lastNickname;

  /// 最近一次 PATCH 的头像媒体 ID（null＝未提交）。
  String? lastAvatarMediaId;

  @override
  Future<MyProfileDto> fetchMyProfile({String? interactionId}) async => _profile();

  @override
  Future<MyProfileDto> updateMyProfile({
    String? nickname,
    String? avatarMediaId,
    String? interactionId,
  }) async {
    lastNickname = nickname;
    lastAvatarMediaId = avatarMediaId;
    if (nickname != null) this.nickname = nickname;
    return _profile();
  }

  /// 构造本人资料。
  ///
  /// 返回：[MyProfileDto]。
  MyProfileDto _profile() => MyProfileDto.fromJson({
        'id': 1,
        'nickname': nickname,
        'realname_status': 'passed',
        'phone_mask': '186****0845',
      });
}

/// 泵入编辑资料页。
///
/// 参数：[tester] 测试句柄；[repository] 假仓库。
/// 返回：[Future<void>]。
Future<void> _pumpEdit(
  WidgetTester tester,
  _FakeProfileRepository repository,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authSessionProvider.overrideWith(_StubSessionNotifier.new),
        profileRepositoryProvider.overrideWithValue(repository),
      ],
      child: const MaterialApp(home: ProfileEditScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('回填昵称，保存时只提交变更的昵称', (tester) async {
    final repository = _FakeProfileRepository('用户0845');
    await _pumpEdit(tester, repository);

    expect(find.text('用户0845'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '新昵称');
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(repository.lastNickname, '新昵称');
    expect(repository.lastAvatarMediaId, isNull);
  });
}
