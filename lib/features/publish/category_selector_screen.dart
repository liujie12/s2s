/// 分类级联选择器（PRD §5.4.2 全屏模态 / §10.1 `category-selector`）。
///
/// **为什么是全屏模态而不是三个下拉**：§5.4.2 定的是「三列滚动：大类 5 列横向卡片
/// → 中类左侧 List → 小类右侧 List」。下拉在 48 个叶子的规模下要点三次、
/// 每次都盖住上一次的选择，用户无法回看自己选到哪了。
///
/// **为什么选完不立刻返回，而要点「确认选择」**：§5.4.2 末条明写底部确认按钮。
/// 点叶子即返回看似少一步，但用户点错叶子就得重开模态从大类选起 ——
/// 确认按钮给的是「点错了可以就地改」。
///
/// **不做的一项**：拼音首字母与同义词搜索（§2.9）。条目 [71] 已记明理由 ——
/// 三列直选已能覆盖发布闭环，搜索是效率优化，且同义词表属运营配置。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../../design_tokens.dart';
import '../../domain/category_tree.dart';
// 只用到色与图标，故只 import style 扩展（详细设计 §10.4.1）。
import '../../domain/listing_category_style.dart';
import '../category/category_tree_provider.dart';

/// 级联选择结果。
///
/// 用叶子 ID 而非三个节点回传：叶子 ID 是 §13.2 `post.leaf_category_id` 那个
/// 契约值，路径可由它推出（`categoryPathOf`）。回传三个节点等于让调用方
/// 自己去拼那个 ID，而拼错的表现是入库分类与显示分类不一致。
typedef CategorySelection = int;

/// 分类级联选择器页面。
///
/// 用法：`Navigator.push<CategorySelection>` 或 go_router 的 `push`，
/// 返回选中的叶子 ID；用户返回未确认时为 null。
///
/// 数据源为分类树 Provider（[124] B2 接线）：缓存树先行渲染、版本协商
/// 结果驱动重建；三态按编码规范 §5.6 渲染（loading 骨架 / error 重试 /
/// data 三列），不再直读内置常量树。
class CategorySelectorScreen extends ConsumerStatefulWidget {
  const CategorySelectorScreen({super.key, this.initialLeafId});

  /// 打开时预选的叶子 ID（发布页已选过分类时回填），null 表示未选。
  final int? initialLeafId;

  @override
  ConsumerState<CategorySelectorScreen> createState() =>
      _CategorySelectorScreenState();
}

class _CategorySelectorScreenState
    extends ConsumerState<CategorySelectorScreen> {
  /// 当前展开的一级、二级节点与选中的叶子。
  ///
  /// 存节点而非索引：索引在树改版后会静默指向别的类目，而节点对不上时
  /// 是空指针那种当场可见的错。均可空：分类树是异步数据，到达前无选择。
  CategoryNode? _top;
  CategoryNode? _mid;
  CategoryNode? _leaf;

  /// 预选展开是否已执行（树到达后只做一次，后续切树不覆盖用户已点选择）。
  bool _selectionInitialized = false;

  /// 树到达后做一次预选展开（initState 拿不到异步树，改为首帧数据到达时）。
  ///
  /// 有预选值则展开到它所在的分支，让用户看到自己上次选的位置；
  /// 否则停在第一个大类。直接给空白三列会让人不知道该从哪一列开始点。
  /// build 期间直接赋字段（非 setState）：紧接着本帧即用于渲染。
  void _ensureSelection(List<CategoryNode> tree) {
    if (_selectionInitialized || tree.isEmpty) return;
    _selectionInitialized = true;
    final path = widget.initialLeafId == null
        ? const <CategoryNode>[]
        : categoryPathOf(widget.initialLeafId!, tree: tree);
    if (path.length == 3) {
      _top = path[0];
      _mid = path[1];
      _leaf = path[2];
    } else {
      _top = tree.first;
      _mid = tree.first.children.firstOrNull;
    }
  }

  /// 切换一级大类。
  ///
  /// 切大类必须清掉二三级选择：留着上一个大类的叶子，会出现「大类显示车辆、
  /// 已选叶子却是日常保洁」这种确认后才发现的错配。
  void _selectTop(CategoryNode top) {
    setState(() {
      _top = top;
      _mid = top.children.firstOrNull;
      _leaf = null;
    });
  }

  void _selectMid(CategoryNode mid) {
    setState(() {
      _mid = mid;
      _leaf = null;
    });
  }

  void _selectLeaf(CategoryNode leaf) => setState(() => _leaf = leaf);

  @override
  Widget build(BuildContext context) {
    final treeAsync = ref.watch(categoryTreeProvider);
    return Scaffold(
      backgroundColor: Color(AppColors.background),
      appBar: AppBar(
        toolbarHeight: 48,
        backgroundColor: Color(AppColors.surface),
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: Color(AppColors.textPrimary)),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          '选择分类',
          style: TextStyle(
            fontSize: AppTypeScale.h3.size,
            fontWeight: FontWeight.w600,
            color: Color(AppColors.textPrimary),
          ),
        ),
      ),
      body: treeAsync.when(
        // 空态≠错误态（编码规范 §5.6），但「线上空树」是服务端违约形态
        // （契约必有类目），按数据异常渲染并给重试入口，不渲染空三列。
        data: (tree) =>
            tree.isEmpty ? _buildError(null, isEmptyTree: true) : _buildTree(tree),
        loading: _buildLoading,
        error: (error, _) => _buildError(asApiException(error)),
      ),
    );
  }

  /// 三列级联主体（data 态）。
  Widget _buildTree(List<CategoryNode> tree) {
    _ensureSelection(tree);
    return Column(
      children: [
        _TopCategoryRow(items: tree, selected: _top, onSelect: _selectTop),
        const Divider(height: 1),
        // 二三级左右并排，各自独立滚动（§5.4.2「中类左侧 List / 小类右侧 List」）。
        // 用 Expanded 包住而非固定高度：横屏与小屏下固定高度会让确认按钮被挤出屏幕。
        Expanded(
          child: Row(
            children: [
              SizedBox(
                width: 132,
                child: _MidColumn(
                  items: _top?.children ?? const [],
                  selected: _mid,
                  onSelect: _selectMid,
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: _LeafColumn(
                  items: _mid?.children ?? const [],
                  selected: _leaf,
                  onSelect: _selectLeaf,
                ),
              ),
            ],
          ),
        ),
        _ConfirmBar(
          leaf: _leaf,
          tree: tree,
          onConfirm: _leaf == null
              ? null
              : () => Navigator.of(context).pop<CategorySelection>(_leaf!.id),
        ),
      ],
    );
  }

  /// 加载骨架（§5.6 首屏不转圈）：三列结构的静态灰块占位，
  /// 不引 shimmer 库——骨架只活一次协商请求的时长。
  Widget _buildLoading() {
    Widget bar(double width, double height) => Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Color(AppColors.border),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          color: Color(AppColors.surface),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: [
              for (var i = 0; i < 5; i++)
                Expanded(
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    height: 44,
                    decoration: BoxDecoration(
                      color: Color(AppColors.border),
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 132,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < 6; i++) ...[
                        bar(96, 16),
                        const SizedBox(height: 20),
                      ],
                    ],
                  ),
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < 6; i++) ...[
                        bar(140, 16),
                        const SizedBox(height: 20),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 错误态（§5.6 与 loading/空态分开）：文案取 [ApiException.uiMessage]
  ///（§11.4 唯一格式 `{message}（{request_id}）`，唯一实现处在
  /// ApiException）。
  /// [error] 链上归一后的异常；null 且 [isEmptyTree] 表示线上空树
  /// （服务端违约形态，无异常对象可展示）。
  Widget _buildError(ApiException? error, {bool isEmptyTree = false}) {
    final message = isEmptyTree ? '分类数据为空，请稍后重试' : error!.uiMessage;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_outlined,
              size: 40,
              color: Color(AppColors.textPlaceholder),
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppTypeScale.body.size,
                color: Color(AppColors.textSecondary),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 40,
              child: ElevatedButton(
                onPressed: () => ref.invalidate(categoryTreeProvider),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Color(AppColors.primary),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.full),
                  ),
                ),
                child: const Text('重新加载'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 一级大类横向卡片行（§5.4.2「大类 5 列横向卡片」）。
class _TopCategoryRow extends StatelessWidget {
  const _TopCategoryRow({
    required this.items,
    required this.selected,
    required this.onSelect,
  });

  /// 当前生效树的一级节点（分类树 Provider 数据，[124] B2）。
  final List<CategoryNode> items;

  /// 当前展开的一级节点；树到达前为 null（无高亮）。
  final CategoryNode? selected;
  final ValueChanged<CategoryNode> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Color(AppColors.surface),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Row(
        children: [
          for (final top in items)
            Expanded(
              child: _TopCard(
                node: top,
                active: top.id == selected?.id,
                onTap: () => onSelect(top),
              ),
            ),
        ],
      ),
    );
  }
}

class _TopCard extends StatelessWidget {
  const _TopCard({
    required this.node,
    required this.active,
    required this.onTap,
  });

  final CategoryNode node;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // 一级节点的 topCategory 由 id 推出（category_tree.dart），故这里直接取大类色。
    // 该 getter 现为可空（详细设计 §10.4.1：一级编号超出 1..5 时用显式 switch
    // 返回 null，而不是 values[top-1] 抛 RangeError）。本页的数据源是本地
    // 常量树，理论上取不到 null，但仍按中性配色降级 —— 断言崩掉整页
    // 比一个灰色卡片糟糕得多。
    final category = node.topCategory;
    final Color activeBg = category?.deepColor ?? neutralCategoryColor;
    final Color iconColor = category?.color ?? neutralCategoryColor;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        // 44 高 + 横向 4 间距，保证触达区不小于 §1.4 的 44×44 最小触达
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          // 选中用大类深色实底 + 白字：原色底白字五类全部不过 WCAG AA
          //（listing_category_style.dart 已实算），故承载文字一律用 deepColor。
          color: active ? activeBg : Color(AppColors.background),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Column(
          children: [
            Icon(
              category?.icon ?? neutralCategoryIcon,
              size: 20,
              color: active ? Colors.white : iconColor,
            ),
            const SizedBox(height: 4),
            Text(
              node.name,
              style: TextStyle(
                fontSize: AppTypeScale.caption.size,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                color: active ? Colors.white : Color(AppColors.textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 二级列表（左列）。
class _MidColumn extends StatelessWidget {
  const _MidColumn({
    required this.items,
    required this.selected,
    required this.onSelect,
  });

  final List<CategoryNode> items;
  final CategoryNode? selected;
  final ValueChanged<CategoryNode> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Color(AppColors.background),
      child: ListView.builder(
        itemCount: items.length,
        itemBuilder: (context, i) {
          final node = items[i];
          final active = node.id == selected?.id;
          return GestureDetector(
            onTap: () => onSelect(node),
            child: Container(
              // 选中项用白底 + 左侧主色竖条，与右列白底连成一片，
              // 视觉上表达「右列内容属于这一项」——单靠文字加粗读不出这层归属。
              color: active ? Color(AppColors.surface) : null,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              child: Row(
                children: [
                  Container(
                    width: 3,
                    height: 16,
                    color: active
                        ? Color(AppColors.primary)
                        : Colors.transparent,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      node.name,
                      style: TextStyle(
                        fontSize: AppTypeScale.body.size,
                        fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                        color: active
                            ? Color(AppColors.textPrimary)
                            : Color(AppColors.textSecondary),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 三级叶子列表（右列）。选中态为 §5.4.2「Primary 色 + ✓」。
class _LeafColumn extends StatelessWidget {
  const _LeafColumn({
    required this.items,
    required this.selected,
    required this.onSelect,
  });

  final List<CategoryNode> items;
  final CategoryNode? selected;
  final ValueChanged<CategoryNode> onSelect;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return Container(
        color: Color(AppColors.surface),
        alignment: Alignment.topCenter,
        padding: const EdgeInsets.only(top: 24),
        child: Text(
          '请先选择左侧类目',
          style: TextStyle(
            fontSize: AppTypeScale.small.size,
            color: Color(AppColors.textPlaceholder),
          ),
        ),
      );
    }
    return Container(
      color: Color(AppColors.surface),
      child: ListView.builder(
        itemCount: items.length,
        itemBuilder: (context, i) {
          final node = items[i];
          final active = node.id == selected?.id;
          return InkWell(
            onTap: () => onSelect(node),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      node.name,
                      style: TextStyle(
                        fontSize: AppTypeScale.body.size,
                        fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                        color: active
                            ? Color(AppColors.primary)
                            : Color(AppColors.textPrimary),
                      ),
                    ),
                  ),
                  // 高敏类目在选择时就标出来，而不是等点了「发布」才弹拦截：
                  // §5.8 的拦截发生在提交前，那时用户已经填完整张表单，
                  // 此时才告知「你没这个资质」是把人一路带到墙上。
                  if (node.requiredCert != RequiredCert.none)
                    _CertChip(cert: node.requiredCert),
                  if (active) ...[
                    const SizedBox(width: 8),
                    Icon(Icons.check, size: 18, color: Color(AppColors.primary)),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 高敏类目的资质提示片。
class _CertChip extends StatelessWidget {
  const _CertChip({required this.cert});

  final RequiredCert cert;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        // 与联系中转页温馨提示同一配方（contact_screen.dart:550）：
        // warning 是图形色，承载文字须换 warningText，故底用 10% 淡化的 warning。
        color: Color(AppColors.warning).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Text(
        '需${cert.label}',
        style: TextStyle(
          fontSize: AppTypeScale.caption.size,
          color: Color(AppColors.warningText),
        ),
      ),
    );
  }
}

/// 底部确认条（§5.4.2 末条「底部确认按钮『确认选择』」）。
class _ConfirmBar extends StatelessWidget {
  const _ConfirmBar({
    required this.leaf,
    required this.tree,
    required this.onConfirm,
  });

  final CategoryNode? leaf;

  /// 当前生效树（面包屑回溯用，[categoryPathOf] 的 tree 参数）。
  final List<CategoryNode> tree;
  final VoidCallback? onConfirm;

  @override
  Widget build(BuildContext context) {
    // 面包屑实时回显选择：只显示「确认选择」按钮的话，用户在长列表里
    // 滚动几屏后已经看不到自己选的是哪一项。
    final path = leaf == null
        ? const <String>[]
        : [
            for (final n in categoryPathOf(leaf!.id, tree: tree)) n.name,
          ];
    return Container(
      color: Color(AppColors.surface),
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 12,
        // 加安全区内边距，否则全面屏手机上按钮会压在手势条上
        bottom: 12 + MediaQuery.of(context).padding.bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            path.isEmpty ? '未选择分类' : path.join(' > '),
            style: TextStyle(
              fontSize: AppTypeScale.small.size,
              color: path.isEmpty
                  ? Color(AppColors.textPlaceholder)
                  : Color(AppColors.textPrimary),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 48,
            child: ElevatedButton(
              onPressed: onConfirm,
              style: ElevatedButton.styleFrom(
                backgroundColor: Color(AppColors.primary),
                disabledBackgroundColor: Color(AppColors.border),
                foregroundColor: Colors.white,
                disabledForegroundColor: Color(AppColors.textPlaceholder),
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.full),
                ),
              ),
              child: Text(
                '确认选择',
                style: TextStyle(
                  fontSize: AppTypeScale.body.size,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
