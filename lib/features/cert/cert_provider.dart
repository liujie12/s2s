/// trust 页数据层（[B2-11]）：认证状态 + 在架信息完整度分布。
///
/// 两条数据流并行取，合成一个视图模型 [TrustOverview]：
///   1. `GET /cert/status` → 实名状态 + 资质列表（[CertStatus]）；
///   2. `GET /posts/mine?status=active` → 在架信息的完整度分布（「我的信任指标」卡）。
///
/// **如实登记**：完整度分布取自 `GET /posts/mine` 的**单页**（`page_size` 上限
/// [NfrApi.pageSizeMax]），在架条目超过该上限时分布为**前 N 条**的样本而非全量。
/// 本轮内测期在架条目远小于上限，暂不为此新开聚合端点（避免造契约）。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../../domain/listing_detail.dart';
import '../../nfr_constants.dart';
import '../post/post_repository.dart';
import 'cert_models.dart';
import 'cert_repository.dart';

/// trust 页视图模型。
class TrustOverview {
  /// 构造视图模型。
  ///
  /// 参数：[cert] 认证状态；[distribution] 在架信息完整度分布（档位 → 条数）。
  const TrustOverview({required this.cert, required this.distribution});

  /// 认证状态。
  final CertStatus cert;

  /// 在架信息完整度分布（档位 → 条数）。
  final Map<CompletenessLevel, int> distribution;

  /// 在架信息总数（分布各档之和）。
  int get activeCount => distribution.values.fold(0, (sum, count) => sum + count);

  /// 某档位的条数（缺省 0）。
  ///
  /// 参数：[level] 完整度档位。
  /// 返回：int。
  int countOf(CompletenessLevel level) => distribution[level] ?? 0;

  /// 在架信息的「平均档位」（全部信息同档时显示该档；否则按占比最高的档）。
  ///
  /// 参数：无。
  /// 返回：[CompletenessLevel]；无在架信息时回 [CompletenessLevel.red]。
  CompletenessLevel get dominantLevel {
    if (activeCount == 0) return CompletenessLevel.red;
    var best = CompletenessLevel.red;
    var bestCount = -1;
    for (final level in CompletenessLevel.values) {
      if (countOf(level) > bestCount) {
        best = level;
        bestCount = countOf(level);
      }
    }
    return best;
  }
}

/// trust 页状态机。
class TrustOverviewNotifier extends Notifier<AsyncValue<TrustOverview>> {
  @override
  AsyncValue<TrustOverview> build() {
    unawaited(_load());
    return const AsyncValue.loading();
  }

  /// 并行拉两路数据并合成。
  ///
  /// 参数：无。
  /// 返回：[Future<void>]。
  Future<void> _load() async {
    try {
      final certFuture = ref.read(certRepositoryProvider).fetchCertStatus();
      final postsFuture = ref
          .read(postRepositoryProvider)
          .fetchMine(status: 'active', pageSize: NfrApi.pageSizeMax);
      final cert = await certFuture;
      final posts = await postsFuture;

      final distribution = <CompletenessLevel, int>{};
      for (final item in posts.items) {
        final level = CompletenessLevel.fromApi(item.completenessLevel);
        distribution[level] = (distribution[level] ?? 0) + 1;
      }
      state = AsyncValue.data(TrustOverview(cert: cert, distribution: distribution));
    } catch (e) {
      state = AsyncValue.error(asApiException(e), StackTrace.current);
    }
  }

  /// 重新拉取（重试 / 下拉刷新）。
  ///
  /// 参数：无。
  /// 返回：[Future<void>]。
  Future<void> refresh() async {
    state = const AsyncValue.loading();
    await _load();
  }
}

/// trust 页 Provider。
final trustOverviewProvider =
    NotifierProvider<TrustOverviewNotifier, AsyncValue<TrustOverview>>(
  TrustOverviewNotifier.new,
);
