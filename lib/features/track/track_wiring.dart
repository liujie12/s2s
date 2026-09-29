/// 埋点链前端接线（[130]）：把 `lib/core/track/` 三件套 + 平台能力焊到 Riverpod。
///
/// **依赖方向保持 features → core 单向**（编码规范 §1.2）：本文件 import
/// `core/track` 与 `core/network`，core 不感知本文件。
///
/// 职责：
///   - [trackReporterProvider]：惰性异步初始化持久化队列（path_provider 落盘
///     文件）与上报器（生产同款 dio + 会话/设备回调查询）；
///   - [trackControllerProvider]：封装入队 + 触发调度（满批/30s 定时/进后台/
///     登录补报/联网回灌），供页面与 app 根调用。
library;

import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/network/api_client.dart';
import '../../core/track/track_event.dart';
import '../../core/track/track_queue.dart';
import '../../core/track/track_reporter.dart';
import '../../nfr_constants.dart';

/// 埋点队列文件在应用文档目录下的相对文件名。
const String trackQueueFileName = 'track_events.jsonl';

/// 埋点上报器（惰性异步初始化：先落盘队列文件，再以生产同款 dio 装配）。
///
/// 会话读取（[NetworkHooks.readToken]）决定「未登录不报、登录后补报」；
/// UUID 生成（[NetworkHooks.newUuidV4]）供 [TrackReporter.buildBatch] 每次组批换新键。
final trackReporterProvider = FutureProvider<TrackReporter>((ref) async {
  final dir = await getApplicationDocumentsDirectory();
  final queue = await TrackQueue.open(File('${dir.path}/$trackQueueFileName'));
  final hooks = ref.watch(networkHooksProvider);
  return TrackReporter(
    dio: ref.watch(dioProvider),
    queue: queue,
    readToken: hooks.readToken,
    newUuidV4: hooks.newUuidV4,
  );
});

/// 埋点链控制器：持有上报器、管触发调度。
class TrackController {
  /// 构造控制器。
  ///
  /// 参数：[reporter] 已初始化的上报器（触发调度只调 [TrackReporter.flush]）。
  TrackController({required TrackReporter reporter}) : _reporter = reporter;

  final TrackReporter _reporter;

  Timer? _flushTimer;
  bool _disposed = false;

  /// 启动 30s 周期触发（应用根在首个 reporter 就绪后调用一次）。
  void startPeriodicFlush() {
    _flushTimer?.cancel();
    _flushTimer = Timer.periodic(
      const Duration(seconds: NfrTrack.trackFlushIntervalSec),
      (_) => flush(),
    );
  }

  /// 入队一条事件；满 [NfrApi.trackBatchMaxEvents] 条即触发一次上报。
  ///
  /// 参数：[event] 待入队事件（去重键三列已冻结）。
  Future<void> enqueue(TrackEvent event) async {
    await _reporter.enqueue(event);
    if (_reporter.queueLength >= NfrApi.trackBatchMaxEvents) {
      unawaited(flush());
    }
  }

  /// 触发一次上报（进后台 / 登录补报 / 联网回灌 共用入口）。
  Future<FlushResult> flush() async {
    if (_disposed) return FlushResult.nothingToSend;
    return _reporter.flush();
  }

  /// 释放定时器（app 根 dispose 时调用）。
  void dispose() {
    _disposed = true;
    _flushTimer?.cancel();
  }
}

/// 埋点链控制器 Provider（惰性：reporter 就绪前返回 null，调用方自行等待）。
final trackControllerProvider = Provider<TrackController?>((ref) {
  final reporter = ref.watch(trackReporterProvider).value;
  if (reporter == null) return null;
  final controller = TrackController(reporter: reporter);
  ref.onDispose(controller.dispose);
  return controller;
});

/// 埋点链生命周期观察者：进后台触发上报 + 联网恢复触发回灌。
///
/// 由 app 根经 [WidgetsBindingObserver] 注册，把「进后台」「联网恢复」两个
/// 触发源接到 [trackControllerProvider]。
class TrackLifecycleObserver with WidgetsBindingObserver {
  /// 构造观察者。
  ///
  /// 参数：[readController] 每次事件发生时实时取控制器（避免持有过期实例）。
  TrackLifecycleObserver({required TrackController? Function() readController})
      : _readController = readController;

  final TrackController? Function() _readController;

  Connectivity? _connectivity;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  /// 开始观察（注册生命周期 + 联网监听）。
  void start() {
    WidgetsBinding.instance.addObserver(this);
    _connectivity = Connectivity();
    _connectivitySub = _connectivity!.onConnectivityChanged.listen((_) {
      _readController()?.flush();
    });
  }

  /// 停止观察（app 根 dispose 时调用）。
  void stop() {
    WidgetsBinding.instance.removeObserver(this);
    _connectivitySub?.cancel();
    _connectivitySub = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      // 进后台触发上报（§17.4「进后台」触发源）；detached 不再重复触发。
      _readController()?.flush();
    }
  }
}
