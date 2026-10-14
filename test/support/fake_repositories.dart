/// 跨测试文件共享的仓库替身（[124] 前端段 / B4 提取）。
///
/// B3 publish_screen_test 与 B4 publish_precheck_test 两文件共用的 fake
/// 仓库，按反冗余纪律（编码规范 §1.1）上浮为唯一实现处。继承生产类保
/// 单一调用面（签名漂移编译期炸）；fetch 系列全部纯微任务（fake async
/// 下 pumpAndSettle 可推进），不走真 IO。
library;

import 'package:dio/dio.dart';
import 'package:zhaoyazhao/features/ai/ai_dto.dart';
import 'package:zhaoyazhao/features/ai/ai_repository.dart';
import 'package:zhaoyazhao/features/category/category_dto.dart';
import 'package:zhaoyazhao/features/category/category_repository.dart';
import 'package:zhaoyazhao/features/post/post_dto.dart';
import 'package:zhaoyazhao/features/post/post_repository.dart';
import 'package:zhaoyazhao/nfr_constants.dart';

import 'category_fixtures.dart';
import 'post_fixtures.dart';

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

  /// createPost 抛出的异常（POST 失败形态）；null 走正常返回。
  Object? createErrorToThrow;

  /// createPost 收到的载荷。
  Map<String, Object?>? lastCreateDraft;

  /// createPost 调用次数（成功链路断言 precheck→POST 两跳都发生）。
  var createCount = 0;

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

  @override
  Future<PostCreatedDto> createPost(
    Map<String, Object?> draft, {
    String? interactionId,
  }) async {
    createCount++;
    lastCreateDraft = draft;
    final error = createErrorToThrow;
    if (error != null) throw error;
    return PostCreatedDto.fromJson(postCreatedPayload());
  }

  /// fetchMine 返回的列表页；null 用 `myPostsPayload` 构造的默认两形态数据。
  MyPostsPageDto? mineToReturn;

  /// fetchMine 抛出的异常（列表加载失败形态）；null 走正常返回。
  Object? mineErrorToThrow;

  /// fetchMine 收到的筛选值（断言页签 → 契约单值映射透传）。
  String? lastMineStatus;

  /// fetchMine 收到的页码（断言分页：首屏 1、触底 2）。
  int? lastMinePage;

  /// fetchMine 调用次数（断言切页签/状态变更后确实重拉）。
  var mineFetchCount = 0;

  /// changeStatus 抛出的异常（乐观锁冲突 40903 形态）；null 走正常返回。
  Object? changeStatusErrorToThrow;

  /// changeStatus 收到的帖子 ID。
  int? lastChangePostId;

  /// changeStatus 收到的动作（断言卡片动作 → 契约 action 映射）。
  String? lastChangeAction;

  /// changeStatus 收到的乐观锁版本号（断言来自列表项而非本地推算）。
  int? lastChangeVersion;

  @override
  Future<MyPostsPageDto> fetchMine({
    int page = 1,
    int pageSize = NfrApi.pageSizeDefault,
    String? status,
    String? interactionId,
  }) async {
    mineFetchCount++;
    lastMinePage = page;
    lastMineStatus = status;
    final error = mineErrorToThrow;
    if (error != null) throw error;
    final payload = mineToReturn;
    return payload ?? MyPostsPageDto.fromJson(myPostsPayload());
  }

  @override
  Future<PostStatusResultDto> changeStatus(
    int postId, {
    required String action,
    required int version,
    String? interactionId,
  }) async {
    lastChangePostId = postId;
    lastChangeAction = action;
    lastChangeVersion = version;
    final error = changeStatusErrorToThrow;
    if (error != null) throw error;
    return PostStatusResultDto.fromJson(postStatusResultPayload());
  }

  // ---------------------------------------------------------------------
  // [B2-8] 编辑 / 克隆重发 / 详情（编辑态预填用）
  // ---------------------------------------------------------------------

  /// fetchDetail 抛出的异常；null 走正常返回。
  Object? detailErrorToThrow;

  /// fetchDetail 收到的帖子 ID（断言「编辑」先取详情再进编辑态）。
  int? lastDetailPostId;

  /// updatePost 抛出的异常；null 走正常返回。
  Object? updateErrorToThrow;

  /// updatePost 收到的帖子 ID。
  int? lastUpdatePostId;

  /// updatePost 收到的载荷（断言编辑态提交走 PATCH 且带 `version`）。
  Map<String, Object?>? lastUpdateDraft;

  /// repost 抛出的异常；null 走正常返回。
  Object? repostErrorToThrow;

  /// repost 返回的草稿；null 用 [repostDraftPayload] 默认桩。
  RepostDraftDto? repostToReturn;

  /// repost 收到的帖子 ID（断言「刷新重发」打的是 repost 而非 PATCH status）。
  int? lastRepostPostId;

  @override
  Future<PostDetailDto> fetchDetail(int postId, {String? interactionId}) async {
    lastDetailPostId = postId;
    final error = detailErrorToThrow;
    if (error != null) throw error;
    return PostDetailDto.fromJson(postDetailPayload());
  }

  @override
  Future<PostCreatedDto> updatePost(
    int postId,
    Map<String, Object?> draft, {
    String? interactionId,
  }) async {
    lastUpdatePostId = postId;
    lastUpdateDraft = draft;
    final error = updateErrorToThrow;
    if (error != null) throw error;
    return PostCreatedDto.fromJson(postCreatedPayload());
  }

  @override
  Future<RepostDraftDto> repost(int postId, {String? interactionId}) async {
    lastRepostPostId = postId;
    final error = repostErrorToThrow;
    if (error != null) throw error;
    return repostToReturn ?? RepostDraftDto.fromJson(repostDraftPayload());
  }
}

/// 假 ai 仓库：`parse`/`fetchQuota` 全纯微任务（fake async 下 pumpAndSettle 可推进）。
///
/// 继承生产类保单一调用面（签名漂移编译期炸）；绝不出网。
class FakeAiRepository extends AiRepository {
  /// 构造。dio 占位（本替身不发真请求）。
  FakeAiRepository() : super(Dio());

  /// `parse` 返回的结果；null 走「空猜测」默认（未选分类、无文本的服务端形态）。
  AiParseResultDto? resultToReturn;

  /// `parse`/`fetchQuota` 抛出的异常（模拟 42901/50301/传输错误）；null 走正常返回。
  Object? errorToThrow;

  /// `fetchQuota` 返回的配额；null 走未实名保守档上限。
  AiQuotaDto? quotaToReturn;

  /// `parse` 调用次数（断言「进页面即解析」）。
  var parseCount = 0;

  /// 最后一次 `parse` 入参（断言请求组装正确）。
  AiParseRequestDto? lastRequest;

  @override
  Future<AiParseResultDto> parse(
    AiParseRequestDto req, {
    String? interactionId,
  }) async {
    parseCount++;
    lastRequest = req;
    final error = errorToThrow;
    if (error != null) throw error;
    return resultToReturn ?? _emptyResult();
  }

  @override
  Future<AiQuotaDto> fetchQuota({
    int? completenessLevel,
    int? leafCategoryId,
    String? interactionId,
  }) async {
    final error = errorToThrow;
    if (error != null) throw error;
    return quotaToReturn ??
        AiQuotaDto(
          used: 0,
          limit: NfrAi.quotaUnverifiedOrRed,
          resetAt: DateTime(2026, 1, 1),
        );
  }

  /// 空猜测结果（未选分类、无文本时的服务端返回形态）。
  ///
  /// 返回：[AiParseResultDto] 分类/标题/价格三项皆未猜出。
  static AiParseResultDto _emptyResult() => const AiParseResultDto(
        guess: AiGuessDto(),
        scopeVerified: <String, String>{},
        unresolvedFields: <String>['title', 'price'],
      );
}
