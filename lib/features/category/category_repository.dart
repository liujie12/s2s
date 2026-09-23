/// category 域仓库（[124] 前端段）：分类树版本协商 + 叶子模板拉取。
///
/// 为什么走真网络而不是本地替身（`auth_repository.dart` 的既有模式）：
/// 本域是 [124] 的接线对象——请求经 [dioProvider] 生产同款五拦截器链
/// 发出（mock 期打 MockApiServer 真 HTTP 栈，后端就绪切 baseUrl、
/// 契约示范测试断言一行不改，[123] 已验证该模式）。本层只做
/// 「发请求 + 交 DTO 解析」，信封由 EnvelopeInterceptor 拆、业务错误
/// 以 [ApiException] 抛出，本层不吞不改写（编码规范 §1.2）。
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhaoyazhao/core/network/api_client.dart';

import 'category_dto.dart';

/// 分类树拉取结果（区分契约两种成功语义，调用方必须分开处理）。
///
/// 契约 `/categories/tree` 版本协商（openapi.yaml `/categories/tree`
/// description）：
///   - version 一致 → HTTP 200 + code=0 + **data=null**（304 语义，
///     不是真 304 状态码），客户端沿用本地缓存；
///   - 不一致 → 全量分类树，客户端替换本地数据并**清空全部本地 Pin
///     缓存**（清缓存联动在 B2 Provider 层，本层只忠实报告结果）。
class CategoryTreeResult {
  /// 版本未变（304 语义）：服务端 data=null，本地缓存继续有效。
  const CategoryTreeResult.unchanged() : tree = null;

  /// 全量下发：版本不一致或服务端强制全量。
  const CategoryTreeResult.full(this.tree);

  /// 全量分类树；unchanged 时恒为 null。
  final CategoryTreeDto? tree;

  /// 是否版本未变（304 语义）。
  bool get isUnchanged => tree == null;
}

/// category 域仓库。
///
/// 无实例状态（对比 `AuthRepository` 的计数/锁存），故不需要单实例
/// 纪律；dio 由构造注入，与 [dioProvider] 生产装配同源。
class CategoryRepository {
  /// 构造仓库。
  ///
  /// 参数：[_dio] 生产同款五拦截器链 dio（测试经 NetworkChainHarness
  ///   注入，生产经 [categoryRepositoryProvider] 注入）。
  CategoryRepository(this._dio);

  final Dio _dio;

  /// 拉取分类树（版本协商，`GET /categories/tree`）。
  ///
  /// 参数：
  ///   [localVersion] 本地缓存版本号；null 表示强制全量拉取（契约：
  ///     version 缺省即全量），首启场景用；
  ///   [interactionId] 交互起点生成的 X-Interaction-Id（详设 §11.2
  ///     逐层透传）；null 时由 HeaderInterceptor 兜底生成。
  /// 返回：[CategoryTreeResult]——版本一致为 unchanged，否则携全量 DTO。
  /// 抛出：[ApiException] 信封业务错误/解析失败（拦截器链与 DTO 抛出）。
  Future<CategoryTreeResult> fetchTree({
    String? localVersion,
    String? interactionId,
  }) async {
    final response = await _dio.get<Object?>(
      '/categories/tree',
      queryParameters: <String, String>{'version': ?localVersion},
      options: _interactionOptions(interactionId),
    );
    // EnvelopeInterceptor 已拆信封：成功时 response.data 即信封 data 字段，
    // 版本一致时为 null（304 语义，非错误，详设 §11.3 unwrap 口径）。
    final data = response.data;
    if (data == null) return const CategoryTreeResult.unchanged();
    return CategoryTreeResult.full(CategoryTreeDto.fromJson(data));
  }

  /// 拉取叶子类目发布模板（`GET /templates/{leaf_category_id}`）。
  ///
  /// 参数：
  ///   [leafCategoryId] 叶子类目 ID（契约路径参数；非法/不存在服务端回
  ///     40001，以 [ApiException] 抛出，由调用方按行为表处理——本层不
  ///     做客户端预检，避免与服务端类目表双份真源）；
  ///   [interactionId] 同 [fetchTree]。
  /// 返回：[TemplateDto] 字段模板（`required` 标记兼完整度
  ///   `required_full` 判定依据）。
  /// 抛出：[ApiException] 信封业务错误（含 40001）/解析失败。
  Future<TemplateDto> fetchTemplate(
    int leafCategoryId, {
    String? interactionId,
  }) async {
    final response = await _dio.get<Object?>(
      '/templates/$leafCategoryId',
      options: _interactionOptions(interactionId),
    );
    return TemplateDto.fromJson(response.data);
  }

  /// 组装携带 X-Interaction-Id 的按请求选项。
  ///
  /// 参数：[interactionId] 交互 ID，null 表示无透传值。
  /// 返回：[Options]；null（dio 接受 null options 走 BaseOptions 默认）。
  ///   头注入走「containsKey 才写」纪律：这里显式设了头，
  ///   HeaderInterceptor 不会覆盖；null 时由拦截器兜底生成。
  Options? _interactionOptions(String? interactionId) {
    if (interactionId == null) return null;
    return Options(
      headers: {HeaderInterceptor.interactionIdHeader: interactionId},
    );
  }
}

/// category 仓库 Provider（dio 经 [dioProvider] 注入，与生产装配同源）。
final categoryRepositoryProvider = Provider<CategoryRepository>(
  (ref) => CategoryRepository(ref.watch(dioProvider)),
);
