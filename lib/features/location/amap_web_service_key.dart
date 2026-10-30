/// 高德 Web 服务 Key 的唯一读取处（KTD5 / 实施约束）。
///
/// **为什么收敛到一处**：逆地理、POI 候选、驾车路径三个客户端共用同一个
/// 构建期 Key。若各自写一份 `String.fromEnvironment`，注入变量名一旦改动
/// 或某处漏改，表现是「地图能看，但地址/候选/距离里有一个永远空白」——
/// 且没有任何编译期提示。故全工程只允许本文件出现 `String.fromEnvironment`。
///
/// **安全口径**：含 Key 的完整 URL 不得进入日志、异常文案与埋点。本文件的
/// 值只允许拼进请求 URI，调用方不得把 URI 打出来。
library;

/// 高德 Web 服务 Key 的 `--dart-define` 变量名（全工程唯一真源）。
///
/// 与地图 Android Key 不同链路：它是 Web 服务（逆地理/输入提示/路径规划）
/// 凭证，只经构建期注入，不入仓库。
const String kAmapWebServiceKeyDefine = 'AMAP_WEBSERVICE_KEY';

/// 构建期注入的高德 Web 服务 Key（未注入时为空串）。
const String _amapWebServiceKey = String.fromEnvironment(
  kAmapWebServiceKeyDefine,
);

/// 测试缝：非 null 时覆盖构建期注入的 Key。
///
/// **为什么需要**：请求侧降级（非 200、超时、异常）只有真的发出请求才能覆盖，
/// 而 `String.fromEnvironment` 是编译期常量，测试进程里恒为空串。生产代码不得
/// 读写本变量；测试须在 `tearDown` 里置回 null。
String? amapWebServiceKeyOverride;

/// 当前生效的高德 Web 服务 Key（未注入时为空串）。
///
/// 返回：Key 明文；只允许用于拼请求参数，不得写进日志或异常文案。
String get amapWebServiceKey => amapWebServiceKeyOverride ?? _amapWebServiceKey;

/// 当前是否已配置高德 Web 服务 Key。
///
/// 返回：bool；false 时所有依赖它的客户端都不发请求，直接走空结果降级
///   （与逆地理「不可用即空」同一口径）。
bool get amapWebServiceKeyConfigured => amapWebServiceKey.isNotEmpty;
