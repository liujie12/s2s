/// 网络底座装配（详细设计 §11.1 / §11.3 / §14.1，计划 U3：R6/R8/R12、
/// KTD2/KTD5/KTD8/KTD9）。
///
/// 本文件是 `lib/core/network/` 的唯一装配处（编码规范 §1.2 取向）：
///   - [NetworkConfig]：baseUrl 与 release 判定运行时注入分离，不直接引
///     `kReleaseMode`（KTD8）；release 且非 https 快速失败
///     （编码规范 §3.3 对外 TLS ≥1.2）；
///   - [NetworkHooks]：core 与 Riverpod 解耦的回调缝（KTD5），core 不
///     import lib/features，焊接在 `lib/features/auth/auth_network_wiring.dart`；
///   - [buildNetworkDio]：生产同款 dio 唯一构造函数，harness 与
///     [dioProvider] 共用，切真服务断言一行不改（R9）；
///   - 五拦截器按 §11.1 定死顺序装配，U3 仅安装 Header/Envelope，
///     Gzip/AuthRefresh/Retry 三位置以显式占位注释保留；
///   - 超时只引 [NfrNetwork] 常量（R12，不复制字面量）；
///     `validateStatus: (_) => true`（KTD2），所有 HTTP 状态进
///     EnvelopeInterceptor 统一拆信封。
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../nfr_constants.dart';
import 'device_id_provider.dart';
import 'interceptors/envelope_interceptor.dart';
import 'interceptors/gzip_interceptor.dart';
import 'interceptors/header_interceptor.dart';

export 'interceptors/envelope_interceptor.dart' show EnvelopeInterceptor;
export 'interceptors/gzip_interceptor.dart' show GzipInterceptor;
export 'interceptors/header_interceptor.dart' show HeaderInterceptor;

/// 网络配置（KTD8：baseUrl 与 release 判定的运行时注入缝）。
///
/// 为什么不用编译期常量直接装配：`String.fromEnvironment` 编译期固化，
/// 拿不到 MockApiServer 运行时随机端口；配置经运行时注入读取后，
/// 生产走 Provider 默认值、测试经 harness 构造参数注入真实端口与
/// 模拟 release 态（KTD8）。
class NetworkConfig {
  /// 构造网络配置并执行 release-https 守卫。
  ///
  /// 参数：
  ///   [baseUrl]   API 基址（含 `/api/v1` 前缀）；
  ///   [isRelease] release 包判定（由出包参数经注入缝提供，不引
  ///               `kReleaseMode`，保证测试可模拟两态）。
  /// 抛出：[StateError] —— release 且 baseUrl 非 https 时构造即失败，
  ///   不等到第一个请求才暴露明文流量（编码规范 §3.3）。
  NetworkConfig({required this.baseUrl, required this.isRelease}) {
    _assertReleaseHttps(baseUrl: baseUrl, isRelease: isRelease);
  }

  /// 生产默认配置：值全部来自 `--dart-define` 编译期注入。
  ///
  /// - `S2S_API_BASE_URL`：API 基址（命名沿用既有契约示范测试
  ///   `test/contract/api_contract_example_test.dart` 的先例，保证切真
  ///   服务时两处用同一个 define）；
  /// - `S2S_IS_RELEASE`：release 判定（`bool.fromEnvironment` 默认 false，
  ///   出包脚本必须显式传 `true`）。
  ///
  /// const 构造无法做运行时 https 校验：该守卫在 [buildNetworkDio]
  /// 装配时再执行一次 [assertReleaseHttps]，release 包配错 http 地址
  /// 仍在启动装配期快速失败，而非发出第一个明文请求。
  const factory NetworkConfig.production() = _ProductionNetworkConfig;

  /// `--dart-define` 的 baseUrl 变量名（全工程唯一真源）。
  static const String baseUrlEnvironmentKey = 'S2S_API_BASE_URL';

  /// `--dart-define` 的 release 判定变量名。
  static const String releaseEnvironmentKey = 'S2S_IS_RELEASE';

  /// API 基址（含版本前缀）。
  final String baseUrl;

  /// 是否 release 包（true 时强制 https）。
  final bool isRelease;

  /// release-https 快速失败守卫（KTD8 / 编码规范 §3.3）。
  ///
  /// 参数：
  ///   [baseUrl]   待校验基址；
  ///   [isRelease] release 判定。
  /// 返回：void；release 且基址非 https 时抛 [StateError]。
  static void assertReleaseHttps({
    required String baseUrl,
    required bool isRelease,
  }) {
    _assertReleaseHttps(baseUrl: baseUrl, isRelease: isRelease);
  }

  /// 守卫实现（构造与装配两处复用，避免两份判定，编码规范 §1.1）。
  static void _assertReleaseHttps({
    required String baseUrl,
    required bool isRelease,
  }) {
    if (isRelease && !baseUrl.startsWith('https://')) {
      throw StateError(
        'release 包禁止使用明文 HTTP baseUrl（必须 https，对外 TLS ≥1.2，'
        '编码规范 §3.3），实际：$baseUrl',
      );
    }
  }
}

/// 经编译期 define 构造的生产配置（[NetworkConfig.production] 的落地类）。
class _ProductionNetworkConfig implements NetworkConfig {
  /// const 构造：全部字段直接读取编译期环境值。
  const _ProductionNetworkConfig();

  @override
  String get baseUrl =>
      const String.fromEnvironment(NetworkConfig.baseUrlEnvironmentKey);

  @override
  bool get isRelease =>
      const bool.fromEnvironment(NetworkConfig.releaseEnvironmentKey);
}

/// core 网络层的可变依赖回调缝（KTD5：core 不感知 Riverpod）。
///
/// U3 只包含请求头注入实际需要的四个回调（计划 U3 任务口径）：
///   - [readToken]：读当前会话 Token，null/空串 = 未登录，不注入
///     Authorization（§11.2）；
///   - [readPrivacyConsented]：读隐私同意态，false 时不注入
///     X-Device-Id（PRD §6.5.1 硬门，每次请求实时读）；
///   - [readDeviceId]：读设备标识（同意门在拦截器侧，Provider 自身
///     惰性生成）；
///   - [newUuidV4]：UUID v4 生成器，做成可注入是为了让 §11.1.1
///     第 3 条断言（重试全链路 uuid.v4 只调 1 次）可机器计数。
///
/// U5 单飞续期需要的 writeToken/onSessionCleared/readSessionEpoch
/// （KTD5 四回调的另三个缝）在 U5 扩展本类，届时 AuthSessionNotifier
/// 同步补会话代次字段；U3 不预留未被消费的回调（不预建占位，
/// 计划 Scope Boundaries）。
class NetworkHooks {
  /// 构造回调缝。
  ///
  /// 参数：
  ///   [readToken]            异步读当前 Token；
  ///   [readPrivacyConsented] 异步读隐私同意态；
  ///   [readDeviceId]         异步读设备标识；
  ///   [newUuidV4]            同步产出新 UUID v4（生成频率需计数，
  ///                          保持同步以避免调用点误做缓存）。
  const NetworkHooks({
    required this.readToken,
    required this.readPrivacyConsented,
    required this.readDeviceId,
    required this.newUuidV4,
  });

  /// 读当前会话 Token；未登录返回 null。
  final Future<String?> Function() readToken;

  /// 读隐私同意态；仅 true 允许外发 X-Device-Id。
  final Future<bool> Function() readPrivacyConsented;

  /// 读设备标识（UUID v4）；尚未生成时由实现侧惰性生成。
  final Future<String?> Function() readDeviceId;

  /// 产出一个新的 UUID v4（交互 ID/幂等键兜底生成）。
  final String Function() newUuidV4;
}

/// 构造 `/map/pins` 的按请求选项（R12 / §14.1：读超时收紧为 3s）。
///
/// 收紧理由（§14.1）：`/map/pins` 承诺图层切换 P95，10s 才超时用户早已
/// 离开页面。以 Per-Request Options **只覆盖读超时**：连接超时不随单请求
/// 选项漂移，继续生效全局 5s。
///
/// 返回：[Options] receiveTimeout 引 [NfrNetwork.mapPinsReadTimeoutSec]，
///   不设置 connectTimeout/sendTimeout（保持继承 BaseOptions）。
Options mapPinsOptions() => Options(
  receiveTimeout: Duration(seconds: NfrNetwork.mapPinsReadTimeoutSec),
);

/// 生产同款 dio 唯一装配函数（harness 与 [dioProvider] 共用，R9）。
///
/// 参数：
///   [config] 网络配置（基址 + release 态）；
///   [hooks]  请求头注入所需回调缝。
/// 返回：[Dio] 已按 §11.1 顺序装配 U3 两个拦截器的实例。
Dio buildNetworkDio({
  required NetworkConfig config,
  required NetworkHooks hooks,
}) {
  // const 生产配置的构造期无法做运行时守卫，装配期补做（KTD8）。
  NetworkConfig.assertReleaseHttps(
    baseUrl: config.baseUrl,
    isRelease: config.isRelease,
  );

  final dio = Dio(
    BaseOptions(
      baseUrl: config.baseUrl,
      // KTD2：任何 HTTP 状态都不交给 dio 自动抛 badResponse，统一进
      // EnvelopeInterceptor.onResponse 先拆信封再分流（R8）。
      validateStatus: (_) => true,
      // R12：超时只引常量真源 NfrNetwork，不复制字面量（详设 §0.1）。
      connectTimeout: Duration(seconds: NfrNetwork.connectTimeoutSec),
      receiveTimeout: Duration(seconds: NfrNetwork.readTimeoutSec),
      // 请求/响应均按 JSON 处理；非 JSON（网关 HTML）由 dio 原样返回
      // String，EnvelopeInterceptor 的非 Map 分流负责（R8）。
      responseType: ResponseType.json,
    ),
  );

  // 拦截器顺序按详设 §11.1 定死（发出向）：
  //   1. Header → 2. Gzip → 3. Envelope → 4. AuthRefresh → 5. Retry。
  // dio 的 Interceptors.add 顺序即发出向执行序（计划 Assumptions，
  // U4 第一天实测三方向执行序并回写 §11.1 图注）。
  dio.interceptors.add(HeaderInterceptor(hooks));
  // 装配位 2（U4 已落地）：GzipInterceptor。第一天双实测结论已回写
  // §11.5/§11.1（2026-09-10）：dart:io HttpClient 默认自动协商 gzip 并
  // 自动解压，故拦截器不写 Accept-Encoding，只承担压缩前后体积统计
  // （R13）；禁止在此压缩请求体。
  dio.interceptors.add(const GzipInterceptor());
  dio.interceptors.add(const EnvelopeInterceptor());
  // 装配位 4（U5 落地）：AuthRefreshInterceptor。40101 单飞续期，
  // refresh 独立 dio 仅挂 Header+Envelope（KTD3）。
  // 装配位 5（U6 落地）：RetryInterceptor。全链路唯一重试点，
  // dio.fetch 重走全链（KTD4），传输层 DioException→networkFailure
  // 的唯一归一也在其 onError（KTD10），本单元不提前映射。
  return dio;
}

/// 设备标识 Provider（惰性单例；core 侧不感知持久化细节之外的状态）。
final deviceIdProvider = Provider<DeviceIdProvider>(
  (ref) => DeviceIdProvider(),
);

/// 应用网络配置注入缝（KTD8）。
///
/// 默认读生产编译期配置；测试与 mock 接线经 `overrideWithValue`
/// 注入 mock 基址/模拟 release 态。未 override 的非出包场景（如本地
/// 开发忘记传 define）baseUrl 为空串，首个请求即失败暴露配置缺失，
/// 不偷偷兜底默认地址。
final networkConfigProvider = Provider<NetworkConfig>(
  (ref) => const NetworkConfig.production(),
);

/// 应用回调缝注入缝（KTD5）。
///
/// core 不依赖 Riverpod 会话态：本 Provider 默认实现故意抛出，强制焊接
/// 必须由 features 侧（`wiredNetworkHooksProvider` override 本缝）
/// 完成——依赖方向保持 features → core 单向。
final networkHooksProvider = Provider<NetworkHooks>(
  (ref) => throw StateError(
    'networkHooksProvider 必须由 features 侧 override 注入'
    '（见 lib/features/auth/auth_network_wiring.dart，KTD5）',
  ),
);

/// 应用唯一 dio 实例（经 [networkConfigProvider]/[networkHooksProvider]
/// override 完成装配后使用）。
final dioProvider = Provider<Dio>((ref) {
  final dio = buildNetworkDio(
    config: ref.watch(networkConfigProvider),
    hooks: ref.watch(networkHooksProvider),
  );
  // 容器销毁时同步关闭 dio，避免拦截器持有回调闭包造成泄漏。
  ref.onDispose(dio.close);
  return dio;
});
