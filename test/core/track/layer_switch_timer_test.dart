/// 图层切换四段计时器单测（[130]；§7.2 埋点组 / 详细设计 §17.2）。
///
/// 核心验证「四段各自独立 Stopwatch、严禁由 duration 减出」：若任何一段由
/// `duration - 其他段` 推出，则「只跑一段」时其余段会得到非零余数；
/// 独立计时下未开始的段恒为 0。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/core/track/layer_switch_timer.dart';

void main() {
  test('未开始的段记 0（不是由 duration_ms 减出的余数）', () async {
    final timer = LayerSwitchTimer();
    timer.start();
    timer.beginCache();
    await Future<void>.delayed(const Duration(milliseconds: 15));
    timer.endCache();
    timer.finish();

    // duration 与 t_cache 都非零（整段确实跑了）。
    expect(timer.durationMs, greaterThanOrEqualTo(15));
    expect(timer.tCacheMs, greaterThanOrEqualTo(15));
    // 其余三段未开始：独立计时下恒为 0；若由减法推出会得到非零余数。
    expect(timer.tNetMs, 0);
    expect(timer.tAggMs, 0);
    expect(timer.tRenderMs, 0);
  });

  test('只跑 net 段时 cache/agg/render 均为 0', () async {
    final timer = LayerSwitchTimer();
    timer.start();
    timer.beginNet();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    timer.endNet();
    timer.finish();

    expect(timer.tNetMs, greaterThanOrEqualTo(10));
    expect(timer.tCacheMs, 0);
    expect(timer.tAggMs, 0);
    expect(timer.tRenderMs, 0);
  });

  test('finish 停掉仍在跑的段（取消场景冻结为已耗时）', () async {
    final timer = LayerSwitchTimer();
    timer.start();
    timer.beginRender();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    // 不调 endRender，直接 finish：render 段仍应被冻结并报已耗时。
    timer.finish();

    expect(timer.tRenderMs, greaterThanOrEqualTo(10));
    expect(timer.tCacheMs, 0);
  });

  test('duration 独立测：只跑一段时 duration 不小于该段', () async {
    final timer = LayerSwitchTimer();
    timer.start();
    timer.beginAgg();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    timer.endAgg();
    timer.finish();

    expect(timer.durationMs, greaterThanOrEqualTo(timer.tAggMs));
  });
}
