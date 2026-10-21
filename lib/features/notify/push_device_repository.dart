/// 推送设备上报仓库（B2-2 阶段 2；契约 `POST /users/me/devices`）。
///
/// 与 `NotificationRepository` 同一模式：真网络走 [dioProvider] 生产同款五拦截器链，
/// 本层只做「发请求 + 交 DTO 解析」。`X-Device-Id` 与 `Idempotency-Key` 由
/// [HeaderInterceptor] 统一注入，本层不重复写头（避免两处口径）。
///
/// **与插件选型解耦**：本仓库只认「通道 + token」两个值，华为 `huawei_push` 与小米
/// 原生 AAR 的桥接层拿到 token 后调本仓库即可；凭据/插件未到位时本层不影响编译。
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhaoyazhao/core/network/api_client.dart';
import 'package:zhaoyazhao/core/network/api_exception.dart';

import '../../core/contract_json.dart';

/// 推送通道（契约 `DevicePlatformEnum`；与 OS 维度 `device.platform` 不同）。
enum PushChannel {
  /// Apple Push Notification service（iOS）。
  apns('apns'),

  /// Firebase Cloud Messaging（境内不可用，仅契约对齐）。
  fcm('fcm'),

  /// 华为 Push Kit。
  hw('hw'),

  /// 小米推送。
  mi('mi'),

  /// OPPO 推送。
  oppo('oppo'),

  /// vivo 推送。
  vivo('vivo'),

  /// 荣耀推送。
  honor('honor');

  /// 构造通道枚举。
  ///
  /// 参数：[wire] 契约线值（小写）。
  const PushChannel(this.wire);

  /// 契约线值。
  final String wire;
}

/// 设备上报结果（契约 `DeviceUpsertResult`）。
class PushDeviceUpsertResult {
  /// 构造结果。
  ///
  /// 参数：[deviceId] 被写入的 `device` 行 ID；[channel] 实际写入的推送通道。
  const PushDeviceUpsertResult({
    required this.deviceId,
    required this.channel,
  });

  /// 从契约 JSON 解析。
  ///
  /// 参数：[json] 响应 `data` 对象。
  /// 返回：[PushDeviceUpsertResult]。
  /// 抛出：[ApiException.parse] 字段缺失或类型不符。
  factory PushDeviceUpsertResult.fromJson(Object? json) {
    final map = requireMap(json, 'DeviceUpsertResult');
    return PushDeviceUpsertResult(
      deviceId: requireInt(map, 'device_id', 'DeviceUpsertResult'),
      channel: parseChannel(requireString(map, 'platform', 'DeviceUpsertResult')),
    );
  }

  /// `device` 行 ID（新增或命中同一指纹）。
  final int deviceId;

  /// 实际写入的推送通道。
  final PushChannel channel;
}

/// 由契约线值反解通道。
///
/// 参数：[wire] 契约线值。
/// 返回：[PushChannel]。
/// 抛出：[ApiException.parse] 未知通道（服务端新增枚举时按契约违约处理，不静默降级）。
PushChannel parseChannel(String wire) {
  for (final channel in PushChannel.values) {
    if (channel.wire == wire) return channel;
  }
  throw ApiException.parse('DeviceUpsertResult.platform 未知通道: $wire');
}

/// 推送设备上报仓库。
class PushDeviceRepository {
  /// 构造仓库。
  ///
  /// 参数：[dio] 生产同款五拦截器链 dio（测试经 NetworkChainHarness 注入）。
  PushDeviceRepository(this._dio);

  final Dio _dio;

  /// 上报/更新当前设备的推送 token（`POST /users/me/devices`）。
  ///
  /// 参数：[channel] 推送通道；[token] 厂商下发的推送 token（≤128）；
  ///   [interactionId] 可选的 X-Interaction-Id（不传由拦截器生成）。
  /// 返回：[PushDeviceUpsertResult]（device_id + 实际通道）。
  /// 抛出：[ApiException] 40101 未登录 / 40001 参数非法 / 解析失败 / 传输错误。
  Future<PushDeviceUpsertResult> upsert({
    required PushChannel channel,
    required String token,
    String? interactionId,
  }) async {
    final response = await _dio.post<Object?>(
      '/users/me/devices',
      data: <String, Object?>{
        'platform': channel.wire,
        'token': token,
      },
      options: interactionId == null
          ? null
          : Options(headers: {HeaderInterceptor.interactionIdHeader: interactionId}),
    );
    return PushDeviceUpsertResult.fromJson(response.data);
  }
}

/// 推送设备上报仓库 Provider（dio 经 [dioProvider] 注入）。
final pushDeviceRepositoryProvider = Provider<PushDeviceRepository>(
  (ref) => PushDeviceRepository(ref.watch(dioProvider)),
);
