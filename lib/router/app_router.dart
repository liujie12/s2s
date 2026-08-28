/// 路由表（PRD §10.1 页面清单）。
///
/// 用 go_router 而非 Navigator 1.0：声明式路由表能把「有哪些页面」这件事
/// 收在一个文件里，接棒人一眼看全；且深链与返回栈行为由路由表统一定义，
/// 不散落在各页的 push 调用里。
///
/// M4 范围 = PRD §10.1 中 P0 且属五大闭环的 12 项（说明文档 §2.7）。
/// 其余页面（收藏 / 设置 / 我的发布等）不在 M4，故本表**刻意不注册**——
/// 注册空壳会让人误以为已实现。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/contact/contact_screen.dart';
import '../features/detail/detail_screen.dart';
import '../features/discovery/list_screen.dart';
import '../features/map/map_screen.dart';
import '../features/placeholder/placeholder_screen.dart';
import '../features/privacy/privacy_consent.dart';
import '../features/privacy/privacy_gate_screen.dart';

/// 路由路径常量。
///
/// 为什么用常量而非字面量：路径要在跳转处、路由表、埋点三个地方出现，
/// 写错字面量只会在运行时白屏，用常量则编译期就报错。
class AppRoutes {
  const AppRoutes._();

  // ── 准入 ──
  static const String privacyGate = '/privacy-gate';
  static const String login = '/login';

  // ── 底部 Tab ──
  static const String home = '/';
  static const String profile = '/profile';

  // ── 首页内视图（不占底部 Tab，与地图共享筛选态，见 PRD §10.1）──
  static const String list = '/list';

  // ── 核心闭环 ──
  static const String detail = '/detail/:id';
  static const String publish = '/publish';
  static const String aiConfirm = '/publish/ai-confirm';
  static const String publishSuccess = '/publish/success';
  static const String contact = '/contact/:id';

  // ── 认证 ──
  static const String trust = '/trust';

  // ── 模态（PRD §10.1 三个模态）──
  static const String categorySelector = '/modal/category';
  static const String mapSelector = '/modal/map-picker';
  static const String certModal = '/modal/cert';
}

/// 应用路由表。
///
/// 做成 Provider 而非全局常量的原因：路由需要读隐私同意状态来决定是否
/// 强制跳转协议门（PRD §6.5.1）。这层拦截必须放在路由，而不是各页自查——
/// 各页自查等于每加一页就多一个可能漏判的地方，而漏判的后果是上架驳回。
final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: AppRoutes.home,

    // 同意状态一变就重算重定向。没有它，用户在协议门点「同意」后仍会停在门内。
    refreshListenable: _ConsentListenable(ref),

    /// 隐私协议门守卫。
    ///
    /// 返回：需要跳转时返回目标路径，无需跳转返回 null。
    redirect: (context, state) {
      final status = ref.read(privacyConsentProvider);
      final atGate = state.matchedLocation == AppRoutes.privacyGate;

      // unknown 表示本地存储还没读完。此时不跳转，避免已同意的用户
      // 在冷启动瞬间闪一下协议门（PRD §6.5.1 三态设计的用意）。
      if (status == PrivacyConsentStatus.unknown) return null;

      if (status != PrivacyConsentStatus.agreed) {
        return atGate ? null : AppRoutes.privacyGate;
      }
      // 已同意却还停在门上，放回首页
      return atGate ? AppRoutes.home : null;
    },
    routes: _routes,
  );
});

/// 把 Riverpod 的状态变化转成 go_router 能听的 Listenable。
///
/// go_router 的 refreshListenable 只认 Listenable，而 Riverpod 用的是
/// listen 回调，二者需要这层适配。
class _ConsentListenable extends ChangeNotifier {
  _ConsentListenable(Ref ref) {
    ref.listen(privacyConsentProvider, (_, _) => notifyListeners());
  }
}

/// 路由定义。
///
/// 当前多数页面为占位屏 —— 路由骨架的目的是先把导航拓扑固定下来，
/// 页面实现随 M4-3 逐个替换。占位屏会显著地显示「未实现」，避免
/// 空白页被误判为已完成。
final List<RouteBase> _routes = [
  GoRoute(
    path: AppRoutes.privacyGate,
    builder: (context, state) => const PrivacyGateScreen(),
  ),
  GoRoute(path: AppRoutes.home, builder: (context, state) => const MapScreen()),
  GoRoute(
    path: AppRoutes.login,
    builder: (context, state) => const PlaceholderScreen(
      pageId: 'login-screen',
      pageName: '登录/注册（合并）',
      note: '手机号验证码一步进入',
    ),
  ),
  GoRoute(
    path: AppRoutes.list,
    builder: (context, state) => const ListScreen(),
  ),
  GoRoute(
    path: AppRoutes.detail,
    builder: (context, state) =>
        DetailScreen(listingId: state.pathParameters['id']!),
  ),
  GoRoute(
    path: AppRoutes.publish,
    builder: (context, state) => const PlaceholderScreen(
      pageId: 'publish-screen',
      pageName: '发布页（模板+记忆）',
      note: '三级分类模板 + 发布记忆 + T2 四模式',
    ),
  ),
  GoRoute(
    path: AppRoutes.aiConfirm,
    builder: (context, state) => const PlaceholderScreen(
      pageId: 'ai-confirm-screen',
      pageName: 'AI 结果确认页',
      note: '逐字段 AI 猜测值 + 「AI 猜」角标 + 升 🟢 冲刺区',
    ),
  ),
  GoRoute(
    path: AppRoutes.publishSuccess,
    builder: (context, state) => const PlaceholderScreen(
      pageId: 'publish-success-screen',
      pageName: '发布完成页',
      note: '完整度卡：当前档 + 还差哪几项 + 权益三条',
    ),
  ),
  GoRoute(
    path: AppRoutes.contact,
    builder: (context, state) =>
        ContactScreen(listingId: state.pathParameters['id']!),
  ),
  GoRoute(
    path: AppRoutes.profile,
    builder: (context, state) => const PlaceholderScreen(
      pageId: 'profile-screen',
      pageName: '个人中心',
      note: '信任与认证入口',
    ),
  ),
  GoRoute(
    path: AppRoutes.trust,
    builder: (context, state) => const PlaceholderScreen(
      pageId: 'trust-screen',
      pageName: '信任与认证',
      note: '实名 + 资质二层认证',
    ),
  ),
  // ── 模态：用 fullscreenDialog 语义，返回栈行为与页面不同 ──
  GoRoute(
    path: AppRoutes.categorySelector,
    pageBuilder: (context, state) => const MaterialPage(
      fullscreenDialog: true,
      child: PlaceholderScreen(
        pageId: 'category-selector',
        pageName: '分类级联选择器（模态）',
        note: '三级分类级联',
      ),
    ),
  ),
  GoRoute(
    path: AppRoutes.mapSelector,
    pageBuilder: (context, state) => const MaterialPage(
      fullscreenDialog: true,
      child: PlaceholderScreen(
        pageId: 'map-selector',
        pageName: '地图选点（模态）',
        note: '地图打点选位',
      ),
    ),
  ),
  GoRoute(
    path: AppRoutes.certModal,
    pageBuilder: (context, state) => const MaterialPage(
      fullscreenDialog: true,
      child: PlaceholderScreen(
        pageId: 'cert-modal',
        pageName: '认证拦截浮层（模态）',
        note: '未实名发布拦截',
      ),
    ),
  ),
];
