/// 详情页（PRD §7.4.1 / §7.4.3 需求态差异 / §10.1）。
///
/// **本期不做的两项**（依赖未就位，做了必返工）：
/// ① **详情小地图**：§7.7 要求高德小地图 + Marker，依赖 Key（同地图页现状）；
/// ② **分享**：需 share sheet 插件且要带落地页 URL，而 URL 依赖已备案域名（上架手册 P2）。
///
/// **收藏已实装**（2026-10-27）：外壳（`Scaffold`/`AppBar`）常驻，星标在 `actions`，
/// body 按 loading / error / 41001 / 40301 / data 分流（KTD1）。41001 不再整页替换，
/// 改为同壳降级：联系按钮禁用；星标仅当入口能证明该帖曾存在（来自「我的收藏」）
/// 时才按已收藏态可点，深链 / 未知来源渲染不可点的未知态（KTD4）。
/// 收藏态读写 [favoriteStateProvider]（KTD2），乐观更新 + 失败回滚。
/// **不弹底部浮条**（2026-10-28 用户裁定）：星标由空心变实心（反之亦然）已是
/// 足够的成功反馈，浮条只会压住「联系 TA」；误取消再点一次星标即可复原。
///
/// **[B2-11] 顶部媒体区已由占位转真**：`_MediaPlaceholder`（分类色渐变块）
/// 换成 `MediaCarousel`（消费 `PostDetail.media` 的真图轮播 + 点击全屏查看）。
/// 无图时仍回落为同一分类色占位块，保证下方内容位置不因有无图而位移。
///
/// **「联系 TA」按钮做出来但只做到中转页跳转**：§7.5 用户旅程第 3 步是
/// 「点联系 TA → 弹中转页」，中转页本身是下一个任务。按钮不放会让页面
/// 缺掉最主要的行动点，验收时看不出真实的视觉重量。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_exception.dart';
import '../../core/network/api_error_code.dart';
import '../../design_tokens.dart';
import '../../nfr_constants.dart';
import '../../router/app_router.dart';
import '../../domain/listing_category.dart';
// 色与图标已迁至 style 扩展（详细设计 §10.4.1）：枚举本体须保持纯 Dart，
// 否则聚合模块（features/map/clustering/）无法持有它，就得退回用 int 传分类。
import '../../domain/listing_category_style.dart';
import '../../domain/listing_detail.dart';
import '../auth/auth_repository.dart';
import '../favorite/favorite_state.dart';
import '../post/post_repository.dart';
import 'media_carousel.dart';
import 'post_detail_provider.dart';

/// 详情页入口参数（路由 `extra` 可空，缺失即「深链 / 未知来源」）。
class DetailScreenArgs {
  /// 构造入口参数。
  ///
  /// 参数：[fromFavorites] 是否从「我的收藏」进入；
  ///   [initialFavorited] 列表页已加载的收藏态（仅 [fromFavorites] 时携带）。
  const DetailScreenArgs({this.fromFavorites = false, this.initialFavorited});

  /// 是否从「我的收藏」进入：入口能证明该帖曾存在（KTD4）。
  final bool fromFavorites;

  /// 列表页已加载的收藏态；null = 未知。
  final bool? initialFavorited;
}

class DetailScreen extends ConsumerStatefulWidget {
  const DetailScreen({
    super.key,
    required this.listingId,
    this.args = const DetailScreenArgs(),
  });

  /// 帖子 ID（`int`，契约 `PostIdPath` 为 `int64`，详细设计 §10.4.3）。
  /// 由路由把 URL 字符串解析后传入，非法值传 -1 → 走「信息不存在」。
  final int listingId;

  /// 入口参数（是否来自「我的收藏」等）。
  final DetailScreenArgs args;

  @override
  ConsumerState<DetailScreen> createState() => _DetailScreenState();
}

/// 详情页状态：持浏览上报的一次性标志与收藏动作。
class _DetailScreenState extends ConsumerState<DetailScreen> {
  /// 浏览上报只发一次（R12）：实例级标志，重建 / 翻页都不重复。
  bool _viewReported = false;

  @override
  Widget build(BuildContext context) {
    final detailAsync = ref.watch(postDetailProvider(widget.listingId));
    _reportViewOnce(detailAsync);

    return Scaffold(
      backgroundColor: Color(AppColors.background),
      appBar: AppBar(
        toolbarHeight: 48,
        backgroundColor: Color(AppColors.surface),
        elevation: 0,
        title: Text(
          '详情',
          style: TextStyle(
            fontSize: AppTypeScale.h3.size,
            fontWeight: FontWeight.w600,
            color: Color(AppColors.textPrimary),
          ),
        ),
        // 星标常驻：加载中 / 失败 / 已下架时也保留位置，避免内容跳位（KTD1）。
        actions: [
          _FavoriteAction(
            visual: _favoriteVisual(detailAsync),
            onPressed: _onFavoriteTap,
          ),
        ],
      ),
      body: detailAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _buildErrorBody(error),
        data: _buildDetailBody,
      ),
      bottomNavigationBar: _buildBottomBar(detailAsync),
    );
  }

  /// 详情渲染成功后上报一次浏览（R12）；失败静默，自动重试由全局拦截器负责。
  ///
  /// 参数：[detailAsync] 详情数据三态。
  /// 返回：void。
  void _reportViewOnce(AsyncValue<ListingDetail> detailAsync) {
    if (_viewReported || !detailAsync.hasValue) return;
    _viewReported = true;
    unawaited(
      ref
          .read(postRepositoryProvider)
          .reportView(widget.listingId)
          .catchError((Object _) {}),
    );
  }

  /// 解析星标三态（R2 / KTD4 / KTD9）。
  ///
  /// 优先级：共享收藏态 → 加载中未知 → 错误分流 → 服务端 `favorited` → 游客空心态。
  ///
  /// 参数：[detailAsync] 详情数据三态。
  /// 返回：[_FavoriteVisual]。
  _FavoriteVisual _favoriteVisual(AsyncValue<ListingDetail> detailAsync) {
    final userId =
        ref.watch(authSessionProvider.select((session) => session?.userId));
    if (userId != null) {
      final stored = ref.watch(favoriteStateProvider)[
          FavoriteKey(userId: userId, postId: widget.listingId)];
      if (stored != null) {
        return stored ? _FavoriteVisual.filled : _FavoriteVisual.empty;
      }
    }

    if (detailAsync.isLoading) return _FavoriteVisual.unknown;

    if (detailAsync.hasError) {
      final gone = asApiException(detailAsync.error!).code == ApiErrorCode.postGone;
      // 只有「来自我的收藏」的 41001 能证明该帖曾存在，才允许按已收藏态操作。
      if (gone && widget.args.fromFavorites) {
        final initial = widget.args.initialFavorited;
        if (initial == null) return _FavoriteVisual.unknown;
        return initial ? _FavoriteVisual.filled : _FavoriteVisual.empty;
      }
      return _FavoriteVisual.unknown;
    }

    final favorited = detailAsync.value?.favorited;
    if (favorited != null) {
      return favorited ? _FavoriteVisual.filled : _FavoriteVisual.empty;
    }
    // 游客：未登录不可能是已收藏（KTD9），映射为可收藏的空心态。
    return userId == null ? _FavoriteVisual.empty : _FavoriteVisual.unknown;
  }

  /// 点击星标：未登录先进登录，返回成功后补执行本次收藏（R3 / KTD5）。
  ///
  /// 参数：[visual] 点击时的星标态。
  /// 返回：[Future<void>]。
  Future<void> _onFavoriteTap(_FavoriteVisual visual) async {
    if (visual == _FavoriteVisual.unknown) return;

    if (!ref.read(isLoggedInProvider)) {
      final ok = await GoRouter.of(context).push<bool>(AppRoutes.login);
      // 用户放弃登录（返回非 true）时状态不变：他刚刚放弃了这个动作。
      if (!mounted || ok != true) return;
    }

    await _commit(visual != _FavoriteVisual.filled);
  }

  /// 提交收藏 / 取消收藏；失败时容器已回滚，这里只提示错误（R4）。
  ///
  /// **成功不弹底部浮条**（2026-10-28 用户裁定）：星标由空心变实心（反之亦然）
  /// 已是足够的成功反馈，浮条会压住「联系 TA」；误取消只需再点一次星标即可
  /// 复原，不需要额外的「撤销」按钮。
  ///
  /// 参数：[favorited] 目标状态。
  /// 返回：[Future<void>]。
  Future<void> _commit(bool favorited) async {
    try {
      await ref.read(favoriteStateProvider.notifier).set(widget.listingId, favorited);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(asApiException(e).uiMessage)),
      );
    }
  }

  /// 组装详情正文（三态中的 data 态）。
  ///
  /// 参数：[detail] 详情域模型。
  /// 返回：Widget。
  Widget _buildDetailBody(ListingDetail detail) {
    return ListView(
      // 底部留出主按钮高度 + 安全区，否则最后一段内容会被按钮永久遮住，
      // 且用户无法察觉下面还有东西。
      padding: const EdgeInsets.only(bottom: 96),
      children: [
        MediaCarousel(
          mediaUrls: detail.mediaUrls,
          category: detail.listing.category,
        ),
        _InfoSection(detail: detail),
        if (detail.templateFields.isNotEmpty)
          _TemplateSection(fields: detail.templateFields),
        _DescriptionSection(text: detail.description),
        // B2-4 内容标识落点二：AI 辅助生成的帖子显式标注（PRD §5.9 合规裁定）。
        if (detail.aiAssisted) const _AiAssistBadge(),
        _PublisherCard(
          publisher: detail.publisher,
          completeness: detail.completeness,
          credentials: detail.credentials,
        ),
        if (detail.listing.supplyDemand == SupplyDemand.demand)
          const _DemandHelpEntry(),
      ],
    );
  }

  /// 错误态分流（body 内，外壳常驻）。
  ///
  /// 必须先经 [asApiException] 归一：信封业务错误在链上以
  /// `DioException(error: ApiException)` 形态到达（EnvelopeInterceptor 的
  /// reject 载体），直接判 `error is ApiException` 恒为 false，41001 会落到
  /// 通用错误屏。既有范式见 category_selector_screen.dart / category_tree_provider.dart。
  ///
  /// 参数：[error] 详情请求异常。
  /// 返回：Widget。
  Widget _buildErrorBody(Object error) {
    final apiError = asApiException(error);
    // 41001 是「这条信息已下架/不存在」——用户的预期结果，非故障。
    if (apiError.code == ApiErrorCode.postGone) {
      return const _NotFoundBody();
    }
    // 40301 未实名详情额度耗尽：弹引导实名（PRD §3.7），非普通错误态。
    if (apiError.code == ApiErrorCode.detailQuotaUsed) {
      return const _QuotaExhaustedBody();
    }
    return const _ErrorBody();
  }

  /// 底部联系栏：data 态给真按钮；41001 保留但禁用（R5）；其余不显示。
  ///
  /// 参数：[detailAsync] 详情数据三态。
  /// 返回：`Widget?`。
  Widget? _buildBottomBar(AsyncValue<ListingDetail> detailAsync) {
    final detail = detailAsync.value;
    if (detail != null) return _ContactBar(detail: detail);
    final error = detailAsync.error;
    if (error != null && asApiException(error).code == ApiErrorCode.postGone) {
      return const _ContactBar.disabled();
    }
    return null;
  }
}

/// 星标三态（R2）。
enum _FavoriteVisual {
  /// 已收藏（实心星）。
  filled,

  /// 未收藏（空心星，可点）。
  empty,

  /// 未知（置灰不可点，不渲染成确定的空心态）。
  unknown,
}

/// 导航栏收藏动作：星标 + 「收藏/已收藏」，点击区不小于 44×44（R1）。
class _FavoriteAction extends StatelessWidget {
  /// 构造收藏动作。
  ///
  /// 参数：[visual] 星标三态；[onPressed] 点击回调（未知态不触发）。
  const _FavoriteAction({required this.visual, required this.onPressed});

  /// 星标三态。
  final _FavoriteVisual visual;

  /// 点击回调（携带点击时的星标态，供页面决定目标状态）。
  final ValueChanged<_FavoriteVisual> onPressed;

  @override
  Widget build(BuildContext context) {
    final filled = visual == _FavoriteVisual.filled;
    final enabled = visual != _FavoriteVisual.unknown;
    // 未知态用占位色置灰：既保留位置，又不冒充「确定未收藏」。
    final color = !enabled
        ? Color(AppColors.textPlaceholder)
        : filled
            ? Color(AppColors.accent)
            : Color(AppColors.textPrimary);

    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.sm),
      child: TextButton.icon(
        onPressed: enabled ? () => onPressed(visual) : null,
        icon: Icon(filled ? Icons.star : Icons.star_border, size: 20),
        label: Text(
          filled ? '已收藏' : '收藏',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        style: TextButton.styleFrom(
          foregroundColor: color,
          disabledForegroundColor: Color(AppColors.textPlaceholder),
          minimumSize: const Size(84, 44),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        ),
      ),
    );
  }
}

/// 「AI 辅助生成」内容标识（B2-4；PRD §5.9 合规裁定：确认页 + 详情页两处都做）。
///
/// 仅当帖子 `ai_assisted=true` 时展示。样式克制：一行小字 + 图标，不与正文争视觉。
class _AiAssistBadge extends StatelessWidget {
  const _AiAssistBadge();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        0,
      ),
      child: Row(
        children: [
          Icon(
            Icons.auto_awesome_outlined,
            size: 14,
            color: Color(AppColors.textPlaceholder),
          ),
          const SizedBox(width: AppSpacing.xs),
          Text(
            'AI 辅助生成',
            style: TextStyle(
              fontSize: AppTypeScale.caption.size,
              color: Color(AppColors.textPlaceholder),
            ),
          ),
        ],
      ),
    );
  }
}

/// 信息区：标签 + 面包屑 + 标题 + 价格 + 位置与有效期（PRD §7.4.1）。
class _InfoSection extends StatelessWidget {
  const _InfoSection({required this.detail});

  final ListingDetail detail;

  @override
  Widget build(BuildContext context) {
    final listing = detail.listing;
    final days = detail.daysUntilExpire(DateTime.now());

    return _Section(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _SupplyDemandTag(
                supplyDemand: listing.supplyDemand,
                category: listing.category,
              ),
              if (detail.publisher.realNameVerified) ...[
                const SizedBox(width: AppSpacing.sm),
                const _VerifiedTag(),
              ],
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  detail.categoryPath.join(' > '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppTypeScale.caption.size,
                    color: Color(AppColors.textSecondary),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            // 需求态自动加前缀（§7.4.3），前缀由分类推导，不需要发布者手填。
            detail.displayTitle,
            style: TextStyle(
              fontSize: AppTypeScale.h2.size,
              fontWeight: FontWeight.w700,
              color: Color(AppColors.textPrimary),
              height: 1.35,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                // 无价格显示「面议」而非留空（§5.8 允许价格为空）：
                // 空白会让用户以为页面没加载完，而「面议」是明确的信息。
                listing.priceLabel ?? '面议',
                style: TextStyle(
                  fontSize: AppTypeScale.h2.size,
                  fontWeight: FontWeight.w700,
                  color: Color(AppColors.accent),
                ),
              ),
              if (detail.negotiable) ...[
                const SizedBox(width: AppSpacing.sm),
                Text(
                  '可议价',
                  style: TextStyle(
                    fontSize: AppTypeScale.small.size,
                    color: Color(AppColors.textSecondary),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          _MetaRow(icon: Icons.place_outlined, text: detail.address ?? '位置未填写'),
          const SizedBox(height: AppSpacing.xs),
          _MetaRow(
            icon: Icons.schedule_outlined,
            // 到期与临期用不同措辞：「1 天后下架」带紧迫感，
            // 而已过期的信息本不该出现在列表里，出现即为数据问题，明确说出来。
            text: days == 0 ? '已过期' : '$days 天后下架',
            // 3 天内标警示色：这是用户决定「要不要现在就联系」的关键信息。
            highlight: days > 0 && days <= 3,
          ),
        ],
      ),
    );
  }
}

/// 模板字段区（PRD §7.4.1 / §7.7 按序显示 key/value）。
class _TemplateSection extends StatelessWidget {
  const _TemplateSection({required this.fields});

  final List<TemplateField> fields;

  @override
  Widget build(BuildContext context) {
    return _Section(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionTitle('详细信息'),
          const SizedBox(height: AppSpacing.sm),
          ...fields.map(
            (f) => Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 固定标签宽度让所有 value 左对齐成一列。不固定的话，
                  // 「工具」与「可服务面积」会让 value 参差不齐，扫读成本明显上升。
                  SizedBox(
                    width: 84,
                    child: Text(
                      f.label,
                      style: TextStyle(
                        fontSize: AppTypeScale.small.size,
                        color: Color(AppColors.textSecondary),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      f.value,
                      style: TextStyle(
                        fontSize: AppTypeScale.small.size,
                        color: Color(AppColors.textPrimary),
                        height: 1.45,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 描述区（PRD §7.4.1）。
class _DescriptionSection extends StatelessWidget {
  const _DescriptionSection({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return _Section(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionTitle('描述'),
          const SizedBox(height: AppSpacing.sm),
          Text(
            text,
            style: TextStyle(
              fontSize: AppTypeScale.body.size,
              color: Color(AppColors.textPrimary),
              // 正文行高比标题松：详情描述是需要连续阅读的段落，
              // 1.35 的行高在多行段落下会显得挤。
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}

/// 发布者信任卡（PRD §7.4.1；本轮加入帖级资质行）。
class _PublisherCard extends StatelessWidget {
  const _PublisherCard({
    required this.publisher,
    required this.completeness,
    this.credentials = const [],
  });

  final Publisher publisher;
  final CompletenessLevel completeness;

  /// 帖级凭证列表（一帖多证；空列表 = 整栏不渲染）。
  final List<PostCredential> credentials;

  @override
  Widget build(BuildContext context) {
    return _Section(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: Color(AppColors.primaryLight),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.person,
              size: 26,
              color: Color(AppColors.primary),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  publisher.nickname,
                  style: TextStyle(
                    fontSize: AppTypeScale.body.size,
                    fontWeight: FontWeight.w600,
                    color: Color(AppColors.textPrimary),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                // 未实名不显示灰色的「未实名」标 —— 那是在替发布者做负面背书。
                // PRD §9.8 的设计是「有认证才展示」，无认证靠完整度档位说话。
                if (publisher.realNameVerified)
                  const _TrustLine(icon: Icons.verified_user, text: '个人实名'),
                // 说明（原型说明 §4）：原通用「资质认证」标签由帖级资质行取代，
                // 不再展示 `publisher.qualificationLabel`，避免同一语义两处重复。
                const SizedBox(height: AppSpacing.xs),
                _CompletenessLine(level: completeness),
                if (credentials.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Divider(height: 1, color: Color(AppColors.border)),
                  const SizedBox(height: AppSpacing.sm),
                  _CredentialBlock(credentials: credentials),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 帖级资质块：只显示证书名（2026-10-28 起没有有效期与归属说明行）。
class _CredentialBlock extends StatelessWidget {
  /// 构造资质块。
  ///
  /// 参数：[credentials] 凭证列表（按挂载顺序，一帖多证）。
  const _CredentialBlock({required this.credentials});

  /// 凭证列表。
  final List<PostCredential> credentials;

  /// 大图最大放大倍数（只读证照，给足看清细节的空间）。
  static const double _maxImageScale = 4;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final credential in credentials)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: InkWell(
              onTap: credential.imageUrl == null
                  ? null
                  : () => _openImage(context, credential),
              child: Row(
                children: [
                  _thumb(credential),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      _mainLineOf(credential),
                      style: TextStyle(
                        fontSize: AppTypeScale.body.size,
                        color: Color(AppColors.textPrimary),
                      ),
                    ),
                  ),
                  if (credential.imageUrl != null)
                    Icon(
                      Icons.zoom_in,
                      size: 16,
                      color: Color(AppColors.textSecondary),
                    ),
                ],
              ),
            ),
          ),
        Text(
          '资质由发布者提供，平台未核验；点击可查看证照图',
          style: TextStyle(
            fontSize: AppTypeScale.caption.size,
            color: Color(AppColors.textSecondary),
          ),
        ),
      ],
    );
  }

  /// 证照图缩略图（无图时退化为图标，保持行高一致）。
  ///
  /// 参数：[credential] 凭证块。
  /// 返回：左侧缩略图或图标。
  static Widget _thumb(PostCredential credential) {
    final url = credential.imageUrl;
    if (url == null) {
      return Icon(
        Icons.workspace_premium_outlined,
        size: 16,
        color: Color(AppColors.textSecondary),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Image.network(
        url,
        width: 56,
        height: 56,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Container(
          width: 56,
          height: 56,
          color: Color(AppColors.primaryLight),
          child: Icon(
            Icons.image_not_supported_outlined,
            size: 18,
            color: Color(AppColors.textSecondary),
          ),
        ),
      ),
    );
  }

  /// 打开证照大图（可双指缩放，点任意处关闭）。
  ///
  /// 参数：[context] 构建上下文；[credential] 凭证块（须有 imageUrl）。
  /// 返回：[Future<void>]。
  static Future<void> _openImage(
    BuildContext context,
    PostCredential credential,
  ) async {
    final url = credential.imageUrl;
    if (url == null) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(AppSpacing.lg),
        child: GestureDetector(
          onTap: () => Navigator.of(dialogContext).pop(),
          child: InteractiveViewer(
            maxScale: _maxImageScale,
            child: Image.network(
              url,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
  }

  /// 主行：只显示证名；空快照回落「资质认证」。
  ///
  /// 参数：[credential] 凭证块。
  /// 返回：[String]。
  static String _mainLineOf(PostCredential credential) {
    final name = credential.certName.trim();
    return name.isEmpty ? '资质认证' : name;
  }
}

/// 需求态专属入口（PRD §7.4.3 末条：「我有资源/能帮忙 · 一键发布对应资源」）。
class _DemandHelpEntry extends StatelessWidget {
  const _DemandHelpEntry();

  @override
  Widget build(BuildContext context) {
    return _Section(
      child: Row(
        children: [
          Icon(
            Icons.lightbulb_outline,
            size: 20,
            color: Color(AppColors.primary),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              '你有对应的资源？',
              style: TextStyle(
                fontSize: AppTypeScale.small.size,
                color: Color(AppColors.textPrimary),
              ),
            ),
          ),
          TextButton(
            // 发布页尚未实现，跳过去是占位屏。仍保留入口：这是 §7.4.3 定义的
            // 需求态与资源态的核心差异，去掉会让两态看起来没区别。
            onPressed: () => context.push('/publish'),
            child: const Text('我能帮忙'),
          ),
        ],
      ),
    );
  }
}

/// 底部固定联系栏（PRD §7.4.1 底部固定主按钮胶囊）。
///
/// 41001 时走 [ _ContactBar.disabled ]：外壳与占位保留，但按钮禁用——
/// 「已下架仍可收藏」需要这条提示仍在，而联系入口已无意义（R5）。
class _ContactBar extends StatelessWidget {
  const _ContactBar({required ListingDetail this.detail}) : enabled = true;

  /// 已下架（41001）降级态：无详情数据，按钮禁用。
  const _ContactBar.disabled()
      : detail = null,
        enabled = false;

  /// 详情域模型；禁用态为 null。
  final ListingDetail? detail;

  /// 联系入口是否可点（41001 时为 false）。
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    // 需求态按钮文案改为「响应需求」（§7.4.3）：对需求发布者说「联系 TA」
    // 语义是反的 —— 点击者是来提供资源的，不是来求助的。
    final isDemand = detail?.listing.supplyDemand == SupplyDemand.demand;
    final label = isDemand ? '响应需求' : '联系 TA';
    final icon = detail?.contactChannel == ContactChannel.wechat
        ? Icons.chat_bubble_outline
        : Icons.phone;

    return SafeArea(
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        decoration: BoxDecoration(
          color: Color(AppColors.surface),
          boxShadow: const [
            BoxShadow(
              color: Color(0x14000000),
              blurRadius: 12,
              offset: Offset(0, -2),
            ),
          ],
        ),
        child: SizedBox(
          height: 48,
          child: FilledButton.icon(
            onPressed: enabled
                ? () => context.push('/contact/${detail!.listing.id}')
                : null,
            icon: Icon(icon, size: 20),
            label: Text(
              label,
              style: TextStyle(
                fontSize: AppTypeScale.body.size,
                fontWeight: FontWeight.w600,
              ),
            ),
            style: FilledButton.styleFrom(
              backgroundColor: Color(AppColors.primary),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.full),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 通用错误态（网络失败 / 游客限频 42907 / 服务端错误等，非 41001）。
///
/// 不展示具体错误码：详情页失败对用户而言都是「暂时看不到这条信息」，
/// 具体原因（限频 vs 网络）在 §12.2 行为表的 UI 层再细分——本页只兜住
/// 「非 41001 的失败」这一档，避免把错误码细节泄给页面。
/// 外壳（`Scaffold`/`AppBar`）由详情页常驻，这里只给 body（KTD1）。
class _ErrorBody extends StatelessWidget {
  const _ErrorBody();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.cloud_off_outlined,
            size: 48,
            color: Color(AppColors.textPlaceholder),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            '加载失败，请稍后重试',
            style: TextStyle(
              fontSize: AppTypeScale.body.size,
              color: Color(AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// 未实名详情额度耗尽（40301）：引导实名（PRD §3.7「今天的 N 条看完了」）。
///
/// 与 [_ErrorBody] 分开：额度耗尽不是故障，而是「完成实名即可解锁」的
/// 引导态，须给「去实名」入口（跳 trust 实名表单页），不是重试。
class _QuotaExhaustedBody extends StatelessWidget {
  const _QuotaExhaustedBody();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.verified_user_outlined,
            size: 48,
            color: Color(AppColors.textPlaceholder),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            '今天的 ${NfrCert.detailQuotaLimitPerDay} 条看完了',
            style: TextStyle(
              fontSize: AppTypeScale.body.size,
              color: Color(AppColors.textPrimary),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '完成实名后可无限查看',
            style: TextStyle(
              fontSize: AppTypeScale.small.size,
              color: Color(AppColors.textSecondary),
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          ElevatedButton(
            onPressed: () => context.push(AppRoutes.trust),
            style: ElevatedButton.styleFrom(
              backgroundColor: Color(AppColors.primary),
              foregroundColor: Colors.white,
              elevation: 0,
              shape: StadiumBorder(),
            ),
            child: const Text('去实名（约 30 秒）'),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextButton(
            onPressed: () => context.pop(),
            child: Text(
              '明天再来',
              style: TextStyle(color: Color(AppColors.textSecondary)),
            ),
          ),
        ],
      ),
    );
  }
}

/// 信息不存在（已下架 / id 非法）。
///
/// 与旧版「整页替换」的差异（KTD1 / R5）：不再自建 `Scaffold`，外壳、
/// 星标与底部禁用联系栏由详情页提供 —— 从「我的收藏」进来的已下架帖
/// 仍能取消收藏。
class _NotFoundBody extends StatelessWidget {
  const _NotFoundBody();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.inventory_2_outlined,
            size: 48,
            color: Color(AppColors.textPlaceholder),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            // 说明原因而非只说「不存在」：信息过期下架是本产品的常态
            // （§5.11 默认 7 天），用户需要知道这不是 App 出错。
            '这条信息已下架或不存在',
            style: TextStyle(
              fontSize: AppTypeScale.body.size,
              color: Color(AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

// ── 通用小部件 ──────────────────────────────────────────────

/// 白底分段容器。详情页由多个内容块纵向堆叠，块间用背景色缝隙分隔。
class _Section extends StatelessWidget {
  const _Section({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.lg),
      color: Color(AppColors.surface),
      child: child,
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: AppTypeScale.body.size,
        fontWeight: FontWeight.w600,
        color: Color(AppColors.textPrimary),
      ),
    );
  }
}

/// 资源 / 需求标签（PRD §6.4.2 配色规则，与地图 Marker、列表色块一致）。
class _SupplyDemandTag extends StatelessWidget {
  const _SupplyDemandTag({required this.supplyDemand, required this.category});

  final SupplyDemand supplyDemand;
  final ListingCategory category;

  @override
  Widget build(BuildContext context) {
    final isSupply = supplyDemand == SupplyDemand.supply;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        // 承载白字必须用 deepColor：分类原色配白字全部不过 WCAG AA
        // （design_tokens.dart:74 已实测）。
        color: isSupply ? category.deepColor : Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: isSupply ? null : Border.all(color: category.deepColor),
      ),
      child: Text(
        supplyDemand.label,
        style: TextStyle(
          fontSize: AppTypeScale.caption.size,
          fontWeight: FontWeight.w600,
          color: isSupply ? Colors.white : category.deepColor,
        ),
      ),
    );
  }
}

class _VerifiedTag extends StatelessWidget {
  const _VerifiedTag();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: Color(AppColors.primaryLight),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Text(
        '已认证',
        style: TextStyle(
          fontSize: AppTypeScale.caption.size,
          fontWeight: FontWeight.w600,
          color: Color(AppColors.primaryDark),
        ),
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({
    required this.icon,
    required this.text,
    this.highlight = false,
  });

  final IconData icon;
  final String text;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    // 用 warningText 而非 warning：后者是图形色，承载文字对比度不足
    // （design_tokens.dart 已为此专门备了 *-text 三色）。
    final color = highlight
        ? Color(AppColors.warningText)
        : Color(AppColors.textSecondary);
    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: AppSpacing.xs),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: AppTypeScale.small.size, color: color),
          ),
        ),
      ],
    );
  }
}

class _TrustLine extends StatelessWidget {
  const _TrustLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: Color(AppColors.successText)),
        const SizedBox(width: AppSpacing.xs),
        Text(
          text,
          style: TextStyle(
            fontSize: AppTypeScale.small.size,
            color: Color(AppColors.textPrimary),
          ),
        ),
      ],
    );
  }
}

/// 完整度档位行（PRD §9.8 三档视觉标记）。
class _CompletenessLine extends StatelessWidget {
  const _CompletenessLine({required this.level});

  final CompletenessLevel level;

  @override
  Widget build(BuildContext context) {
    final (int dot, int text) = switch (level) {
      CompletenessLevel.green => (AppColors.success, AppColors.successText),
      CompletenessLevel.yellow => (AppColors.warning, AppColors.warningText),
      CompletenessLevel.red => (AppColors.error, AppColors.errorText),
    };
    return Row(
      children: [
        // 圆点用图形色、文字用 *-text 深色变体：同一语义两种用途，
        // 混用会让文字在浅背景上达不到 4.5:1。
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: Color(dot), shape: BoxShape.circle),
        ),
        const SizedBox(width: AppSpacing.sm),
        Text(
          '信息完整度：${level.label}',
          style: TextStyle(
            fontSize: AppTypeScale.small.size,
            color: Color(text),
          ),
        ),
      ],
    );
  }
}
