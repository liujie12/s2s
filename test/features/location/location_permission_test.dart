/// 定位权限三态归类测试（PRD §6.4.4 A/B 判定）。
///
/// 锁定 [classifyLocationPhase] 的核心语义：A（从未授权）与 B（曾授权后被关）
/// 只能靠 `location_granted_once` 本地标记区分 —— 系统 API 只回答「现在有没有
/// 权限」，不回答「以前有没有过」（§6.4.4 `:1232`–`:1233`）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:zhaoyazhao/features/location/location_permission.dart';

void main() {
  group('classifyLocationPhase', () {
    test('granted/limited → granted（不看标记）', () {
      expect(
        classifyLocationPhase(PermissionStatus.granted, false),
        LocationPermissionPhase.granted,
      );
      expect(
        classifyLocationPhase(PermissionStatus.granted, true),
        LocationPermissionPhase.granted,
      );
      expect(
        classifyLocationPhase(PermissionStatus.limited, false),
        LocationPermissionPhase.granted,
      );
    });

    test('denied 且无标记 → A（从未授权）', () {
      expect(
        classifyLocationPhase(PermissionStatus.denied, false),
        LocationPermissionPhase.neverGranted,
      );
    });

    test('denied 且有标记 → B（曾授权后被关）', () {
      expect(
        classifyLocationPhase(PermissionStatus.denied, true),
        LocationPermissionPhase.revoked,
      );
    });

    test('permanentlyDenied/restricted 靠标记分 A/B', () {
      expect(
        classifyLocationPhase(PermissionStatus.permanentlyDenied, false),
        LocationPermissionPhase.neverGranted,
      );
      expect(
        classifyLocationPhase(PermissionStatus.permanentlyDenied, true),
        LocationPermissionPhase.revoked,
      );
      expect(
        classifyLocationPhase(PermissionStatus.restricted, true),
        LocationPermissionPhase.revoked,
      );
    });
  });
}
