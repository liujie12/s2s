/// 位置头与位置视图（原型 `prototype-figma/location-recalibration.html`）。
///
/// 两件事拆开：
/// - [LocationHeader]：筛选面板左上角的位置入口（来源 + 地名 + ›）；
/// - [LocationPanel]：点开后**就地**切换的位置视图（搜索地点 / 地图选点 /
///   当前搜索位置 / 当前定位 / 最近使用）。
///
/// 搜索地点不新增接口：直接复用 `POST /search/resolve` 已返回的
/// `anchor_name / anchor_lat / anchor_lng / anchor_source` 与
/// `community_candidates`，落点仍走门面 `setAnchor`（唯一写点）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_exception.dart';
import '../../core/text/location_label.dart';
import '../../design_tokens.dart';
import '../../router/app_router.dart';
import '../location/high_accuracy_locator.dart';
import '../location/location_center.dart';
import '../location/reverse_geocode.dart';
import '../publish/map_selector_screen.dart';
import 'discovery_filter.dart';
import 'effective_filter.dart';
import 'effective_filter_provider.dart';
import 'search_conditions.dart';
import 'search_intent.dart';
import 'search_repository.dart';

/// 最近使用列表的上限（原型 SPEC 01：最多 5 条）。
const int _kRecentLocationMax = 5;

/// 逆地理文案缓存 key：坐标按原值，精度提升（fix 变化）才算新点。
typedef _Point = ({double lat, double lng});

/// 坐标 → 可读地址（失败为空串，由调用方回退文案）。
final _addressLabelProvider = FutureProvider.family<String, _Point>(
  (ref, point) => reverseGeocodeLabel(lat: point.lat, lng: point.lng),
);

/// 锚点来源 → 界面文案。
///
/// 参数：[source] 契约 `anchor_source`（current/manual/poi/text/long_press）。
/// 返回：中文来源标签；未知值退化「地点」而不是显示英文原始值。
String locationSourceLabel(String? source) => switch (source) {
  'current' => '我的位置',
  'manual' || 'long_press' => '地图选点',
  'poi' || 'text' => '搜索',
  null || '' => '自选位置',
  _ => '地点',
};

/// 当前圆心的一行文案（列表空态回显用）。
///
/// 参数：[effective] 生效条件；[hasFix] 本会话是否取得过定位。
/// 返回：如「地图选点 · 望江路商圈」「我的位置」「未校准」。
String currentCenterLabel({
  required EffectiveFilter effective,
  required bool hasFix,
}) {
  if (effective.anchorLat != null && effective.anchorLng != null) {
    final String name = shortLocationLabel(effective.anchorName);
    return '${locationSourceLabel(effective.anchorSource)} · '
        '${name.isEmpty ? '自选位置' : name}';
  }
  return hasFix ? '我的位置' : '未校准';
}

/// 筛选面板左上角的位置头。
class LocationHeader extends ConsumerWidget {
  const LocationHeader({super.key, required this.onTap});

  /// 点按入口：由面板切到位置视图。
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final EffectiveFilter effective = ref.watch(effectiveFilterProvider);
    final LocationFix? fix = ref.watch(locationFixProvider);
    final LocationCenter center = ref.watch(locationCenterProvider);
    final bool hasAnchor =
        effective.anchorLat != null && effective.anchorLng != null;
    // 未校准＝没有显式锚点也没有任何有效定位，只能按默认中心搜索。
    final bool uncalibrated = !hasAnchor && fix == null;

    final String source;
    final String? place;
    if (hasAnchor) {
      source = locationSourceLabel(effective.anchorSource);
      place = effective.anchorName;
    } else if (fix != null) {
      source = '我的位置';
      place = _watchedLabel(ref, lat: fix.lat, lng: fix.lng);
    } else {
      source = '未校准';
      place = _watchedLabel(ref, lat: center.lat, lng: center.lng);
    }
    // 省市区前缀对本地用户没有信息量，只压展示，不改锚点里存的完整地址。
    final String? shownPlace = place == null ? null : shortLocationLabel(place);

    final Color textColor = uncalibrated
        ? const Color(AppColors.warningText)
        : const Color(AppColors.textPrimary);
    final Color sourceColor = uncalibrated
        ? const Color(AppColors.warningText).withValues(alpha: .82)
        : const Color(AppColors.textSecondary);

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        decoration: BoxDecoration(
          // 警示底色由 color/warning 12% 透明度派生，不引入新色值。
          color: uncalibrated
              ? const Color(AppColors.warning).withValues(alpha: .12)
              : null,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: uncalibrated
              ? Border.all(
                  color: const Color(AppColors.warning).withValues(alpha: .34),
                )
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.location_on_outlined,
              size: 17,
              color: uncalibrated
                  ? const Color(AppColors.warningText)
                  : const Color(AppColors.primary),
            ),
            const SizedBox(width: AppSpacing.xs),
            Flexible(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    source,
                    style: TextStyle(fontSize: 11, color: sourceColor),
                  ),
                  if (shownPlace != null && shownPlace.isNotEmpty) ...[
                    Text(
                      ' · ',
                      style: TextStyle(fontSize: 11, color: sourceColor),
                    ),
                    Flexible(
                      child: Text(
                        shownPlace,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: textColor,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 2),
            Text(
              '›',
              style: TextStyle(
                fontSize: 13,
                height: 1,
                color: uncalibrated
                    ? const Color(AppColors.warningText)
                    : const Color(AppColors.textPlaceholder),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 位置视图（同一底部面板内切换，不叠第二层）。
class LocationPanel extends ConsumerStatefulWidget {
  const LocationPanel({super.key, required this.onDone});

  /// 锚点写入成功后的回调（面板切回筛选视图，或由承载方关闭面板）。
  final VoidCallback onDone;

  @override
  ConsumerState<LocationPanel> createState() => _LocationPanelState();
}

class _LocationPanelState extends ConsumerState<LocationPanel> {
  /// 搜索输入框控制器。
  final TextEditingController _searchCtrl = TextEditingController();

  /// 是否正在解析地点。
  bool _searching = false;

  /// 解析失败/无结果的提示。
  String? _searchError;

  /// 最近一次解析结果（供结果行渲染）。
  SearchIntent? _resolved;

  /// 是否正在重新定位。
  bool _relocating = false;

  /// 重新定位失败的提示。
  String? _relocateError;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// 提交搜索框里的地名。
  ///
  /// 用回车/搜索键触发一次，而不是边输边搜：输入过程中每个前缀都会打一次
  /// `/search/resolve`，既浪费配额也会让结果闪跳。
  ///
  /// 参数：无；返回：Future，解析完成（失败只写提示，不向 UI 抛）。
  Future<void> _search() async {
    final String text = _searchCtrl.text.trim();
    if (text.isEmpty || _searching) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _searchError = null;
    });
    final LocationFix? fix = ref.read(locationFixProvider);
    final LocationCenter center = ref.read(locationCenterProvider);
    try {
      final SearchIntent intent = await ref
          .read(searchRepositoryProvider)
          .resolve(
            text: text,
            // 不给坐标会退化成全国检索，同名小区容易被匹到别的城市。
            currentLat: fix?.lat ?? center.lat,
            currentLng: fix?.lng ?? center.lng,
          );
      if (!mounted) return;
      setState(() {
        _searching = false;
        _resolved = intent;
        final bool hasAnchor =
            intent.anchorLat != null && intent.anchorLng != null;
        _searchError = hasAnchor || intent.communityCandidates.isNotEmpty
            ? null
            : '没有找到这个地点，换个说法或用「地图选点」';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _searchError = asApiException(error).uiMessage;
      });
    }
  }

  /// 打开地图选点页（发现侧：底部换半径档 + 「以此为中心搜索」）。
  ///
  /// 参数：无；返回：Future，选点页关闭后结束（取消则不改动条件）。
  Future<void> _pickOnMap() async {
    final EffectiveFilter effective = ref.read(effectiveFilterProvider);
    final LocationFix? fix = ref.read(locationFixProvider);
    final LocationCenter center = ref.read(locationCenterProvider);
    final MapPickResult? result = await context.push<MapPickResult>(
      AppRoutes.mapSelector,
      extra: MapSelectorArgs(
        lat: effective.anchorLat ?? fix?.lat ?? center.lat,
        lng: effective.anchorLng ?? fix?.lng ?? center.lng,
        purpose: MapSelectorPurpose.discovery,
        radius: toApiRadius(effective.radius),
      ),
    );
    if (result == null || !mounted) return;
    if (result.radius.isNotEmpty) {
      ref
          .read(searchConditionsProvider.notifier)
          .setRadius(searchRadiusFromApi(result.radius));
    }
    _applyAnchor(
      lat: result.lat,
      lng: result.lng,
      // 无地址时不重复写「地图选点」，否则位置头会显示「地图选点 · 地图选点」。
      name: result.address.isEmpty ? null : result.address,
      source: 'manual',
    );
  }

  /// 重新定位：只刷新「当前定位」行。
  ///
  /// 圆心仅在来源仍是「我的位置」（无显式锚点或来源为 current）时跟随；
  /// 已经地图选点/搜索过的圆心不动，避免把用户刚选的点悄悄改掉。
  ///
  /// 参数：无；返回：Future，定位结束（失败只写行下提示）。
  Future<void> _relocate() async {
    if (_relocating) return;
    setState(() {
      _relocating = true;
      _relocateError = null;
    });
    final LocationFix? fix = await ref.read(highAccuracyLocatorProvider).locate();
    if (!mounted) return;
    if (fix == null) {
      setState(() {
        _relocating = false;
        _relocateError = '重新定位失败，请检查定位权限后重试';
      });
      return;
    }
    ref
        .read(locationFixProvider.notifier)
        .update(lat: fix.lat, lng: fix.lng, accuracy: fix.accuracy);
    final EffectiveFilter effective = ref.read(effectiveFilterProvider);
    final bool followsMyLocation =
        effective.anchorLat == null || effective.anchorSource == 'current';
    if (followsMyLocation) {
      ref.read(locationCenterProvider.notifier).moveTo(fix.lat, fix.lng);
    }
    if (!mounted) return;
    setState(() => _relocating = false);
  }

  /// 写锚点并收尾（记录最近使用 → 通知承载方切回/关闭）。
  ///
  /// 参数：[lat]/[lng] 坐标；[name] 地点名；[source] 来源。
  /// 返回：无。
  void _applyAnchor({
    required double lat,
    required double lng,
    required String? name,
    required String source,
  }) {
    ref
        .read(searchConditionsProvider.notifier)
        .setAnchor(lat: lat, lng: lng, name: name, source: source);
    ref
        .read(recentLocationsProvider.notifier)
        .add(
          RecentLocation(
            name: (name == null || name.isEmpty) ? '自选位置' : name,
            lat: lat,
            lng: lng,
            source: source,
          ),
        );
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final EffectiveFilter effective = ref.watch(effectiveFilterProvider);
    final LocationFix? fix = ref.watch(locationFixProvider);
    final List<RecentLocation> recent = ref.watch(recentLocationsProvider);
    final String fixLabel = _relocating
        ? '定位中…'
        : (fix == null
              ? '未获取到定位'
              : _watchedLabel(
                  ref,
                  lat: fix.lat,
                  lng: fix.lng,
                  fallback: '当前位置',
                ));

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.xs,
        AppSpacing.lg,
        AppSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: _buildSearchField()),
              const SizedBox(width: AppSpacing.sm),
              _MapPickButton(onTap: _pickOnMap),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          _buildCurrentSearchBlock(effective: effective, fix: fix),
          const SizedBox(height: AppSpacing.md),
          _buildCurrentLocationRow(
            label: fixLabel,
            canRelocate: !_relocating,
          ),
          if (_relocateError != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(
                _relocateError!,
                style: TextStyle(
                  fontSize: AppTypeScale.caption.size,
                  color: const Color(AppColors.textSecondary),
                ),
              ),
            ),
          if (_searching || _resolved != null || _searchError != null) ...[
            const SizedBox(height: AppSpacing.md),
            _buildSearchFeedback(),
          ],
          if (recent.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            _buildRecentHeader(),
            for (final RecentLocation item in recent) _buildRecentRow(item),
          ],
        ],
      ),
    );
  }

  /// 搜索输入框（占位「搜索小区、商圈、地标」）。
  ///
  /// 参数：无；返回：搜索框控件。
  Widget _buildSearchField() {
    return SizedBox(
      height: 40,
      child: TextField(
        controller: _searchCtrl,
        textInputAction: TextInputAction.search,
        onSubmitted: (_) => _search(),
        onChanged: (_) => setState(() {}),
        style: TextStyle(
          fontSize: AppTypeScale.body.size,
          color: const Color(AppColors.textPrimary),
        ),
        decoration: InputDecoration(
          isDense: true,
          hintText: '搜索小区、商圈、地标',
          hintStyle: TextStyle(
            fontSize: AppTypeScale.body.size,
            color: const Color(AppColors.textPlaceholder),
          ),
          prefixIcon: const Icon(
            Icons.search,
            size: 18,
            color: Color(AppColors.textSecondary),
          ),
          suffixIcon: _searchCtrl.text.isEmpty
              ? null
              : GestureDetector(
                  onTap: () {
                    _searchCtrl.clear();
                    setState(() {
                      _resolved = null;
                      _searchError = null;
                    });
                  },
                  behavior: HitTestBehavior.opaque,
                  child: const Icon(
                    Icons.close,
                    size: 16,
                    color: Color(AppColors.textPlaceholder),
                  ),
                ),
          filled: true,
          fillColor: const Color(AppColors.background),
          contentPadding: EdgeInsets.zero,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(20),
            borderSide: const BorderSide(color: Color(AppColors.border)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(20),
            borderSide: const BorderSide(color: Color(AppColors.border)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(20),
            borderSide: const BorderSide(color: Color(AppColors.primary)),
          ),
        ),
      ),
    );
  }

  /// 当前搜索位置（只读：地名 + 来源 + 半径说明）。
  ///
  /// 参数：[effective] 生效条件；[fix] 本会话定位点。
  /// 返回：信息块控件。
  Widget _buildCurrentSearchBlock({
    required EffectiveFilter effective,
    required LocationFix? fix,
  }) {
    final bool hasAnchor =
        effective.anchorLat != null && effective.anchorLng != null;
    final String name = hasAnchor
        ? (effective.anchorName ?? '自选位置')
        : (fix != null ? '我的位置' : '未校准');
    final String source = hasAnchor
        ? locationSourceLabel(effective.anchorSource)
        : (fix != null ? '我的位置' : '未校准');
    final String note = effective.radius == SearchRadius.city
        ? '全城范围，列表与地图共用'
        : '半径 ${effective.radius.label} 以该点为准，列表与地图共用';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '当前搜索位置',
          style: TextStyle(
            fontSize: AppTypeScale.caption.size,
            color: const Color(AppColors.textSecondary),
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Row(
          children: [
            const Icon(
              Icons.location_on,
              size: 16,
              color: Color(AppColors.primary),
            ),
            const SizedBox(width: AppSpacing.xs),
            Flexible(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppTypeScale.body.size,
                  fontWeight: FontWeight.w600,
                  color: const Color(AppColors.textPrimary),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.xs),
            Text(
              source,
              style: TextStyle(
                fontSize: AppTypeScale.caption.size,
                color: const Color(AppColors.textSecondary),
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          note,
          style: TextStyle(
            fontSize: AppTypeScale.caption.size,
            color: const Color(AppColors.textPlaceholder),
          ),
        ),
      ],
    );
  }

  /// 当前定位行（值 + 重新定位）。
  ///
  /// 参数：[label] 当前定位文案；[canRelocate] 是否可点（定位中禁用防连点）。
  /// 返回：行控件。
  Widget _buildCurrentLocationRow({
    required String label,
    required bool canRelocate,
  }) {
    return Row(
      children: [
        Text(
          '当前定位',
          style: TextStyle(
            fontSize: AppTypeScale.small.size,
            color: const Color(AppColors.textSecondary),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: AppTypeScale.small.size,
              color: const Color(AppColors.textPrimary),
            ),
          ),
        ),
        GestureDetector(
          onTap: canRelocate ? _relocate : null,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.refresh,
                  size: 14,
                  color: canRelocate
                      ? const Color(AppColors.primary)
                      : const Color(AppColors.textPlaceholder),
                ),
                const SizedBox(width: 2),
                Text(
                  _relocating ? '重新定位中' : '重新定位',
                  style: TextStyle(
                    fontSize: AppTypeScale.caption.size,
                    color: canRelocate
                        ? const Color(AppColors.primary)
                        : const Color(AppColors.textPlaceholder),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 搜索进度 / 结果 / 失败提示。
  ///
  /// 参数：无；返回：结果区控件（无结果且无提示时为空）。
  Widget _buildSearchFeedback() {
    if (_searching) {
      return Text(
        '正在搜索地点…',
        style: TextStyle(
          fontSize: AppTypeScale.caption.size,
          color: const Color(AppColors.textSecondary),
        ),
      );
    }
    final SearchIntent? intent = _resolved;
    final List<Widget> rows = <Widget>[];
    if (intent != null &&
        intent.anchorLat != null &&
        intent.anchorLng != null) {
      final double lat = intent.anchorLat!;
      final double lng = intent.anchorLng!;
      final String name = intent.anchorName ?? _searchCtrl.text.trim();
      rows.add(
        _PlaceRow(
          icon: Icons.place_outlined,
          title: name,
          subtitle: locationSourceLabel(intent.anchorSource),
          onTap: () => _applyAnchor(
            lat: lat,
            lng: lng,
            name: name,
            source: intent.anchorSource ?? 'poi',
          ),
        ),
      );
    }
    if (intent != null) {
      for (final CommunityCandidate candidate in intent.communityCandidates) {
        rows.add(
          _PlaceRow(
            icon: Icons.apartment_outlined,
            title: candidate.name,
            subtitle: candidate.district.isEmpty
                ? '小区'
                : '小区 · ${candidate.district}',
            onTap: () => _applyAnchor(
              lat: candidate.lat,
              lng: candidate.lng,
              name: candidate.name,
              source: 'poi',
            ),
          ),
        );
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (rows.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.xs),
            child: Text(
              '找到 ${rows.length} 个地点',
              style: TextStyle(
                fontSize: AppTypeScale.caption.size,
                color: const Color(AppColors.textSecondary),
              ),
            ),
          ),
        ...rows,
        if (_searchError != null)
          Text(
            _searchError!,
            style: TextStyle(
              fontSize: AppTypeScale.caption.size,
              color: const Color(AppColors.errorText),
            ),
          ),
      ],
    );
  }

  /// 最近使用的标题行（含清空）。
  ///
  /// 参数：无；返回：标题行控件。
  Widget _buildRecentHeader() {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Row(
        children: [
          Text(
            '最近使用',
            style: TextStyle(
              fontSize: AppTypeScale.caption.size,
              color: const Color(AppColors.textSecondary),
            ),
          ),
          const Spacer(),
          GestureDetector(
            onTap: () => ref.read(recentLocationsProvider.notifier).clear(),
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                '清空',
                style: TextStyle(
                  fontSize: AppTypeScale.caption.size,
                  color: const Color(AppColors.textPlaceholder),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 最近使用的一条。
  ///
  /// 参数：[item] 最近使用的地点；返回：可点行控件。
  Widget _buildRecentRow(RecentLocation item) {
    return _PlaceRow(
      icon: Icons.history,
      title: item.name,
      subtitle: locationSourceLabel(item.source),
      onTap: () => _applyAnchor(
        lat: item.lat,
        lng: item.lng,
        name: item.name,
        source: item.source,
      ),
    );
  }
}

/// 读取某点的逆地理文案（未取到/未注入 Key 时返回 [fallback]）。
///
/// 参数：[ref] 组件引用；[lat]/[lng] 坐标；[fallback] 空文案时的兜底。
/// 返回：地址文案。
String _watchedLabel(
  WidgetRef ref, {
  required double lat,
  required double lng,
  String fallback = '',
}) {
  final String label =
      ref.watch(_addressLabelProvider((lat: lat, lng: lng))).asData?.value ??
      '';
  return label.isEmpty ? fallback : label;
}

/// 主色胶囊按钮「地图选点」。
class _MapPickButton extends StatelessWidget {
  const _MapPickButton({required this.onTap});

  /// 点按回调。
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        decoration: BoxDecoration(
          color: const Color(AppColors.primary),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.place_outlined, size: 16, color: Colors.white),
            const SizedBox(width: AppSpacing.xs),
            Text(
              '地图选点',
              style: TextStyle(
                fontSize: AppTypeScale.small.size,
                fontWeight: FontWeight.w600,
                color: const Color(AppColors.surface),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 结果/最近使用的一行地点。
class _PlaceRow extends StatelessWidget {
  const _PlaceRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  /// 行首图标。
  final IconData icon;

  /// 地点名。
  final String title;

  /// 来源/区域说明。
  final String subtitle;

  /// 点按：采用该地点。
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Row(
          children: [
            Icon(icon, size: 17, color: const Color(AppColors.textSecondary)),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppTypeScale.small.size,
                      fontWeight: FontWeight.w600,
                      color: const Color(AppColors.textPrimary),
                    ),
                  ),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppTypeScale.caption.size,
                      color: const Color(AppColors.textPlaceholder),
                    ),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.chevron_right,
              size: 16,
              color: Color(AppColors.textPlaceholder),
            ),
          ],
        ),
      ),
    );
  }
}

/// 最近使用的一处地点（仅本次会话，不落本地存储）。
class RecentLocation {
  const RecentLocation({
    required this.name,
    required this.lat,
    required this.lng,
    required this.source,
  });

  /// 地点名。
  final String name;

  /// 纬度（GCJ-02）。
  final double lat;

  /// 经度（GCJ-02）。
  final double lng;

  /// 来源（manual/poi/current）。
  final String source;
}

/// 最近使用列表读写入口。
class RecentLocationsNotifier extends Notifier<List<RecentLocation>> {
  @override
  List<RecentLocation> build() => const <RecentLocation>[];

  /// 记一条最近使用（同名同点去重并置顶，超过上限丢最旧）。
  ///
  /// 参数：[item] 新采用的地点；返回：无。
  void add(RecentLocation item) {
    final List<RecentLocation> next = [
      item,
      for (final RecentLocation old in state)
        if (!(old.name == item.name && old.lat == item.lat && old.lng == item.lng))
          old,
    ];
    state = next.length > _kRecentLocationMax
        ? next.sublist(0, _kRecentLocationMax)
        : next;
  }

  /// 清空最近使用。
  void clear() => state = const <RecentLocation>[];
}

/// 最近使用 Provider（会话内）。
final recentLocationsProvider =
    NotifierProvider<RecentLocationsNotifier, List<RecentLocation>>(
      RecentLocationsNotifier.new,
    );
