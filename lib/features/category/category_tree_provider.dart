/// 分类树状态层（[124] B2）：版本协商缓存 + DTO→domain 转换 +
/// 「版本变更清 Pin 缓存」联动口子。
///
/// 数据流（契约 `GET /categories/tree` 版本协商 + 详设 §16 缓存口径）：
///   启动/首次 watch → 读 [CategoryTreeStore] 缓存（有则先渲染，不等网络）
///   → 携本地版本号请求 → 版本一致（unchanged，304 语义）保持缓存；
///   不一致（全量下发）→ 替换 state、覆盖缓存、逐一调用
///   [pinCacheInvalidatorsProvider] 登记的 Pin 缓存清理回调。
///
/// 为什么「有缓存时刷新失败静默保持」：分类树是低频变更的只读数据，
/// 缓存可服务即不构成错误态；契约亦明写本端点「永不报错」。首启无缓存
/// 又拿不到树才是错误态（选择器无法工作，须给重试入口）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhaoyazhao/core/network/api_exception.dart';
import 'package:zhaoyazhao/domain/category_tree.dart';
import 'package:zhaoyazhao/domain/publish_template.dart' show requiredCertForLeaf;

import 'category_dto.dart';
import 'category_repository.dart';

/// 分类树本地缓存（shared_preferences 键值层 <10KB，详设 §16 三层存储；
/// 队列与 Pin 缓存禁放本层）。
///
/// 存取形态：整棵 [CategoryTreeDto] 的契约 JSON 单键存储——恢复路径与
/// 网络路径共用同一份 [CategoryTreeDto.fromJson] 校验，缓存损坏
/// （JSON 截断/结构违约）即删键按「无缓存」降级，不留坏键让每次启动
/// 白解析一次。
class CategoryTreeStore {
  /// 构造存储；构造时不进行任何 I/O（惰性，同 `DeviceIdProvider` 模式）。
  ///
  /// 参数：[prefs] 测试注入的持久化实例；生产为 null 时首次读写
  ///   自行获取 shared_preferences 单例。
  CategoryTreeStore({SharedPreferences? prefs}) : _prefsOverride = prefs;

  /// 持久化键名（带 `s2s.` 前缀，与 device_id/privacy_consent 键名约定一致）。
  static const String storageKey = 's2s.category.tree';

  /// 测试注入的持久化实例；null 时懒加载真实单例。
  final SharedPreferences? _prefsOverride;

  /// 读缓存的分类树。
  ///
  /// 返回：[CategoryTreeDto?]——无键/空串为 null（首启）；缓存损坏
  ///   删除坏键后返回 null（按无缓存降级，触发全量拉取自愈）。
  /// 副作用：仅缓存损坏时删除一次坏键；正常路径只读不写。
  Future<CategoryTreeDto?> read() async {
    final prefs = _prefsOverride ?? await SharedPreferences.getInstance();
    final raw = prefs.getString(storageKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return CategoryTreeDto.fromJson(jsonDecode(raw));
    } on FormatException {
      // JSON 截断/非法（写盘中断、手改）。
    } on ApiException {
      // 结构违约（版本漂移后旧缓存不满足新解析口径）。
    }
    await prefs.remove(storageKey);
    return null;
  }

  /// 覆盖写入分类树缓存（全量下发后调用）。
  ///
  /// 参数：[tree] 服务端下发的全量分类树 DTO。
  /// 返回：[Future<void>] 落盘完成。
  Future<void> write(CategoryTreeDto tree) async {
    final prefs = _prefsOverride ?? await SharedPreferences.getInstance();
    await prefs.setString(storageKey, jsonEncode(tree.toJson()));
  }
}

/// 分类树存储 Provider（测试经 override 注入 mock prefs 实例）。
final categoryTreeStoreProvider = Provider<CategoryTreeStore>(
  (ref) => CategoryTreeStore(),
);

/// Pin 缓存清理回调登记处（契约 `/categories/tree` description：版本变更
/// 客户端须「清空全部本地 Pin 缓存」）。
///
/// [126] 地图域接 `/map/pins` 缓存时，把「清空全部 Pin 缓存」动作经
/// override 登记进本列表；分类树域只在版本变更时逐一调用，不知道
/// Pin 缓存的存在形式。默认空列表即「当前无 Pin 缓存可清」——
/// 这是 [126] 未开工的预期内状态，不是漏接。
final pinCacheInvalidatorsProvider = Provider<List<void Function()>>(
  (ref) => const [],
);

/// DTO→domain 分类树转换（唯一实现处，编码规范 §1.1）。
///
/// `requiredCert` 契约**不下发**（openapi.yaml `CategoryNode` 无此字段，
/// §4.3 四档是本地渲染细化）：按 [requiredCertForLeaf] 查内置常量树
/// 补充；线上新增叶子在本地常量树补录前查不到 → [RequiredCert.none]，
/// 与 `topCategoryOf` 返回 null 同取向（版本落后是 §16.4 预期内状态，
/// 不报错、不阻断发布，由服务端 precheck 的 40302 兜底拦截）。
/// 非叶子节点的 `requiredCert` 恒 none（domain 注释：仅叶子有意义）。
///
/// 参数：[dtos] 契约节点列表（任一层级，递归转换 children）。
/// 返回：[List<CategoryNode>] domain 树（children 缺失落实为空列表）。
List<CategoryNode> categoryNodesFromDtos(List<CategoryNodeDto> dtos) => [
  for (final dto in dtos)
    CategoryNode(
      id: dto.id,
      name: dto.name,
      requiredCert: (dto.children == null || dto.children!.isEmpty)
          ? requiredCertForLeaf(dto.id)
          : RequiredCert.none,
      children: categoryNodesFromDtos(dto.children ?? const []),
    ),
];

/// 分类树状态（AsyncValue 三态，编码规范 §5.6）。
///
/// `state` 语义：
///   - loading：首启无缓存且协商请求在途；
///   - data：缓存树或线上树（有缓存时刷新在途/失败均保持 data）；
///   - error：仅「首启无缓存 + 请求失败」——error 对象恒为
///     [ApiException]（[asApiException] 归一），页面按 §12.2 行为表渲染。
class CategoryTreeNotifier extends Notifier<AsyncValue<List<CategoryNode>>> {
  @override
  AsyncValue<List<CategoryNode>> build() {
    // build 须同步返回初始态；加载完成后经 state 驱动重建。
    unawaited(_load());
    return const AsyncValue.loading();
  }

  /// 加载主流程：缓存先行 → 版本协商 → 按需替换/清 Pin 缓存。
  ///
  /// X-Interaction-Id 显式不传：这是应用自发的后台协商请求，无用户
  /// 交互起点，由 HeaderInterceptor 缺失时兜底生成（详设 §11.2）。
  Future<void> _load() async {
    final store = ref.read(categoryTreeStoreProvider);
    final cached = await store.read();
    if (cached != null) {
      // 缓存先行：选择器打开不空等网络（详设 §16 缓存口径）。
      state = AsyncValue.data(categoryNodesFromDtos(cached.categories));
    }
    try {
      final result = await ref
          .read(categoryRepositoryProvider)
          .fetchTree(localVersion: cached?.version);
      final full = result.tree;
      if (full == null) return; // unchanged（304 语义）：缓存继续有效
      state = AsyncValue.data(categoryNodesFromDtos(full.categories));
      await store.write(full);
      // 契约硬要求：版本变更清空全部本地 Pin 缓存。空列表=[126] 未开工，
      // 循环零次属预期内；回调自身异常不拦截——Pin 缓存清理失败不应
      // 拖垮分类树主流程（届时地图页按五要素自检重新拉取）。
      for (final invalidate in ref.read(pinCacheInvalidatorsProvider)) {
        invalidate();
      }
    } catch (e) {
      // 有缓存：静默保持（理由见文件头）；无缓存：错误态给重试入口。
      if (cached != null) return;
      state = AsyncValue.error(asApiException(e), StackTrace.current);
    }
  }
}

/// 分类树 Provider（页面经 `ref.watch` 取 AsyncValue 三态渲染）。
final categoryTreeProvider =
    NotifierProvider<CategoryTreeNotifier, AsyncValue<List<CategoryNode>>>(
      CategoryTreeNotifier.new,
    );
