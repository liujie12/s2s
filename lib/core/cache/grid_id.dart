/// 约 500m 坐标网格 ID 算法（与服务端 {@code GridIdCalculator} / SQL 逐位一致）。
///
/// 这是全项目**唯一一处三方（Dart / Java / SQL）必须逐位一致**的算法（详设 §5.4.1）。
/// 不一致的后果不是报错，而是客户端缓存键与服务端缓存键错位、命中率长期偏低且查不出原因。
///
/// 算法四步（顺序不可调换）：
///   1. 先把坐标向下取整到 5 位小数：`floor(deg * 100000) / 100000`
///   2. 转入【整数微度域】运算，避免浮点累积误差
///   3. 以 450 微度（0.0045°，约 500m）为步长，用 floor（向负无穷）取整
///   4. 编码为 "{gx}_{gy}"
///
/// 两处 Dart 特有陷阱（Java 侧不存在，代码不能照抄 Java）：
/// - 向下整除：Dart 的 `~/` 对负数向零截断，须用 `(a / b).floor()`（Java 用 `Math.floorDiv`）
/// - 向下取整：Dart 的 `.toInt()` 对负数向零截断，须用 `.floor()`（Java 用 `(long) Math.floor`）
library;

/// 微度换算比例：1 度 = 100000 微度。
const double _microDegreeScale = 100000.0;

/// 网格步长（微度）：0.0045° = 450 微度 ≈ 500m。
const int _stepMicro = 450;

/// 浮点补偿量：补偿 `deg * 100000` 的二进制舍入误差。
///
/// 与服务端 {@code GridIdCalculator.FLOOR_EPSILON} 逐字同值（1e-9）。理由同 Java：
/// 0.00450 的 double 表示略小于 0.0045，乘积得 449.99999999999994，直接 floor 会误得
/// 449 而非 450（测试向量第 3 条 `0.00450 → "1_1"` 依赖此补偿）。量级远小于 1 微度，
/// 不影响真实边界判定。
const double _floorEpsilon = 1e-9;

/// 计算约 500m 网格的 grid_id（与服务端 {@code GridIdCalculator.of} 逐位一致）。
///
/// [lng] GCJ-02 经度
/// [lat] GCJ-02 纬度
/// 返回：形如 "26700_6728" 的网格标识，负数保留减号（正则 `^-?\d+_-?\d+$`）
String gridIdOf(double lng, double lat) {
  final int lngMicro = floorToMicroDegree(lng);
  final int latMicro = floorToMicroDegree(lat);
  // 必须用 (a / b).floor() 而非 ~/：~/ 对负数向零截断，南半球/西半球坐标网格全错。
  final int gx = (lngMicro / _stepMicro).floor();
  final int gy = (latMicro / _stepMicro).floor();
  return '${gx}_$gy';
}

/// 将度数向下取整到 5 位小数并转为整数微度（1 微度 = 1e-5 度）。
///
/// 必须用 `.floor()` 而非 `.toInt()`：`.toInt()` 对负数向零截断，会让 -0.000015 落到 0
/// 而不是 -1（测试向量第 9 条冲突）。
///
/// 本函数声明为公开（而非 `_` 私有）仅为一个目的：供测试断言第 9 条向量的**中间微度值**
/// 为 -2——只断言最终 grid_id 会漏掉「用截断代替 floor」的 bug（结果偶然正确）。
///
/// [deg] 度数
/// 返回：向下取整到 5 位小数的整数微度值
int floorToMicroDegree(double deg) => (deg * _microDegreeScale + _floorEpsilon).floor();
