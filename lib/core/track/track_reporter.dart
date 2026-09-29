/// 埋点聚批上报器（详细设计 §17.4 / §17.4.1 / §17.4.2）。
///
/// **本文件是「埋点批次每次组批换新幂等键」这一唯一例外的落地处**（§17.4.1）。
/// 与普通写接口相反：普通写接口的重试重发的是「同一笔业务意图」，须沿用原
/// `Idempotency-Key` 防重复；而埋点批次失败退回队列头部后，会与新采集事件
/// **重新组批**（内容可能已变），若沿用旧 Key，服务端命中幂等缓存直接回
/// code=0，客户端误判成功并出队 → **事件静默丢失且无任何错误日志**。故
/// [buildBatch] 每次组批都生成新的幂等键与批次级 `X-Interaction-Id`。
///
/// **批次级 `X-Interaction-Id` 语义是「这次传输动作」**（§17.4.2）：埋点上报
/// 没有单一「交互起点」（定时/进后台/离线回灌，一批 50 条可能来自几十个不同
/// 交互），故由上报器每批新生成，事件自身的 `interaction_id` 保留在事件体内，
/// 两者互不覆盖。
///
/// **回灌限速与重试是两套机制**（§17.4.2）：本类的 [flush] 只发一批；限速
/// （批间 ≥[NfrTrack.trackReplayMinIntervalSec] 秒）与触发调度（30s 定时/
/// 进后台/登录补报/联网回灌）由外层控制器负责，**禁靠重试驱动回灌**。
library;

import 'package:dio/dio.dart';

import '../../nfr_constants.dart';
import '../network/api_client.dart';
import '../network/api_error_code.dart';
import '../network/api_exception.dart';
import 'track_event.dart';
import 'track_queue.dart';

/// 单次 flush 的结果（供外层控制器决定后续调度，不向用户呈现）。
enum FlushResult {
  /// 批次已发送且已从队列移除。
  sent,

  /// 队列为空，无可上报。
  nothingToSend,

  /// 未登录：事件保留在队列，登录后补报（§17.4「未登录事件」）。
  notLoggedIn,

  /// 命中 `42906` 埋点限频：整批退回队列头部，静默不打扰用户（§12.2）。
  requeued,

  /// 传输或服务端失败（非 42906/40101）：整批保留，下次 flush 再试。
  failed,
}

/// 埋点聚批上报器。
class TrackReporter {
  /// 构造上报器。
  ///
  /// 参数：
  ///   [dio]      生产同款五拦截器链 dio（AuthRefresh/Retry 对埋点批次照常生效）；
  ///   [queue]    持久化队列（本类只读/移除，不加工事件字段）；
  ///   [readToken] 读当前登录态（null/空串 = 未登录，事件暂存不报）；
  ///   [newUuidV4] UUID v4 生成器（幂等键与批次交互 ID 各取一次）。
  TrackReporter({
    required Dio dio,
    required TrackQueue queue,
    required Future<String?> Function() readToken,
    required String Function() newUuidV4,
  })  : _dio = dio,
        _queue = queue,
        _readToken = readToken,
        _newUuidV4 = newUuidV4;

  /// `POST /track/events` 路径（相对 baseUrl，前缀在 [NetworkConfig.baseUrl]）。
  static const String trackEventsPath = '/track/events';

  final Dio _dio;
  final TrackQueue _queue;
  final Future<String?> Function() _readToken;
  final String Function() _newUuidV4;

  /// 组装一个上报批次（每次组批换新幂等键与批次级交互 ID，§17.4.1/§17.4.2）。
  ///
  /// 幂等键策略与 §11.1.1 的普通写接口【相反】：每次调用都生成**新的**
  /// `Idempotency-Key` 与批次级 `X-Interaction-Id` —— 见文件头论证。
  ///
  /// 参数：
  ///   [events]       本批事件（条数上限 [NfrApi.trackBatchMaxEvents]）；
  ///   [droppedCount] 自上次成功上报以来因容量溢出丢弃的条数。
  /// 返回：[TrackBatch] 含新生成幂等键/交互 ID 的批次对象。
  TrackBatch buildBatch(List<TrackEvent> events, int droppedCount) {
    return TrackBatch(
      idempotencyKey: _newUuidV4(),
      interactionId: _newUuidV4(),
      events: events,
      droppedCount: droppedCount,
    );
  }

  /// 队列内待上报事件数（供外层控制器判断「满批触发」）。
  int get queueLength => _queue.length;

  /// 入队一条事件（纯入队，不触发上报；上报时机由外层控制器调度）。
  ///
  /// 参数：[event] 待入队事件（去重键三列已冻结）。
  /// 返回：[Future<void>] 追加落盘完成后返回。
  Future<void> enqueue(TrackEvent event) => _queue.enqueue(event);

  /// 发送一批（至多 [NfrApi.trackBatchMaxEvents] 条）。
  ///
  /// 流程：未登录直接返回 [FlushResult.notLoggedIn]（事件保留）；否则窥视队首
  /// 组批 → POST → 成功则 [TrackQueue.acknowledge] 移除并清零丢弃计数；任何失败
  /// （42906/40101/传输/5xx）都不移除（`peek` 本就不移除），事件留在队首待下次。
  ///
  /// 返回：[Future<FlushResult>] 本次上报结果，供控制器决定后续调度。
  Future<FlushResult> flush() async {
    final token = await _readToken();
    if (token == null || token.isEmpty) {
      return FlushResult.notLoggedIn;
    }
    final events = _queue.peek(NfrApi.trackBatchMaxEvents);
    if (events.isEmpty) {
      return FlushResult.nothingToSend;
    }
    final dropped = _queue.droppedCount;
    final batch = buildBatch(events, dropped);
    try {
      await _dio.post<Object?>(
        trackEventsPath,
        data: batch.toJson(),
        // 批次级两键由本类显式带头；HeaderInterceptor 的 containsKey 纪律
        // 不会覆盖，重试（RetryInterceptor 重走 onRequest）也因此逐字沿用
        // 同批键（同一传输动作），而「换新键」只发生在下次 buildBatch。
        options: Options(
          headers: <String, String>{
            HeaderInterceptor.idempotencyKeyHeader: batch.idempotencyKey,
            HeaderInterceptor.interactionIdHeader: batch.interactionId,
          },
        ),
      );
      await _queue.acknowledge(events);
      _queue.takeDroppedCount();
      return FlushResult.sent;
    } on ApiException catch (error) {
      return _classify(error);
    } on DioException catch (error) {
      return _classify(asApiException(error));
    }
  }

  /// 把失败异常归一为 [FlushResult]（只决定「是否移除」，三种失败都**不移除**）。
  ///
  /// 参数：[error] 链上归一后的统一异常。
  /// 返回：[FlushResult] 42906→requeued、40101→notLoggedIn、其余→failed。
  FlushResult _classify(ApiException error) {
    if (error.code == ApiErrorCode.trackLimit) return FlushResult.requeued;
    if (error.code == ApiErrorCode.unauthorized) return FlushResult.notLoggedIn;
    return FlushResult.failed;
  }
}
