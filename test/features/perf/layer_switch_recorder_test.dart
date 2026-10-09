/// 图层切换耗时记录器单测（[140]）。
///
/// 锁三件事：① 四段按会话独立记录、聚合段只记第一次；② `cancelled` / `failed`
/// **不进 P95 分母**但计数可见；③ 跨帧收尾必须按 `sessionId` 校验 —— 否则被取代的
/// 旧会话会把耗时记到新会话头上。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/features/perf/layer_switch_recorder.dart';

void main() {
  test('完整一次切换：四段与整段各自成读数，落一条 success 样本', () async {
    final recorder = LayerSwitchRecorder();
    recorder.start();
    final int id = recorder.activeSessionId!;

    recorder.beginNet();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    recorder.endNet();

    recorder.beginAgg();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    recorder.endAgg();

    recorder.markRenderStart();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    recorder.finish(sessionId: id, outcome: LayerSwitchOutcome.success);

    expect(recorder.sampleCount, 1);
    expect(recorder.successCount, 1);
    expect(recorder.cancelledCount, 0);
    expect(recorder.failedCount, 0);
    expect(recorder.hasActiveSession, isFalse);

    // 单样本时 P95 即该样本值。
    expect(recorder.netP95Ms, greaterThanOrEqualTo(10));
    expect(recorder.aggP95Ms, greaterThanOrEqualTo(10));
    expect(recorder.renderP95Ms, greaterThanOrEqualTo(10));
    // 缓存段无实现，恒为 0（§17.2「未命中为 0」）。
    expect(recorder.cacheP95Ms, 0);
    // 整段独立测：不小于任一单段。
    expect(recorder.p95Ms, greaterThanOrEqualTo(recorder.netP95Ms));
  });

  test('无活跃会话时所有打点均为空操作（拖动重取不得被计入）', () {
    final recorder = LayerSwitchRecorder();

    recorder.beginNet();
    recorder.endNet();
    recorder.beginAgg();
    recorder.endAgg();
    recorder.markRenderStart();
    recorder.finish(sessionId: 1, outcome: LayerSwitchOutcome.success);

    expect(recorder.sampleCount, 0);
    expect(recorder.hasActiveSession, isFalse);
  });

  test('聚合段一个会话只记第一次（拖动中每帧重算不得累加）', () async {
    final recorder = LayerSwitchRecorder();
    recorder.start();
    final int id = recorder.activeSessionId!;

    recorder.beginAgg();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    recorder.endAgg();

    // 第二次 begin/end 必须被忽略：若被计入，聚合读数会累到 ~60ms。
    recorder.beginAgg();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    recorder.endAgg();

    recorder.finish(sessionId: id, outcome: LayerSwitchOutcome.success);

    expect(recorder.aggP95Ms, lessThan(50));
  });

  test('快速连切：前一会话记 cancelled，且不进 P95 分母', () async {
    final recorder = LayerSwitchRecorder();

    recorder.start();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    // 未收尾就再切一次 → 前者被取代。
    recorder.start();
    final int second = recorder.activeSessionId!;
    recorder.finish(sessionId: second, outcome: LayerSwitchOutcome.success);

    expect(recorder.sampleCount, 2);
    expect(recorder.successCount, 1);
    expect(recorder.cancelledCount, 1);
    // P95 只看那一条 success（≈0ms），cancelled 的 30ms 不得拉高 P95。
    expect(recorder.p95Ms, lessThan(30));
  });

  test('失败会话计入计数但不进 P95 分母', () async {
    final recorder = LayerSwitchRecorder();

    recorder.start();
    final int failedId = recorder.activeSessionId!;
    await Future<void>.delayed(const Duration(milliseconds: 25));
    recorder.finish(sessionId: failedId, outcome: LayerSwitchOutcome.failed);

    recorder.start();
    final int okId = recorder.activeSessionId!;
    recorder.finish(sessionId: okId, outcome: LayerSwitchOutcome.success);

    expect(recorder.sampleCount, 2);
    expect(recorder.successCount, 1);
    expect(recorder.failedCount, 1);
    expect(recorder.p95Ms, lessThan(25));
  });

  test('过期会话的收尾被忽略（跨帧回调不得记到新会话头上）', () async {
    final recorder = LayerSwitchRecorder();

    recorder.start();
    final int staleId = recorder.activeSessionId!;
    recorder.start(); // 取代 staleId，后者已落为 cancelled
    final int currentId = recorder.activeSessionId!;

    // 旧会话的渲染收尾这一刻才到 —— 必须作废。
    recorder.finish(sessionId: staleId, outcome: LayerSwitchOutcome.success);
    expect(recorder.sampleCount, 1, reason: '仅 staleId 的 cancelled 那一条');
    expect(recorder.hasActiveSession, isTrue);

    recorder.finish(sessionId: currentId, outcome: LayerSwitchOutcome.success);
    expect(recorder.sampleCount, 2);
    expect(recorder.successCount, 1);
  });

  test('reset 清空样本并放弃进行中的会话', () async {
    final recorder = LayerSwitchRecorder();
    recorder.start();
    final int id = recorder.activeSessionId!;
    recorder.finish(sessionId: id, outcome: LayerSwitchOutcome.success);
    expect(recorder.sampleCount, 1);

    recorder.start();
    final int inFlight = recorder.activeSessionId!;
    recorder.reset();

    expect(recorder.sampleCount, 0);
    expect(recorder.hasActiveSession, isFalse);
    // 进行中会话已被放弃：其收尾不再落样本。
    recorder.finish(sessionId: inFlight, outcome: LayerSwitchOutcome.success);
    expect(recorder.sampleCount, 0);
  });

  test('容量上限：超出后淘汰最旧样本', () {
    final recorder = LayerSwitchRecorder(capacity: 2);
    for (int i = 0; i < 3; i++) {
      recorder.start();
      recorder.finish(
        sessionId: recorder.activeSessionId!,
        outcome: LayerSwitchOutcome.success,
      );
    }
    expect(recorder.sampleCount, 2);
    expect(recorder.successCount, 2);
  });

  test('轴② 占比：无样本记 0，全达标记 1', () {
    final recorder = LayerSwitchRecorder();
    expect(recorder.layerLoadSuccessCount, 0);
    expect(recorder.layerLoadSuccessRatio, 0);

    recorder.start();
    recorder.finish(
      sessionId: recorder.activeSessionId!,
      outcome: LayerSwitchOutcome.success,
    );
    expect(recorder.layerLoadSuccessCount, 1);
    expect(recorder.layerLoadSuccessRatio, 1.0);
  });

  test('轴② 占比：超 300ms 的会话不计入分子（与 P95 是两条不同的线）', () async {
    final recorder = LayerSwitchRecorder();

    // 慢会话：整段 >300ms（判据线）。用真实等待而非伪造读数 —— duration 必须独立测。
    recorder.start();
    final int slow = recorder.activeSessionId!;
    await Future<void>.delayed(const Duration(milliseconds: 350));
    recorder.finish(sessionId: slow, outcome: LayerSwitchOutcome.success);

    // 快会话：≈0ms。
    recorder.start();
    recorder.finish(
      sessionId: recorder.activeSessionId!,
      outcome: LayerSwitchOutcome.success,
    );

    expect(recorder.successCount, 2);
    expect(recorder.layerLoadSuccessCount, 1, reason: '只有快会话 ≤300ms');
    expect(recorder.layerLoadSuccessRatio, closeTo(0.5, 1e-9));
  });

  test('轴② 占比：cancelled / failed 不进分母（§6.1 口径）', () {
    final recorder = LayerSwitchRecorder();

    // cancelled：未收尾就再切一次。
    recorder.start();
    recorder.start();
    recorder.finish(
      sessionId: recorder.activeSessionId!,
      outcome: LayerSwitchOutcome.success,
    );

    // failed：数据没回来。
    recorder.start();
    recorder.finish(
      sessionId: recorder.activeSessionId!,
      outcome: LayerSwitchOutcome.failed,
    );

    expect(recorder.successCount, 1);
    expect(recorder.cancelledCount, 1);
    expect(recorder.failedCount, 1);
    expect(recorder.layerLoadSuccessCount, 1);
    expect(recorder.layerLoadSuccessRatio, 1.0, reason: '分母只含 success');
  });
}
