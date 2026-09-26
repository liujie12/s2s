/// 详情页（PRD §7.4.1 / §7.4.3 需求态差异 / §10.1）。
///
/// **本期不做的四项**（依赖未就位，做了必返工）：
/// ① **媒体轮播**：§13.2 `post_media` 表未建模，且图片需 CDN 与上传链路，
///    先用分类色渐变占位块占住版面，让下方内容的位置不会因日后加图而整体位移；
/// ② **详情小地图**：§7.7 要求高德小地图 + Marker，依赖 Key（同地图页现状）；
/// ③ **收藏 / 分享**：收藏依赖账号（§13.2 `favorite` 表以 user_id 为键），
///    分享需 share sheet 插件且要带落地页 URL，而 URL 依赖已备案域名（上架手册 P2）；
/// ④ **举报入口**：属联系中转页（§7.4.2 底部），不在详情页。
///
/// **「联系 TA」按钮做出来但只做到中转页跳转**：§7.5 用户旅程第 3 步是
/// 「点联系 TA → 弹中转页」，中转页本身是下一个任务。按钮不放会让页面
/// 缺掉最主要的行动点，验收时看不出真实的视觉重量。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_exception.dart';
import '../../core/network/api_error_code.dart';
import '../../design_tokens.dart';
import '../../domain/listing_category.dart';
// 色与图标已迁至 style 扩展（详细设计 §10.4.1）：枚举本体须保持纯 Dart，
// 否则聚合模块（features/map/clustering/）无法持有它，就得退回用 int 传分类。
import '../../domain/listing_category_style.dart';
import '../../domain/listing_detail.dart';
import 'post_detail_provider.dart';

class DetailScreen extends ConsumerWidget {
  const DetailScreen({super.key, required this.listingId});

  /// 帖子 ID（`int`，契约 `PostIdPath` 为 `int64`，详细设计 §10.4.3）。
  /// 由路由把 URL 字符串解析后传入，非法值传 -1 → 走「信息不存在」。
  final int listingId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detailAsync = ref.watch(postDetailProvider(listingId));
    return detailAsync.when(
      loading: () => const _LoadingScreen(),
      error: (error, _) => _buildErrorScreen(error),
      data: (detail) => _buildDetail(detail),
    );
  }

  /// 组装详情正文（三态中的 data 态）。
  Widget _buildDetail(ListingDetail detail) {
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
      ),
      body: ListView(
        // 底部留出主按钮高度 + 安全区，否则最后一段内容会被按钮永久遮住，
        // 且用户无法察觉下面还有东西。
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          _MediaPlaceholder(category: detail.listing.category),
          _InfoSection(detail: detail),
          if (detail.templateFields.isNotEmpty)
            _TemplateSection(fields: detail.templateFields),
          _DescriptionSection(text: detail.description),
          _PublisherCard(
            publisher: detail.publisher,
            completeness: detail.completeness,
          ),
          if (detail.listing.supplyDemand == SupplyDemand.demand)
            const _DemandHelpEntry(),
        ],
      ),
      bottomNavigationBar: _ContactBar(detail: detail),
    );
  }

  /// 错误态分流：41001（信息下架/不存在）显示「信息不存在」，其余显示可重试错误。
  ///
  /// 必须先经 [asApiException] 归一：信封业务错误在链上以
  /// `DioException(error: ApiException)` 形态到达（EnvelopeInterceptor 的
  /// reject 载体），直接判 `error is ApiException` 恒为 false，41001 会落到
  /// 通用错误屏。既有范式见 category_selector_screen.dart / category_tree_provider.dart。
  Widget _buildErrorScreen(Object error) {
    final apiError = asApiException(error);
    // 41001 是「这条信息已下架/不存在」——用户的预期结果，非故障。
    if (apiError.code == ApiErrorCode.postGone) {
      return const _NotFoundScreen();
    }
    return const _ErrorScreen();
  }
}

/// 顶部媒体区占位（PRD §7.4.1 顶部媒体区）。
///
/// 用分类色渐变而非灰色占位块：灰块在验收时会被误认为「图没加载出来」，
/// 而带分类色的渐变一眼能看出是刻意的占位，且顺带验证了分类色在大面积
/// 铺色时的观感（Pin 上只有 40px，大面积下饱和度问题才会暴露）。
class _MediaPlaceholder extends StatelessWidget {
  const _MediaPlaceholder({required this.category});

  final ListingCategory category;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 200,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            category.color.withValues(alpha: 0.85),
            category.deepColor.withValues(alpha: 0.95),
          ],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              category.icon,
              size: 56,
              color: Colors.white.withValues(alpha: 0.9),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '图片区（待接入媒体上传）',
              style: TextStyle(
                fontSize: AppTypeScale.caption.size,
                color: Colors.white.withValues(alpha: 0.85),
              ),
            ),
          ],
        ),
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

/// 发布者信任卡（PRD §7.4.1）。
class _PublisherCard extends StatelessWidget {
  const _PublisherCard({required this.publisher, required this.completeness});

  final Publisher publisher;
  final CompletenessLevel completeness;

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
                if (publisher.qualificationLabel != null) ...[
                  const SizedBox(height: AppSpacing.xs),
                  _TrustLine(
                    icon: Icons.workspace_premium,
                    text: publisher.qualificationLabel!,
                  ),
                ],
                const SizedBox(height: AppSpacing.xs),
                _CompletenessLine(level: completeness),
              ],
            ),
          ),
        ],
      ),
    );
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
class _ContactBar extends StatelessWidget {
  const _ContactBar({required this.detail});

  final ListingDetail detail;

  @override
  Widget build(BuildContext context) {
    // 需求态按钮文案改为「响应需求」（§7.4.3）：对需求发布者说「联系 TA」
    // 语义是反的 —— 点击者是来提供资源的，不是来求助的。
    final isDemand = detail.listing.supplyDemand == SupplyDemand.demand;
    final label = isDemand ? '响应需求' : '联系 TA';

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
            onPressed: () => context.push('/contact/${detail.listing.id}'),
            icon: Icon(
              detail.contactChannel == ContactChannel.phone
                  ? Icons.phone
                  : Icons.chat_bubble_outline,
              size: 20,
            ),
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

/// 加载态（详情接口首次拉取中）。
class _LoadingScreen extends StatelessWidget {
  const _LoadingScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Color(AppColors.background),
      appBar: AppBar(
        toolbarHeight: 48,
        backgroundColor: Color(AppColors.surface),
        elevation: 0,
        title: const Text('详情'),
      ),
      body: const Center(child: CircularProgressIndicator()),
    );
  }
}

/// 通用错误态（网络失败 / 游客限频 42907 / 服务端错误等，非 41001）。
///
/// 不展示具体错误码：详情页失败对用户而言都是「暂时看不到这条信息」，
/// 具体原因（限频 vs 网络）在 §12.2 行为表的 UI 层再细分——本页只兜住
/// 「非 41001 的失败」这一档，避免把错误码细节泄给页面。
class _ErrorScreen extends StatelessWidget {
  const _ErrorScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Color(AppColors.background),
      appBar: AppBar(
        toolbarHeight: 48,
        backgroundColor: Color(AppColors.surface),
        elevation: 0,
        title: const Text('详情'),
      ),
      body: Center(
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
      ),
    );
  }
}

/// 信息不存在（已下架 / id 非法）。
class _NotFoundScreen extends StatelessWidget {
  const _NotFoundScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Color(AppColors.background),
      appBar: AppBar(
        backgroundColor: Color(AppColors.surface),
        elevation: 0,
        title: const Text('详情'),
      ),
      body: Center(
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
