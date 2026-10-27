/// 收藏态唯一事实源（KTD2 / R6）。
///
/// 键为「会话 + 帖子」：`userId` 进键意味着换号后旧条目天然失效，
/// 登出 / 换号时 [FavoriteStateNotifier.build] 因会话派生值变化而重跑，
/// 容器清空。服务端 `PostDetail.favorited` 只做首次填充与对账（[seed]），
/// 交互路径一律读写本容器 —— 详情页与「我的收藏」页因此共享同一处状态。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_repository.dart';
import 'favorite_repository.dart';

/// 收藏态键：当前会话 + 帖子 ID（KTD2）。
class FavoriteKey {
  /// 构造收藏态键。
  ///
  /// 参数：[userId] 登录用户 ID（`AuthSession.userId`）；[postId] 帖子 ID。
  const FavoriteKey({required this.userId, required this.postId});

  /// 登录用户 ID（会话标识，换号即换键）。
  final String userId;

  /// 帖子 ID。
  final int postId;

  @override
  bool operator ==(Object other) =>
      other is FavoriteKey &&
      other.userId == userId &&
      other.postId == postId;

  @override
  int get hashCode => Object.hash(userId, postId);
}

/// 收藏态容器：`(userId, postId) → 是否已收藏`。
class FavoriteStateNotifier extends Notifier<Map<FavoriteKey, bool>> {
  /// 在途请求（KTD3：同帖只保留一个在途请求，连点按先撤销再执行排队）。
  final Set<FavoriteKey> _inFlight = <FavoriteKey>{};

  @override
  Map<FavoriteKey, bool> build() {
    // 登录 / 登出 / 换号都改变派生值：旧会话的条目对新会话无效，直接清空。
    ref.watch(authSessionProvider.select((session) => session?.userId));
    _inFlight.clear();
    return const <FavoriteKey, bool>{};
  }

  /// 当前会话下该帖的键；未登录返回 null。
  ///
  /// 参数：[postId] 帖子 ID。
  /// 返回：`FavoriteKey?`。
  FavoriteKey? _keyFor(int postId) {
    final userId = ref.read(authSessionProvider)?.userId;
    if (userId == null) return null;
    return FavoriteKey(userId: userId, postId: postId);
  }

  /// 读取当前会话下该帖的收藏态。
  ///
  /// 参数：[postId] 帖子 ID。
  /// 返回：`true` 已收藏 / `false` 未收藏 / `null` 未知（未登录或未填充）。
  bool? read(int postId) {
    final key = _keyFor(postId);
    return key == null ? null : state[key];
  }

  /// 用已加载的收藏态做首次填充（已有值不覆盖；未登录不写）。
  ///
  /// 参数：[postId] 帖子 ID；[favorited] 服务端或列表页给出的收藏态。
  /// 返回：void。
  void seed(int postId, bool favorited) {
    final key = _keyFor(postId);
    if (key == null || state.containsKey(key)) return;
    state = {...state, key: favorited};
  }

  /// 写入已确认的服务端结果（收藏页取消后同步共享态，R6）。
  ///
  /// 参数：[postId] 帖子 ID；[favorited] 已确认的收藏态。
  /// 返回：void；未登录不写。
  void mark(int postId, bool favorited) {
    final key = _keyFor(postId);
    if (key == null) return;
    state = {...state, key: favorited};
  }

  /// 乐观写入并提交服务端，失败回滚并把异常抛给页面（R4）。
  ///
  /// 参数：[postId] 帖子 ID；[favorited] 目标状态（`true` 收藏 / `false` 取消）。
  /// 返回：服务端回执确认后的收藏态。
  /// 抛出：[ApiException] 请求失败时（已回滚到请求前的值）。
  Future<bool> set(int postId, bool favorited) async {
    // 未登录由页面先走登录再调用，此处必已登录。
    final key = _keyFor(postId)!;
    if (_inFlight.contains(key)) return state[key] ?? favorited;

    _inFlight.add(key);
    final previous = state[key];
    state = {...state, key: favorited};
    try {
      final repository = ref.read(favoriteRepositoryProvider);
      final result = favorited
          ? await repository.addFavorite(postId)
          : await repository.removeFavorite(postId);
      // 请求在途期间可能已换号：只有同一会话才写回。
      if (_keyFor(postId) == key) {
        state = {...state, key: result.favorited};
      }
      return result.favorited;
    } catch (_) {
      if (_keyFor(postId) == key) {
        if (previous == null) {
          state = {...state}..remove(key);
        } else {
          state = {...state, key: previous};
        }
      }
      rethrow;
    } finally {
      _inFlight.remove(key);
    }
  }
}

/// 收藏态 Provider（详情页与「我的收藏」页共读共写）。
final favoriteStateProvider =
    NotifierProvider<FavoriteStateNotifier, Map<FavoriteKey, bool>>(
  FavoriteStateNotifier.new,
);
