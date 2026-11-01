/// 实时消息客户端（WebSocket）。
///
/// 职责边界：**只负责连接与事件分发**，不碰 Riverpod、不碰 UI、不碰业务仓库。
/// 装配在 `lib/features/message/realtime_wiring.dart`，这样 core 仍不反向依赖 features
/// （与 `core/network` 同一取向）。
///
/// 设计要点：
/// - 断线由指数退避 + 抖动重连（全客户端统一，页面内不再各写 Timer）；
/// - **被同账号其它端替换（关闭码 4002）时不自动重连**：否则两端会互相踢成死循环；
/// - 心跳 25s 一次，超过 60s 没收到任何帧即判定假连接并重连（移动网络切换常见）；
/// - 连接只在「已登录 + App 在前台」时存在，后台交给厂商推送（省电、也避免被系统杀）。
///
/// 可靠性口径：实时通道是**加速器**，丢事件不影响最终一致——重连后由装配层拉一次
/// 未读汇总与当前会话增量（`after_seq`）补齐。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../nfr_constants.dart';

/// 新消息事件类型（与后端 `RealtimeLimits.EVENT_MESSAGE_NEW` 同值）。
const String realtimeEventMessageNew = 'message.new';

/// 建立 WebSocket 的连接器（测试可注入假实现）。
typedef RealtimeConnector = Future<WebSocket> Function(
  Uri uri,
  Map<String, dynamic> headers,
);

/// 一条实时消息事件。
///
/// 只带定位信息（会话 + 序号），<b>不含正文</b>；正文由页面向 HTTP 增量接口拉取。
class RealtimeMessageEvent {
  /// 构造事件。
  ///
  /// 参数：[type] 事件类型；[conversationId] 会话 ID；[seq] 新消息序号。
  const RealtimeMessageEvent({
    required this.type,
    required this.conversationId,
    required this.seq,
  });

  /// 事件类型（当前只有 [realtimeEventMessageNew]）。
  final String type;

  /// 会话 ID。
  final int conversationId;

  /// 新消息序号（增量拉取游标）。
  final int seq;
}

/// 把 baseUrl 推导成实时通道地址。
///
/// 参数：[baseUrl] HTTP 基址（生产为 `https://<域名>`，不带 `/api/v1`）。
/// 返回：[Uri] `wss://<域名>/ws`（http 基址对应 `ws://`）。
/// 抛出：[FormatException] baseUrl 无法解析出主机时（装配期即暴露配置错误）。
Uri realtimeUriFor(String baseUrl) {
  final base = Uri.parse(baseUrl);
  if (base.host.isEmpty) {
    throw FormatException('实时通道 baseUrl 缺少主机：$baseUrl');
  }
  final scheme = base.scheme == 'https' ? 'wss' : 'ws';
  final rawPath = base.path.endsWith('/')
      ? base.path.substring(0, base.path.length - 1)
      : base.path;
  return base.replace(
    scheme: scheme,
    path: '$rawPath${NfrRealtime.endpointPath}',
    query: null,
    fragment: null,
  );
}

/// 解析一帧 JSON 成事件；不是新消息事件或字段缺失时返回 null（不抛）。
///
/// 参数：[decoded] 已 `jsonDecode` 的值。
/// 返回：[RealtimeMessageEvent?]。
RealtimeMessageEvent? realtimeMessageEventOf(Object? decoded) {
  if (decoded is! Map) return null;
  if (decoded['type']?.toString() != realtimeEventMessageNew) return null;
  final conversationId = _asIntValue(decoded['conversationId']);
  final seq = _asIntValue(decoded['seq']);
  if (conversationId == null || seq == null) return null;
  return RealtimeMessageEvent(
    type: realtimeEventMessageNew,
    conversationId: conversationId,
    seq: seq,
  );
}

/// 计算第 [attempt] 次重连的等待时长（指数退避 + 抖动，封顶
/// [NfrRealtime.reconnectMaxDelay]）。
///
/// 参数：[attempt] 从 0 开始的连续失败次数；[random] 抖动源（测试注入固定种子）。
/// 返回：[Duration] 本次等待时长；抖动幅度为 ±[NfrRealtime.reconnectJitterRatio]。
Duration realtimeReconnectDelay(int attempt, Random random) {
  // 指数封顶到 2^16，避免大 attempt 左移溢出；该值对应的等待早已超过上限
  final exponent = attempt.clamp(0, 16);
  final baseMillis =
      NfrRealtime.reconnectBaseDelay.inMilliseconds * (1 << exponent);
  final capMillis = NfrRealtime.reconnectMaxDelay.inMilliseconds;
  final rawMillis = min(baseMillis, capMillis);
  final jitterMillis =
      (rawMillis * NfrRealtime.reconnectJitterRatio).round();
  if (jitterMillis <= 0) return Duration(milliseconds: rawMillis);
  final offset = random.nextInt(jitterMillis * 2 + 1) - jitterMillis;
  return Duration(milliseconds: (rawMillis + offset).clamp(0, capMillis));
}

/// 实时通道客户端。
class RealtimeClient {
  /// 构造客户端。
  ///
  /// 参数：
  ///   [endpoint]   连接地址提供者（每次重连现取，兼容 baseUrl 变更）；
  ///   [token]      Token 提供者（每次重连现取，登录/续期后自动用新值）；
  ///   [connector]  连接器（测试注入；默认 `WebSocket.connect`）；
  ///   [random]     抖动源（测试注入固定种子）。
  RealtimeClient({
    required Uri Function() endpoint,
    required String? Function() token,
    RealtimeConnector? connector,
    Random? random,
  })  : _endpoint = endpoint,
        _token = token,
        _connector = connector ?? _defaultConnector,
        _random = random ?? Random();

  /// 默认连接器：`dart:io` WebSocket（支持自定义请求头，无需引入第三方依赖）。
  ///
  /// 参数：[uri] 目标地址；[headers] 握手请求头（含 Authorization）。
  /// 返回：[Future<WebSocket>]。
  static Future<WebSocket> _defaultConnector(
    Uri uri,
    Map<String, dynamic> headers,
  ) =>
      WebSocket.connect(uri.toString(), headers: headers);

  final Uri Function() _endpoint;
  final String? Function() _token;
  final RealtimeConnector _connector;
  final Random _random;

  /// 事件出口（广播：列表页、会话页、装配层可同时监听）。
  final StreamController<RealtimeMessageEvent> _events =
      StreamController<RealtimeMessageEvent>.broadcast();

  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  DateTime? _lastFrameAt;
  int _attempt = 0;
  bool _connecting = false;
  bool _manualClose = false;
  bool _replaced = false;
  bool _disposed = false;

  /// 事件流（新消息）。
  Stream<RealtimeMessageEvent> get events => _events.stream;

  /// 当前是否已建立连接。
  bool get isConnected => _socket != null;

  /// 连续失败次数（观测与测试用）。
  @visibleForTesting
  int get reconnectAttempt => _attempt;

  /// 建立连接；已连接、正在连接或未登录时直接返回。
  ///
  /// 返回：[Future<void>] 连接动作完成（不代表握手成功，失败会进入退避重连）。
  Future<void> connect() async {
    if (_disposed || _connecting || _socket != null) return;
    final token = _token();
    if (token == null || token.isEmpty) return;
    _manualClose = false;
    _replaced = false;
    _connecting = true;
    try {
      final socket = await _connector(
        _endpoint(),
        <String, dynamic>{'Authorization': 'Bearer $token'},
      );
      if (_disposed || _manualClose) {
        await socket.close();
        return;
      }
      _socket = socket;
      _attempt = 0;
      _lastFrameAt = DateTime.now();
      _subscription = socket.listen(
        _onFrame,
        onError: (Object _) => _handleDrop(),
        onDone: _handleDrop,
        cancelOnError: true,
      );
      _startHeartbeat();
    } catch (_) {
      // 握手失败/网络不可达：进入退避，不向上抛（实时是旁路）
      _scheduleReconnect();
    } finally {
      _connecting = false;
    }
  }

  /// 主动断开（进后台、登出、页面销毁）；不会自动重连。
  ///
  /// 返回：[Future<void>]。
  Future<void> disconnect() async {
    _manualClose = true;
    _reconnectTimer?.cancel();
    _heartbeatTimer?.cancel();
    final socket = _socket;
    _socket = null;
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
    await socket?.close();
  }

  /// 释放资源（Provider 销毁时调用）。
  ///
  /// 返回：[Future<void>]。
  Future<void> dispose() async {
    _disposed = true;
    await disconnect();
    await _events.close();
  }

  /// 收到一帧：刷新活跃时间，心跳应答忽略，其余按事件解析。
  ///
  /// 参数：[frame] 文本帧。
  void _onFrame(dynamic frame) {
    _lastFrameAt = DateTime.now();
    if (frame is! String) return;
    if (frame == 'pong') return;
    try {
      final event = realtimeMessageEventOf(jsonDecode(frame));
      if (event != null) _events.add(event);
    } on FormatException {
      // 非 JSON 帧直接忽略
    }
  }

  /// 连接掉线：清理 socket，按关闭码决定是否重连。
  void _handleDrop() {
    final closeCode = _socket?.closeCode;
    _teardown();
    if (_disposed || _manualClose) return;
    if (closeCode == NfrRealtime.closeSessionReplaced) {
      // 被同账号其它端替换：停止重连，等下次登录/回前台由装配层显式重连
      _replaced = true;
      return;
    }
    _scheduleReconnect();
  }

  /// 安排一次退避重连。
  void _scheduleReconnect() {
    if (_disposed || _manualClose || _replaced) return;
    _reconnectTimer?.cancel();
    final delay = realtimeReconnectDelay(_attempt, _random);
    _attempt += 1;
    _reconnectTimer = Timer(delay, () => unawaited(connect()));
  }

  /// 启动心跳：发 ping 并检测假连接。
  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(NfrRealtime.heartbeatInterval, (_) {
      final last = _lastFrameAt;
      if (last != null &&
          DateTime.now().difference(last) > NfrRealtime.heartbeatTimeout) {
        // 假连接：对端已不可达但 TCP 未断开，主动丢弃触发重连
        unawaited(_socket?.close());
        _handleDrop();
        return;
      }
      try {
        _socket?.add('ping');
      } catch (_) {
        _handleDrop();
      }
    });
  }

  /// 清理连接资源（不触发重连判定）。
  void _teardown() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    final subscription = _subscription;
    _subscription = null;
    unawaited(subscription?.cancel());
    _socket = null;
  }
}

/// 把 JSON 数值宽松解析成 int（服务端可能下发 int 或字符串）。
///
/// 参数：[value] 原始值。
/// 返回：[int?] 解析失败为 null。
int? _asIntValue(Object? value) {
  if (value is int) return value;
  return int.tryParse(value?.toString() ?? '');
}
