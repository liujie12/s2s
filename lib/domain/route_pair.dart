/// 起终点地点对（计划 KTD1 / R3 / R7 / R11）。
///
/// **为什么是一个嵌套对象而不是两个字段**：二期要按两端坐标做索引与路线匹配，
/// 嵌套对象可以直接建表达式索引，而「起点文本 + 终点文本」两列做不到。落库位置
/// 仍是现有 `attributes` JSON 列，不改表结构（KTD1）。
///
/// **为什么解析全部走「失败即空」**：`attributes.route` 里同时存在历史字符串
/// （AI 猜测 / 旧草稿 / 存量帖）与新的对象形态。解析器一旦对缺失字段抛错，
/// 一条旧帖就能把详情页打崩；而把半截对象当成已填，发布页会放行没有终点的
/// 拼车帖。故：[fromJson] 缺关键结构返回 null，[parseAttribute] 对字符串返回
/// null 交调用方按文本渲染，坐标类型不符只让该端 [RoutePlace.isLocated] 为假。
library;

/// 一个地点（起点或终点）：名称 + 展示用地址 + GCJ-02 坐标。
///
/// [name] 是用户看到的主值（「回龙观」「我的位置」），[address] 是副文
/// （逆地理或 POI 的地址描述）。坐标缺失（如定位被拒）时 [isLocated] 为假，
/// 但对象仍可承载名称 —— 选择页需要展示「我的位置」却暂时没有坐标的情形。
class RoutePlace {
  /// 构造地点。
  ///
  /// 参数：[name] 主值名称；[address] 副文地址描述（可空串）；
  /// [lng]/[lat] GCJ-02 坐标（可空，null 表示该端尚未定位）。
  const RoutePlace({
    required this.name,
    this.address = '',
    this.lng,
    this.lat,
  });

  /// 由对象形态解析一个地点。
  ///
  /// 参数：[raw] `attributes.route.origin` / `.destination` 的原始值。
  /// 返回：地点对象；入参不是 Map 时返回 null。字段缺失或类型不符一律
  ///   降级为默认值（名称空串、坐标 null），**不抛异常**。
  static RoutePlace? parse(Object? raw) {
    if (raw is! Map) return null;
    return RoutePlace(
      name: _asString(raw['name']),
      address: _asString(raw['address']),
      lng: _asDouble(raw['lng']),
      lat: _asDouble(raw['lat']),
    );
  }

  /// 地点主值名称（「我的位置」「回龙观」）。
  final String name;

  /// 地点地址描述（逆地理或 POI 地址，可能为空串）。
  final String address;

  /// 经度（GCJ-02）；null 表示该端没有坐标。
  final double? lng;

  /// 纬度（GCJ-02）；null 表示该端没有坐标。
  final double? lat;

  /// 是否已定位（两个坐标都齐备）。
  ///
  /// 这是「这一端算不算选好了」的唯一判据：名称单独存在不算 —— 没有坐标就
  /// 建不了索引，也算不了距离。
  bool get isLocated => lng != null && lat != null;

  /// 序列化为 `attributes.route.origin` / `.destination` 的形态。
  ///
  /// 返回：Map；坐标缺失时不写 `lng`/`lat` 键（不写 null 占位，避免读取方
  ///   把「有键但为空」误当成有值）。
  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    if (address.isNotEmpty) 'address': address,
    if (lng != null) 'lng': lng,
    if (lat != null) 'lat': lat,
  };

  @override
  bool operator ==(Object other) =>
      other is RoutePlace &&
      other.name == name &&
      other.address == address &&
      other.lng == lng &&
      other.lat == lat;

  @override
  int get hashCode => Object.hash(name, address, lng, lat);
}

/// 一次选择的起终点对：两个地点 + 可选的驾车距离与时长。
///
/// 距离与时长是**展示值**，服务端不重算、也不据此做校验（KTD6）：每次两端
/// 齐备（换点、交换）都重新请求，失败就隐藏，不缓存。
class RoutePair {
  /// 构造起终点对。
  ///
  /// 参数：[origin] 起点；[destination] 终点；[distanceM] 驾车里程（米，
  /// 可空）；[durationS] 驾车时长（秒，可空）。
  const RoutePair({
    required this.origin,
    required this.destination,
    this.distanceM,
    this.durationS,
  });

  /// 由对象形态解析起终点对。
  ///
  /// 参数：[json] `attributes.route` 的原始值。
  /// 返回：起终点对；**不是 Map、或缺少 origin/destination 任一端时返回
  ///   null**（缺一端不是一条路线，交调用方按「未填写」处理）。两端对象在
  ///   但坐标不全时仍返回对象，由 [isComplete] 回答「够不够提交」。
  static RoutePair? fromJson(Object? json) {
    if (json is! Map) return null;
    final origin = RoutePlace.parse(json['origin']);
    final destination = RoutePlace.parse(json['destination']);
    if (origin == null || destination == null) return null;
    return RoutePair(
      origin: origin,
      destination: destination,
      distanceM: _asInt(json['distance_m']),
      durationS: _asInt(json['duration_s']),
    );
  }

  /// 解析 `attributes.route` 的两种历史形态（KTD1）。
  ///
  /// 参数：[raw] 属性原始值：对象形态或历史字符串。
  /// 返回：对象形态解析出的 [RoutePair]；**字符串形态返回 null**，由调用方
  ///   按文本键原样渲染（存量帖不能被吞掉，也不能被当成结构化两点）。
  static RoutePair? parseAttribute(Object? raw) {
    if (raw is! Map) return null;
    return fromJson(raw);
  }

  /// 起点。
  final RoutePlace origin;

  /// 终点。
  final RoutePlace destination;

  /// 驾车里程（米）；null 表示未取到或请求失败。
  final int? distanceM;

  /// 驾车时长（秒）；null 表示未取到或请求失败。
  final int? durationS;

  /// 两端是否都已定位 —— 发布必填与「位置精确」共用的判据（KTD3/KTD4）。
  bool get isComplete => origin.isLocated && destination.isLocated;

  /// 交换起点与终点。
  ///
  /// 返回：两端互换后的新对象；距离与时长**不携带** —— 反向路线的数值
  ///   不同，必须由调用方重新请求（R4 / KTD6）。
  RoutePair swapped() =>
      RoutePair(origin: destination, destination: origin);

  /// 序列化为 `attributes.route` 的对象形态。
  ///
  /// 返回：Map；没有距离/时长时不写 `distance_m`/`duration_s` 键。
  Map<String, Object?> toJson() => <String, Object?>{
    'origin': origin.toJson(),
    'destination': destination.toJson(),
    if (distanceM != null) 'distance_m': distanceM,
    if (durationS != null) 'duration_s': durationS,
  };

  @override
  bool operator ==(Object other) =>
      other is RoutePair &&
      other.origin == origin &&
      other.destination == destination &&
      other.distanceM == distanceM &&
      other.durationS == durationS;

  @override
  int get hashCode => Object.hash(origin, destination, distanceM, durationS);
}

/// 宽松读取字符串字段：非字符串一律空串（不抛错）。
///
/// 参数：[value] 原始值。返回：字符串或其空串降级。
String _asString(Object? value) => value is String ? value.trim() : '';

/// 宽松读取数值字段：非数值一律 null（不抛错）。
///
/// 参数：[value] 原始值。返回：double，或 null 表示缺失/类型不符。
double? _asDouble(Object? value) => value is num ? value.toDouble() : null;

/// 宽松读取整数字段：非数值一律 null（不抛错）。
///
/// 参数：[value] 原始值。返回：int，或 null 表示缺失/类型不符。
int? _asInt(Object? value) => value is num ? value.toInt() : null;
