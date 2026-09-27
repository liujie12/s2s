/// 「我的发布」的 API 状态与状态变更动作常量（客户端唯一落点）。
///
/// **为什么单独成文件**：契约值（`active`/`offline`/`expired`/`archived` 与
/// `offline`/`republish`/`renew`）要在页签映射、卡片操作组、仓库调用、测试四处
/// 出现；任一处写错字面量都只会表现为「筛不出数据」或「动作无效」，编译期无感
/// ——违反常驻红线「不复制字面量」，故收成常量（编码规范 §0.2-①）。
///
/// **本文件只放契约值与判定**；用户可见文案（在架 / 刷新重发…）与配色属设计层，
/// 留在 [MyPublishScreen] 所在文件 —— 文案是「稿↔码对数」探针的判据对象
/// （`prototype-figma/probe-layout-offline.js` 取码侧字面量），放这里会让探针
/// 取不到（它只读页面源文件）。
library;

/// API 状态值（openapi `PostStatusEnum`，库内 `(status, status_reason)` 派生）。
///
/// 派生只在服务端 `PostStatus.toApi` 一处完成（后端详设 §5.3.3），客户端只消费。
class PostApiStatus {
  const PostApiStatus._();

  /// 在架。
  static const String active = 'active';

  /// 已下架（用户主动下架 / 审核下架 / 24h 未实名隐藏）。
  static const String offline = 'offline';

  /// 已过期（到期自动下架）。
  static const String expired = 'expired';

  /// 已归档（成交）。
  static const String archived = 'archived';
}

/// 状态变更动作（openapi `PATCH /posts/{id}/status` 请求体 `action`）。
class PostStatusAction {
  const PostStatusAction._();

  /// 下架（active → archived，`status_reason=0`）。
  static const String offline = 'offline';

  /// 重新上架（→ active，重算 `expire_at`）。
  static const String republish = 'republish';
}

/// 「我的发布」页签（PRD §8.3.1 四个页签：全部 / 在架 / 已下架 / 草稿）。
enum MyPostsTab {
  /// 全部（不筛选）。
  all('全部', null),

  /// 在架。
  active('在架', PostApiStatus.active),

  /// 已下架（**只查 `offline`**：契约 `status` 筛选为单值，`expired`/`archived`
  /// 仅在「全部」页签可见并各标状态 —— 2026-09-27 用户裁定）。
  offline('已下架', PostApiStatus.offline),

  /// 草稿。
  ///
  /// 服务端不存 `draft`（PRD §8.7 草稿为纯客户端概念，Batch1 不变量），故
  /// 无契约筛选值；且本地草稿存储属 Batch2，本页签当前**无数据源**，页面渲染
  /// 降级空态（见说明文档 §2.9）。
  draft('草稿', null);

  const MyPostsTab(this.label, this.apiStatus);

  /// 页签文案（与设计稿 `segTab` 逐字一致）。
  final String label;

  /// 传给 `GET /posts/mine?status=` 的筛选值；null = 不筛选。
  final String? apiStatus;

  /// 当前页签是否具备数据源（草稿页签无）。
  bool get hasDataSource => this != MyPostsTab.draft;
}

/// 卡片动作（客户端动作枚举；与契约 `action` 的对应见 [apiAction]）。
enum MyPostCardAction {
  /// 编辑（依赖 Batch2 的 `PATCH /posts/{id}` 与发布页编辑态，本轮降级）。
  edit(null),

  /// 下架（契约 `offline`）。
  offline(PostStatusAction.offline),

  /// 刷新重发（契约 `republish`：直接重新上架，**不克隆原内容**）。
  ///
  /// PRD §8.4 的「重发」是克隆重发（`POST /posts/{id}/repost`），该端点
  /// openapi 无声明、Batch2 才交付，故本轮语义降级为 `republish`
  /// （2026-09-27 用户裁定；差异登记见说明文档 §2.9）。
  republish(PostStatusAction.republish),

  /// 删除（openapi 无 `DELETE /posts/{post_id}`，本轮降级）。
  remove(null),

  /// 继续编辑（草稿；依赖 Batch2 本地草稿 + 编辑态，本轮无数据源）。
  continueEdit(null);

  const MyPostCardAction(this.apiAction);

  /// 契约 `action` 值；null = 本轮无对应接口（降级项）。
  final String? apiAction;

  /// 是否为已接通真接口的动作（有契约 `action`）。
  bool get isWired => apiAction != null;
}

/// 按 API 状态给出卡片操作组（PRD §8.3.1 / §8.6 状态机 + 设计稿 my-publish）。
///
/// **设计稿冻结的对应关系**（`prototype-figma/code.js` `buildMyPublish`：
/// 在架 → [编辑, 下架]；已下架 → [刷新重发, 删除]；草稿 → [继续编辑, 删除]）。
/// 稿面未单独覆盖的两个契约状态按下表延伸，**不新增稿外按钮**：
///   - `expired`（已过期）→ 同「已下架」（PRD §8.4「过期了能一键重发」）；
///   - `archived`（成交归档）→ 仅 [删除]（成交件不应被重新上架）。
///
/// 参数：[apiStatus] 契约状态值（[PostApiStatus]）。
/// 返回：[List<MyPostCardAction>] 该状态的操作组；契约外取值返回空列表
///   （宁可不给按钮，也不给一个必然失败的动作）。
List<MyPostCardAction> cardActionsFor(String apiStatus) => switch (apiStatus) {
  PostApiStatus.active => const [
    MyPostCardAction.edit,
    MyPostCardAction.offline,
  ],
  PostApiStatus.offline => const [
    MyPostCardAction.republish,
    MyPostCardAction.remove,
  ],
  PostApiStatus.expired => const [
    MyPostCardAction.republish,
    MyPostCardAction.remove,
  ],
  PostApiStatus.archived => const [MyPostCardAction.remove],
  _ => const [],
};
