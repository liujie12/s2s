/// 手动选择城市底部弹层（PRD §6.4.4「手动选择城市」出口，DEC-24）。
///
/// 城市列表来自 `/cities`（[citiesProvider]），选中城市用于确定地图中心与
/// `radius=city` 请求入参，不在客户端做行政区过滤。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design_tokens.dart';
import 'city.dart';
import 'city_provider.dart';

/// 弹出城市选择弹层。
///
/// 参数：[context] 当前构建上下文。
/// 返回：[Future]<[CityItem]?> 用户选中的城市；取消（下滑/点遮罩）返回 null。
Future<CityItem?> showCitySelectorSheet(BuildContext context) {
  return showModalBottomSheet<CityItem>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => const _CitySelectorSheet(),
  );
}

/// 城市选择弹层内容。
class _CitySelectorSheet extends ConsumerWidget {
  const _CitySelectorSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final citiesAsync = ref.watch(citiesProvider);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          0,
          AppSpacing.md,
          AppSpacing.md,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '手动选择城市',
              style: TextStyle(
                fontSize: AppTypeScale.h2.size,
                height: AppTypeScale.h2.lineHeight,
                fontWeight: FontWeight.w600,
                color: const Color(AppColors.textPrimary),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '用于确定地图中心，全城范围口径以所选城市为准',
              style: TextStyle(
                fontSize: AppTypeScale.small.size,
                color: const Color(AppColors.textSecondary),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Flexible(
              child: citiesAsync.when(
                loading: () => const _CityListLoading(),
                error: (error, _) => _CityListError(
                  onRetry: () => ref.invalidate(citiesProvider),
                ),
                data: (cities) => _CityList(
                  cities: cities,
                  onSelect: (city) => Navigator.pop(context, city),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 城市列表加载态。
class _CityListLoading extends StatelessWidget {
  const _CityListLoading();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      height: 160,
      child: Center(
        child: CircularProgressIndicator(),
      ),
    );
  }
}

/// 城市列表错误态（含重试）。
class _CityListError extends StatelessWidget {
  const _CityListError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 160,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            '城市列表加载失败',
            style: TextStyle(
              fontSize: AppTypeScale.body.size,
              color: const Color(AppColors.textSecondary),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}

/// 城市列表。
class _CityList extends StatelessWidget {
  const _CityList({required this.cities, required this.onSelect});

  final List<CityItem> cities;
  final void Function(CityItem) onSelect;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      shrinkWrap: true,
      itemCount: cities.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final city = cities[index];
        return ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(
            city.name,
            style: TextStyle(
              fontSize: AppTypeScale.body.size,
              color: const Color(AppColors.textPrimary),
            ),
          ),
          onTap: () => onSelect(city),
        );
      },
    );
  }
}
