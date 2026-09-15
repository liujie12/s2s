/// 跨测试文件共享的仓库替身（[124] 前端段 / B4 提取）。
///
/// B3 publish_screen_test 与 B4 publish_precheck_test 两文件共用的 fake
/// 仓库，按反冗余纪律（编码规范 §1.1）上浮为唯一实现处。继承生产类保
/// 单一调用面（签名漂移编译期炸）；fetch 系列全部纯微任务（fake async
/// 下 pumpAndSettle 可推进），不走真 IO。
library;

import 'package:dio/dio.dart';
import 'package:zhaoyazhao/features/category/category_dto.dart';
import 'package:zhaoyazhao/features/category/category_repository.dart';
import 'package:zhaoyazhao/features/post/post_dto.dart';
import 'package:zhaoyazhao/features/post/post_repository.dart';

import 'category_fixtures.dart';

/// 假 category 仓库：fetchTree 恒返线上树；fetchTemplate 按注入态返回。
class FakeCategoryRepository extends CategoryRepository {
  /// 构造。dio 占位（生产同款五拦截器链不会被触发——本替身不发真请求）。
  FakeCategoryRepository() : super(Dio());

  /// fetchTemplate 抛出的异常（模板拉取失败形态）；null 走正常返回。
  Object? templateErrorToThrow;

  /// fetchTemplate 调用次数。
  var templateFetchCount = 0;

  @override
  Future<CategoryTreeResult> fetchTree({
    String? localVersion,
    String? interactionId,
  }) async {
    return CategoryTreeResult.full(
      CategoryTreeDto.fromJson(serverCategoryTreePayload()),
    );
  }

  @override
  Future<TemplateDto> fetchTemplate(
    int leafCategoryId, {
    String? interactionId,
  }) async {
    templateFetchCount++;
    final error = templateErrorToThrow;
    if (error != null) throw error;
    return TemplateDto.fromJson(
      serverTemplatePayload(leafCategoryId: leafCategoryId),
    );
  }
}

/// 假 post 仓库：precheck 按注入态返回（通过/阻断/链路失败三形态）。
class FakePostRepository extends PostRepository {
  /// 构造。dio 占位（同上，不发真请求）。
  FakePostRepository() : super(Dio());

  /// precheck 抛出的异常（链路失败形态）；null 走正常返回。
  Object? errorToThrow;

  /// precheck 返回结果；null 用通过态（passed=true 空 blocks）。
  PrecheckResultDto? resultToReturn;

  /// precheck 收到的载荷（断言表单映射透传）。
  Map<String, Object?>? lastDraft;

  @override
  Future<PrecheckResultDto> precheck(
    Map<String, Object?> draft, {
    String? interactionId,
  }) async {
    lastDraft = draft;
    final error = errorToThrow;
    if (error != null) throw error;
    return resultToReturn ?? PrecheckResultDto(passed: true, blocks: const []);
  }
}
