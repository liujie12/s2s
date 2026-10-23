/// 「AI 帮我发」入口测试（PRD §6.13 T6-① + §5.9 四模式）。
///
/// 守的是「入口把四种模式如实呈现、且可用/不可用分流正确」这条线：
/// 弹层少一个模式 = 漏做；把未实现的模式点成可用 = 假入口（比漏做更坏）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zhaoyazhao/features/ai/ai_repository.dart';
import 'package:zhaoyazhao/features/auth/auth_repository.dart';
import 'package:zhaoyazhao/features/media/audio_recorder.dart';
import 'package:zhaoyazhao/features/media/media_upload_service.dart';
import 'package:zhaoyazhao/features/publish/ai_entry_sheet.dart';
import 'package:zhaoyazhao/router/app_router.dart';

import '../../support/fake_media.dart';
import '../../support/fake_repositories.dart';

void main() {
  /// 挂载一个只含 FAB 的最小页面（不拉整张地图，聚焦入口本身）。
  ///
  /// 参数：[tester] 测试驱动器，[loggedIn] 是否已登录，
  ///   [recorder] 可注入的假录音器（语音模式用）。
  Future<void> pumpFab(
    WidgetTester tester, {
    bool loggedIn = true,
    FakeAudioRecorder? recorder,
  }) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          isLoggedInProvider.overrideWithValue(loggedIn),
          if (recorder != null) audioRecorderProvider.overrideWithValue(recorder),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: Consumer(
                builder: (context, ref, _) => AiPublishFab(
                  onTap: () => startAiPublish(context, ref),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  group('§6.13 T6-① 入口弹层', () {
    testWidgets('FAB 文案为「AI 帮我发」（Accent 专用色，不加装饰图标）', (tester) async {
      await pumpFab(tester);
      expect(find.text('AI 帮我发'), findsOneWidget);
    });

    testWidgets('点击后弹四模式（四模式全可用，无「即将开放」）', (tester) async {
      await pumpFab(tester);
      await tester.tap(find.text('AI 帮我发'));
      await tester.pumpAndSettle();

      expect(find.text('拍张图，说一句'), findsOneWidget);
      expect(find.text('语音说，零键盘'), findsOneWidget);
      expect(find.text('一问一答，新手引导'), findsOneWidget);
      expect(find.text('抢发：先占位再补全'), findsOneWidget);
      // B2-4 四模式已全量开放 —— 不再有占位标注
      expect(find.text('即将开放'), findsNothing);
    });

    testWidgets('点②语音 → 进入语音录制弹层（麦克风入口）', (tester) async {
      await pumpFab(tester);
      await tester.tap(find.text('AI 帮我发'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('语音说，零键盘'));
      await tester.pumpAndSettle();

      expect(find.text('点击开始录音'), findsOneWidget);
      expect(find.textContaining('说一句话，再点停止'), findsWidgets);
    });
  });

  group('§5.9 模式① 快速输入', () {
    testWidgets('选① → 出现「拍张图 + 一句话」弹层', (tester) async {
      await pumpFab(tester);
      await tester.tap(find.text('AI 帮我发'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('拍张图，说一句'));
      await tester.pumpAndSettle();

      expect(find.text('拍 1 张图'), findsOneWidget);
      expect(find.text('开始识别'), findsOneWidget);
      expect(find.text('说一句，例如「楼下超市卖苹果 5 元」'), findsOneWidget);
    });

    testWidgets('没选图就点「开始识别」→ 提示先拍图（不上传、不跳转）', (tester) async {
      await pumpFab(tester);
      await tester.tap(find.text('AI 帮我发'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('拍张图，说一句'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('开始识别'));
      await tester.pumpAndSettle();

      expect(find.textContaining('先拍 1 张图'), findsOneWidget);
    });
  });

  group('§5.9 模式④ 抢发', () {
    testWidgets('选④ → 出现「标题 + 拍照」弹层（含 24h 补全说明）', (tester) async {
      await pumpFab(tester);
      await tester.tap(find.text('AI 帮我发'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('抢发：先占位再补全'));
      await tester.pumpAndSettle();

      expect(find.text('抢发：先占位，再补全'), findsOneWidget);
      expect(find.textContaining('24 小时内补全'), findsWidgets);
      expect(find.text('标题'), findsWidgets);
      expect(find.text('拍好了，去发布'), findsOneWidget);
    });

    testWidgets('未选图点「拍好了，去发布」→ 提示先加图', (tester) async {
      await pumpFab(tester);
      await tester.tap(find.text('AI 帮我发'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('抢发：先占位再补全'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('拍好了，去发布'));
      await tester.pumpAndSettle();

      expect(find.textContaining('先拍 1 张图'), findsOneWidget);
    });
  });

  group('§5.9 模式② 语音零键盘', () {
    testWidgets('麦克风权限被拒 → 提示去系统设置开启（不进录音态）', (tester) async {
      final recorder = FakeAudioRecorder()..permissionGranted = false;
      await pumpFab(tester, recorder: recorder);
      await tester.tap(find.text('AI 帮我发'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('语音说，零键盘'));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.mic_none));
      await tester.pumpAndSettle();

      expect(find.textContaining('需要麦克风权限'), findsOneWidget);
      expect(recorder.startCount, 0);
    });

    testWidgets('录音 → 停止 → 上传音频 → 进确认页（带 voice_media_id）', (tester) async {
      final recorder = FakeAudioRecorder();
      final uploader = FakeMediaUploadService(mediaId: 'voice_9');
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => Scaffold(
              body: Center(
                child: Consumer(
                  builder: (context, ref, _) => AiPublishFab(
                    onTap: () => startAiPublish(context, ref),
                  ),
                ),
              ),
            ),
          ),
          GoRoute(
            path: AppRoutes.aiConfirm,
            builder: (context, state) =>
                const Scaffold(body: Center(child: Text('确认页占位'))),
          ),
        ],
      );
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isLoggedInProvider.overrideWithValue(true),
            audioRecorderProvider.overrideWithValue(recorder),
            mediaUploadServiceProvider.overrideWithValue(uploader),
            // 确认页落地后会调解析接口，注入假仓库避免真网络。
            aiRepositoryProvider.overrideWithValue(FakeAiRepository()),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );

      await tester.tap(find.text('AI 帮我发'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('语音说，零键盘'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.mic_none));
      await tester.pumpAndSettle();
      // 进入录音态：文案变为「点击停止」
      expect(find.textContaining('点击停止'), findsWidgets);

      await tester.tap(find.byIcon(Icons.stop));
      await tester.pumpAndSettle();

      // 音频走了上传链路，且上了确认页
      expect(recorder.stopCount, 1);
      expect(uploader.uploadCount, 1);
      expect(uploader.lastUploaded?.contentType, 'audio/mp4');
      expect(find.text('确认页占位'), findsOneWidget);
    });
  });
}
