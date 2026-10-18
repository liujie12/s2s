/// 发布页入参（PRD §5.4.1 / §8.4 编辑态）。
///
/// **为什么单列一个入参对象而不是给 [PublishScreen] 加多个可选参数**：
/// 发布页本轮要承载三种进入态 —— 新建（空白表单）/ 重发（服务端克隆草稿
/// 预填）/ 编辑（既有帖预填 + 乐观锁版本）。三者都以「一份初始表单」为
/// 起点，区别只在于「是否编辑既有帖」及「编辑时的乐观锁版本」；把三者
/// 收进一个对象，路由侧只需透传一个 `extra`，也让「编辑态」的判据
/// （[editPostId] 非空）只有一个来源，不会在页面内多处各自判断。
///
/// 与页面的解耦：本文件只依赖 [PublishFormState]，不引 go_router / Flutter，
/// 便于路由与页面共用而不成环。
library;

import 'publish_form_state.dart';

/// 发布页入参。
class PublishScreenArgs {
  /// 构造发布页入参。
  ///
  /// 参数：
  ///   [initialForm] 初始表单快照（新建为默认空表单；重发/编辑为预填表单）；
  ///   [initialMedia] 既有媒体（编辑态带 URL 回显；重发态 URL 为空串）；
  ///   [editPostId] 非空 = 编辑既有帖（提交走 `PATCH /posts/{id}`）；
  ///     null = 新建/重发（提交走 `POST /posts`）；
  ///   [editVersion] 编辑时的乐观锁版本号（取自 `GET /posts/mine` 的列表项）。
  const PublishScreenArgs({
    this.initialForm = const PublishFormState(),
    this.initialMedia = const <({String mediaId, String url})>[],
    this.editPostId,
    this.editVersion,
  });

  /// 初始表单快照。
  final PublishFormState initialForm;

  /// 既有媒体（编辑态回显；重发态无 URL 时 url 传空串）。
  ///
  /// 与 [PublishFormState.mediaIds] 的区别：后者只承载可提交的 ID，媒体段还需要
  /// URL 才能画出缩略图。两者在编辑态由同一份 `GET /posts/{id}` 详情派生。
  final List<({String mediaId, String url})> initialMedia;

  /// 编辑目标帖子 ID；null 表示新建/重发。
  final int? editPostId;

  /// 编辑时的乐观锁版本号（仅 [editPostId] 非空时有意义）。
  final int? editVersion;
}
