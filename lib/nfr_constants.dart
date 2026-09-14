/// NFR 数字常量集中真源（PRD §6.10 / §6.15 / §12 / §14 + 2026-09-02 缺陷评审定案）。
///
/// **为什么需要这个文件**：PRD 的 §12/§13/§14 是结构化 Markdown 表格，人读得懂，
/// 机器读不了。从 PRD 到代码只有「照着表格手敲」一条通路，而这 21 个数字里有 18 个
/// 分布在缓存层、埋点层、接口层 —— 这三层当前尚未实现。也就是说漂移还没发生，
/// 但一旦这三层开写，同一个数字会被三处各敲一遍。本文件把它们收成一处，
/// PRD 表格标注「值以此为准」，消费方一律引用而不复制字面量。
///
/// **与 design_tokens.dart 的分工**：那份管视觉 Token（颜色/字号/间距），由
/// `prototype-figma/export-dart-tokens.js` 从 `code.js` 真源生成、`probe-token-vars.py`
/// 断言校验；本份管 NFR 数字（时延/体积/容量/阈值），**当前为手写**。
///
/// **为什么手写而不上生成脚本**：写 Markdown 表格解析器的成本，在 21 项里有 18 项
/// 还没有任何代码消费方的当下不划算。Batch2 接口面变宽（后台 7 页 + LR/GBDT +
/// 双向推送同时在做）后再照 design_tokens 那套上脚本 + 断言。
///
/// **改动纪律（2026-09-02 定案）**：本文件任一常量改动，必须同时改 PRD 对应行，
/// 缺一即视为未改。否则真源又变成两个，比没有真源更糟 —— 那时两处都"看起来是权威"。
///
/// **注释里的 PRD 行号**：截至 2026-09-02 核实。行号会随 PRD 编辑漂移，
/// 故每条同时给出章节号（§x.y），章节号比行号稳定，行号仅作快速定位用。
library;

/// §14.1 性能指标（PRD:2296-2304）。
///
/// 这些是「判定线」而非「配置项」—— 它们出现在 §14.6 NFR 验收清单里，
/// 改动等于改对外承诺，不是调参。
class NfrPerf {
  const NfrPerf._();

  /// 分类图层切换耗时上限（毫秒）。PRD §14.1 / §6.10（PRD:2298）。
  ///
  /// 口径是四段之和：本地缓存查找 → 网络请求 → Dart 侧聚合 → Pin 渲染上屏。
  /// 计时起点＝手指离开分类 Tab，终点＝Pin 首屏绘制完成（PRD:1342）。
  ///
  /// **2026-09-02 定案**：本值降为工程 SLA（§14 发布门禁 + P95 告警线），
  /// 不再作为北极星轴②的判定基准 —— 轴②改用单次布尔口径，见 [NorthStar]。
  static const double layerSwitchP95Ms = 300;

  /// 读接口服务端响应上限（毫秒）。PRD §14.1 / §6.10（PRD:2299）。
  ///
  /// 是 [layerSwitchP95Ms] 的子指标，单列上报。未命中缓存时若超此值，
  /// 整体 300ms 必然超标。
  static const double readApiRtP95Ms = 150;

  /// 冷启动预渲染：条数上限与耗时上限。PRD §6.10 第 1 层（PRD:2300）。
  ///
  /// 打开 APP 瞬间后台一次性预渲染 5 大类聚合 Marker，1000 条以内不超过 50ms。
  static const int prerenderMaxItems = 1000;
  static const double prerenderBudgetMs = 50;

  /// 单帧耗时判据线（毫秒），即 60fps。PRD §14.1（PRD:2301）。
  ///
  /// 统计量取 P95 而非平均值 —— 平均值会把偶发长帧摊平，
  /// 而用户感知的卡顿恰恰来自长帧。
  static const double frameBudgetMs = 16;

  /// 地图取数接口单次响应体积上限（字节），**口径为压缩后 over-the-wire 字节数**。
  /// PRD §14.1 / §12.1 / §6.10 第 2 层（PRD:2355）。
  ///
  /// **2026-09-02 定案（缺陷第 4 条）**：原文未定义压缩前后，且与 [renderMaxPins]
  /// 算不通 —— 6 字段对象式 JSON 实测单 Pin 约 118 字节，500 条约 57.6KB，
  /// 是 10KB 的 5.8 倍；而 10240÷500≈20.5 字节/Pin，仅六个字段名加引号冒号
  /// 就已 60 字节，预算的 3 倍还没开始装数据。
  ///
  /// 定案取「压缩后」口径：本值存在的目的是控制 300ms 里的网络段耗时，
  /// 而网络上跑的就是压缩后的字节。同时四项优化叠加把原始体积压到
  /// [mapPayloadMaxRawBytes] 以内，给弱网留余量。
  static const int mapPayloadMaxBytes = 10 * 1024;

  /// 地图取数响应**未压缩**原始体积上限（字节）。PRD §12.1（2026-09-02 新增）。
  ///
  /// 四项优化叠加后的实测目标：gzip + 数组化紧凑格式 + 坐标 5 位小数 +
  /// 枚举转 int，原始约 22KB、gzip 后约 4–5KB，对 [mapPayloadMaxBytes] 有一倍余量。
  ///
  /// 设这条原始上限而不只看压缩后，是因为压缩后体积依赖数据分布（同类目 Pin 密集
  /// 时压缩比高、稀疏时低），只卡压缩后会在最坏分布下失守。
  static const int mapPayloadMaxRawBytes = 24 * 1024;

  /// `/map/pins` 响应中坐标的小数位数。PRD §12.1 坐标行（2026-09-02 定案）。
  ///
  /// 5 位约 1m 精度，Pin 定位足够，且 §6.4.3 本就要求隐私模糊化。
  /// 详情页与发布接口仍用 6 位（那里需要精确回显用户所选点）。
  static const int mapPinCoordDecimals = 5;

  /// 单次渲染 Pin 数上限。PRD §14.1 / §6.7 / §6.8（PRD:2356）。
  ///
  /// **2026-09-02 定案（缺陷第 4 条）**：聚合切换点由「`total>500` 点数开关」
  /// 改为「按 `zoom` 缩放层级」。原开关让达标区间为空 —— 客户端聚合的前提是
  /// 拿到全部原始 Pin，而体积爆掉的临界点恰好也是 500。
  ///
  /// 远景（metersPerPixel 大于阈值）服务端预聚合只返 `clusters[]`；近景返紧凑
  /// `pins[]` 走客户端 Dart 聚合。理由：远景时用户在屏幕上分辨不出单点，
  /// 传原始 Pin 纯浪费带宽；近景时可见范围内点本就少，正好让客户端聚合的
  /// 实测优势（说明文档：5 万点聚合 4.73ms）继续生效。
  ///
  /// **2026-09-02 定案（缺陷第 10 条）**：删除「性能降级时把上限降至 500」
  /// 这个动作 —— 它等于常态值，降级等于没做，且 PRD:1389 已自我否定该方向。
  static const int renderMaxPins = 500;

  /// 服务端预聚合与客户端聚合的切换阈值（米/像素）。
  ///
  /// ⚠️ **待 §6.10.1 Batch1 POC 实测确定**。此处暂填 30，依据是初始缩放为
  /// 12 m/px（map_screen.dart）、约 2.5 倍缩出后单点已难分辨。
  /// POC 出结论后回改本行并同步 PRD §12.3。
  ///
  /// POC 证据（2026-09-10）：POC-A 复跑复现 4.73ms 基线（5 万点聚合 5.51ms，
  /// 两档线性 PASS），POC-B 开发机 CPU 基准未见超线性回潮——客户端算力不是
  /// 阈值约束，建议校准区间 10–30 m/px，推导见
  /// docs/poc/2026-09-10-cluster-poc-conclusion.md；终值真机校准见 [126]。
  static const double clusterModeSwitchMetersPerPixel = 30;


  /// 聚合网格边长（逻辑像素）。
  ///
  /// **2026-09-02 定案**：本值原先只存在于代码（map_screen.dart），PRD 只说
  /// 「按屏幕像素网格归并」而未给边长。经评审补入 PRD §6.15。
  ///
  /// 60 略大于单点 Marker 直径 40px：小于直径会让「聚不起来的两个点」在视觉上
  /// 依然重叠，聚合等于没做；过大则相隔很远的点也被聚成一簇。
  static const double clusterGridSizePx = 60;
}

/// §6.10 三级缓存 + §12 传输层约定。
class NfrCache {
  const NfrCache._();

  /// Pin 集合缓存 TTL（秒）。
  ///
  /// **2026-09-02 定案（缺陷第 7 条）**：原按类目层级分档 1h/15min/5min，
  /// 但缓存键五要素（PRD:1347-1355）中无任何一项随「帖子集合变化」而变 ——
  /// 版本号只随运营改分类树变。后果是新发布最长 1h 别人看不见、
  /// 已下架 Pin 最长 1h 仍在图上，与 §9.10.3「风险分≥60 自动下架 + 4h 工单 SLA」
  /// 的治理承诺直接冲突。
  ///
  /// 故 TTL 改按「内容易变性」而非「类目层级」分档：易变的 Pin 集合压到 60s，
  /// 与 PRD:1731「后台每分钟轮询 expire_at」天然对齐；静态数据保留原分档，
  /// 见 [staticL1TtlSec] 等。
  static const int pinSetTtlSec = 60;

  /// 静态数据（分类树/样式等）TTL（秒）。PRD §6.10 第 3 层（PRD:1338）。
  ///
  /// 一级 1 小时 / 二级 15 分钟 / 三级 5 分钟。这三档管的是「不随发布下架变」
  /// 的数据，故可以放长。
  static const int staticL1TtlSec = 3600;
  static const int staticL2TtlSec = 900;
  static const int staticL3TtlSec = 300;

  /// 单设备缓存键容量上限，超出按 LRU 淘汰。PRD §6.10（PRD:1358）。
  static const int maxKeys = 50;

  /// 缓存键中坐标网格的取整边长（米）。PRD §6.10 缓存键五要素（PRD:1354）。
  ///
  /// ⚠️ 注意与 [NfrPerf.clusterGridSizePx] 区分：本值是**缓存键的地理网格**
  /// （避免移动几十米就全量失效），前者是**聚合的屏幕像素网格**。
  /// 两者量纲不同、用途不同，PRD 中表述含混（2026-09-02 缺陷第 5 条），
  /// 此处按用途分开命名以防再次混淆。
  static const double keyGridMeters = 500;

  /// 运营改分类配置后客户端拉到新版本号并清缓存的时限（秒）。
  /// PRD §9.10.1 后台验收标准（PRD:2025 / :1870 / :2318）。
  static const int configPropagateSec = 3;
}

/// §12.1 接口传输层约定（PRD:1972-1984）。
class NfrApi {
  const NfrApi._();

  /// 列表分页默认页大小与上限。PRD §12.1（PRD:1981）。
  static const int pageSizeDefault = 20;
  static const int pageSizeMax = 50;

  /// 写接口幂等键的服务端记忆窗口（小时）。PRD §12.1（PRD:1978）。
  ///
  /// 所有写接口须带 `Idempotency-Key`（客户端 UUID），
  /// 服务端 24h 内重复键直接返回首次结果。
  static const int idempotencyWindowHours = 24;

  /// 埋点批量上报单次条数上限。PRD §12.4（PRD:2117）。
  ///
  /// **2026-09-02 定案（缺陷第 9 条）**：`layer_switch` 补齐四段分列
  /// （t_cache/t_net/t_agg/t_render）+ result + fail_reason + err_code 后，
  /// 单条体积约涨 60%，但**采用全量上报不采样** —— 图层切换非高频动作，
  /// 且这是北极星唯一的量化轴，采样会损失 P95 精度，而 P95 是告警依据。
  static const int trackBatchMaxEvents = 50;
}

/// §14.1 网络层超时 / 重试 / 退避参数（详设:1384-1391）。
///
/// **为什么单建这个类（2026-09-10，计划 KTD6）**：这些参数此前只存在于详设
/// §14.1 的文字表格里，没有常量承载 —— 按「不复制字面量」硬纪律（详设 §0.1），
/// 网络层（dio BaseOptions、RetryInterceptor 退避表）一旦开写就会各敲一遍。
/// 消费方一律引用本类常量名，不得复制字面量。
///
/// **改动纪律**：任一本类常量改动，必须同时改详设 §14.1 对应行（同步方向与
/// 本文件头部纪律一致，只是本类口径源是详设而非 PRD）。
class NfrNetwork {
  const NfrNetwork._();

  /// 连接超时（秒）。详设 §14.1（详设:1388）。
  static const int connectTimeoutSec = 5;

  /// 读取超时（秒）。详设 §14.1（详设:1389）。
  static const int readTimeoutSec = 10;

  /// `/map/pins` 读取超时（秒，收紧档）。详设 §14.1（详设:1390）。
  ///
  /// 收紧理由（详设原文）：`/map/pins` 承诺 P95 ≤ [NfrPerf.layerSwitchP95Ms]，
  /// 10s 才超时时用户早已离开页面。按请求 Options 覆盖，不改全局读取超时。
  static const int mapPinsReadTimeoutSec = 3;

  /// 全链路重试总次数（首发之外）。详设 §14.1（详设:1386）。
  ///
  /// 是**全链路总数**，不是每层 2 次 —— 网络层与业务层双重试会把次数放大成
  /// 4–9 次（详设 §14.2 禁止事项第 1 条）。`RetryInterceptor` 是全局唯一
  /// 重试点，本值只被它引用。
  static const int retryMaxCount = 2;

  /// 第 1 次重试的退避基数（秒）。详设 §14.1（详设:1387）。
  ///
  /// 服务端 `Retry-After` 响应头（整数秒）**优先级高于本退避表**
  /// （详设 §14.1 末行）：服务端给了秒数就用服务端的。
  static const int backoffFirstSec = 1;

  /// 第 2 次重试的退避基数（秒）。详设 §14.1（详设:1387）。
  static const int backoffSecondSec = 2;

  /// 退避抖动幅度（±百分比）。详设 §14.1（详设:1387）。
  ///
  /// 抖动防止大量客户端同时重试形成第二波冲击（详设原文）。
  static const int retryJitterPercent = 20;

  /// 自动重试路径接受 `Retry-After` 的**上界**（秒）。
  ///
  /// 取值 900 = 15 分钟，对齐 PRD §12.5 中最长已知服务端等待窗口
  /// （`40105` 登录失败锁定 15 分钟）：客户端后台无人值守的自动重试
  /// 等待不应超过「用户可感知的最长锁定」量级；超过此值的服务端/网关
  /// 指令按本值钳制，避免一次异常响应头（如 `999999999`）把重试
  /// `Timer` 挂起数年（评审 #8，validator 已实证 Dart 接受该 Timer
  /// 参数）。
  ///
  /// 边界分工：本上界**只夹自动重试 sleep 时长**（RetryInterceptor），
  /// 不夹 429 段 UI 倒计时——`42902` 等限流码不自动重试，
  /// `ApiException.retryAfterSec` 承载服务端原始指令（可能合法地为
  /// 3600s），解析纯函数不钳制。
  ///
  /// 待裁定（决策项 **DEC-01**，见《说明文档.md》§2.9 gap-register）：
  /// 详设 §14.1 与 PRD 均未明文「客户端自动等待上界」，本值为编码期防御
  /// 上限（取最长已知窗口，PRD §12.5 的 40105 锁定 15 分钟）。owner=产品/
  /// 详设维护者；触发事件=详设 §14.1 下次评审 / PRD §12.5 窗口口径变更 /
  /// 429 UI 倒计时语义变更（先到者触发）。裁定后按 §2.9 动作清单回写
  /// 本注释、详设 §14.1 表格与测试期望，三处同改。
  static const int retryAfterMaxSec = 900;
}

/// §0.2 北极星三轴 + 2026-09-02 阶梯定案。
class NorthStar {
  const NorthStar._();

  /// 全期不可跌破的乘积底线。PRD §0.2（PRD:32）。
  ///
  /// **2026-09-02 定案**：0.216 保留为全期底线不变（三份文档共 19 处引用均不动），
  /// 但「全期统一」四字作废 —— 改为分阶段目标值，见 [layerLoadTargetByPhase]。
  /// 依据是 PRD 自己已经在分阶段：BRD:240 的 Batch1 里程碑写的是
  /// 完整发布率 ≥0.75 而非 0.6。
  static const double productFloor = 0.216;

  /// 轴② 分类图层加载成功率的阶段目标。
  ///
  /// **2026-09-02 定案（缺陷第 6 条）**：原口径「P95 耗时 ≤300ms 的会话占比」
  /// 在数学上不成立 —— P95 是一批会话的分布统计量，「会话占比」要求每个会话
  /// 各自有真假值，而单个会话没有 P95。且若 P95 真 ≤300ms，按定义至少 95%
  /// 会话达标，轴② 应 ≥0.95 而非 0.6；写 0.6 实际是 P60≤300ms。
  ///
  /// 故轴② 改为**单次布尔口径**：单次切换 `duration_ms ≤ 300ms` 即成功。
  /// P95≤300ms 剥离为工程 SLA（[NfrPerf.layerSwitchP95Ms]），两者彻底分开。
  ///
  /// 阶梯依据不是拍的，是能力到位时间：Batch1 缓存全冷 + 降级开关未实施 +
  /// 高德 Key 未到位；Batch2 缓存已热且五要素键跑满一个批次；
  /// M3 预计算与 AI 移出读路径已落地。
  ///
  /// **纪律**：阶梯只升不降；各阶段值在该批次启动前锁定；批次内不得因实测
  /// 不达标而下调本批次目标，只能改下一批次 —— 这条直接堵掉 PRD:2306
  /// 「POC 不通过则按实测改写 SLA」那条后路。
  static const Map<String, double> layerLoadTargetByPhase = {
    'batch1': 0.6,
    'listing_window': 0.7,
    'batch2': 0.8,
    'm3': 0.9,
  };

  /// 轴① AI 匹配召回率目标。PRD §0.2 / BRD:242。
  ///
  /// 本轴一个字都不动 —— AI 是飞轮主轮。Batch1 未上线填 0（冷启动观察期
  /// 不考核，PRD:45），Batch2 起正式纳入考核。
  static const double aiRecallTarget = 0.6;

  /// 轴③ 完整发布率目标。BRD:240 Batch1 里程碑已定 0.75。
  static const double completePublishTarget = 0.75;

  /// 轴① 召回判定窗口（分钟）与推送广度。PRD §0.2（PRD:27）/ §14.1（PRD:2304）。
  ///
  /// 口径：需求发布后 5min 内被推送到 Top20 资源方中，
  /// 至少 1 个资源方点击查看该需求详情。
  ///
  /// **2026-09-02 定案（缺陷第 7 条附加）**：点击时该帖须**仍在架**才计成功。
  /// 否则脏 Pin 越多轴① 越高 —— 反向激励。
  static const int recallWindowMin = 5;
  static const int pushTopNResource = 20;
  static const int pushTopNDemand = 30;

  /// 轴① 分母生效门槛：同城同二级类目在库有效资源条数。PRD §0.2（PRD:28）。
  ///
  /// 不足此数的发布不计入召回率分母，单独归入「供给不足占比」。
  ///
  /// **2026-09-02 定案（缺陷第 14 条）**：本门槛按**二级类目**统计，
  /// 且 §6.12 Hard Filter 已由三级放宽为二级，**分子分母粒度自此一致**。
  /// 修改前务必确认与 [NfrMatch.hardFilterCategoryLevel] 同级 —— 两者一旦
  /// 错位，会让「二级够 20 条但三级仅数条」的发布注定填不满 Top20 却照样
  /// 占据分母，使轴① 系统性偏低且偏差在数值上不可归因。
  static const int recallDenominatorMinSupply = 20;

  /// 双向推送触达时延上限（分钟）。PRD §14.1（PRD:2304）。
  static const int pushLatencyMin = 1;
}

/// §6.12 T1 匹配的 Hard Filter 与精排粒度。
///
/// **2026-09-02 缺陷评审第 14 条定案**：Hard Filter 类目粒度由三级放宽为二级，
/// 三级降为精排软特征。三条理由（详见 PRD §6.12）：
/// 1. 原三级是全 PRD 唯一孤例，§0.2 分母 / 单用户冷启动 / 单类目回落三处均按二级，
///    导致分母按二级算、分子按三级筛；
/// 2. §2.4 实际 21 个二级 / 48 个三级，三级粒度永远够不到「单类目 ≥2000 条」门槛；
/// 3. 主卧/次卧、日常保洁/深度清洁高度可替代，三级硬过滤把该由模型判断的
///    相关性提前用硬条件写死。
class NfrMatch {
  const NfrMatch._();

  /// Hard Filter 的类目层级：2 = 二级类目。
  ///
  /// 硬过滤三条件为「同城 + 同二级类目 + 同供需态」，缺一即排除。
  /// **改动本值等于改动产品匹配语义**，须同步 PRD §6.12 与 §0.2 分母口径。
  static const int hardFilterCategoryLevel = 2;

  /// 三级类目相关性系数：同三级 ×1.0，同二级不同三级 ×0.7。
  ///
  /// 这是 Hard Filter 放宽后精度不下降的**唯一保障**，不得省略。
  /// 系数值待 Batch2 双轨灰度期按实际点击率校准，校准后须回写 PRD §6.12。
  static const double leafCategoryMatchBoost = 1.0;
  static const double leafCategoryMismatchBoost = 0.7;

  /// 单类目建模样本量门槛（§6.12 冷启动阶段 2）。
  ///
  /// **粒度为二级类目**（第 14 条定案后不再设「三级→二级」回落层）。
  static const int categoryModelMinSamples = 2000;
}

/// §6.10.1 性能降级开关触发条件（预留，本期不实施 —— PRD:2379）。
class NfrDegrade {
  const NfrDegrade._();

  /// 连续超预算帧数触发阈值。PRD §6.10.1（PRD:1403）。
  static const int consecutiveJankFrames = 3;

  /// P95 触发阈值（毫秒）。PRD §6.10.1（PRD:1403）。
  static const double p95TriggerMs = 800;
}

/// §5 发布有效期。PRD §5（PRD:898 / :963）。
class NfrPostLifecycle {
  const NfrPostLifecycle._();

  /// 默认有效期（天），可一键刷新续期。
  static const int validDays = 7;

  /// 连续未刷新即自动下架的天数。
  static const int autoArchiveDays = 14;
}
