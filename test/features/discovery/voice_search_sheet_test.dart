/// 语音搜索面板单测（U6）：麦克风权限被拒时的可操作指引、转写失败不阻塞文字。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/features/discovery/voice_search_sheet.dart';
import 'package:zhaoyazhao/features/media/audio_recorder.dart';

/// 权限恒被拒的录音器桩。
class _DeniedRecorder implements AudioRecorder {
  @override
  Future<bool> hasPermission() async => false;

  @override
  Future<void> start() async => throw const AudioRecordException('不应开始录音');

  @override
  Future<RecordedClip?> stop() async => null;

  @override
  Future<void> cancel() async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  testWidgets('权限被拒 → 展示跳系统设置指引，不进入录音态', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          audioRecorderProvider.overrideWithValue(_DeniedRecorder()),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: VoiceSearchSheet(anchorLat: 30.28, anchorLng: 120.15),
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.mic_none));
    await tester.pumpAndSettle();

    expect(find.text('去系统设置开启麦克风权限'), findsOneWidget);
    expect(find.text('正在听…松开结束'), findsNothing);
  });

  testWidgets('面板只做语音，不再提供打字框（与搜索栏重复，2026-10-28 用户裁定）',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          audioRecorderProvider.overrideWithValue(_DeniedRecorder()),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: VoiceSearchSheet(anchorLat: 30.28, anchorLng: 120.15),
          ),
        ),
      ),
    );

    expect(find.byType(TextField), findsNothing);
    expect(find.text('按住说话'), findsOneWidget);
  });
}
