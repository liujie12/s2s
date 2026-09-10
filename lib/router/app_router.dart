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

import '../domain/category_tree.dart';
import '../features/auth/login_screen.dart';
import '../features/contact/contact_screen.dart';
import '../features/detail/detail_screen.dart';
import '../features/discovery/list_screen.dart';
import '../features/map/map_screen.dart';
import '../features/placeholder/placeholder_screen.dart';
import '../features/privacy/privacy_consent.dart';
import '../features/privacy/privacy_gate_screen.dart';
import '../features/publish/ai_confirm_screen.dart';
import '../features/publish/category_selector_screen.dart';
import '../features/publish/cert_modal_screen.dart';
import '../features/publish/publish_form_state.dart';
import '../features/publish/publish_screen.dart';
import '../features/publish/publish_success_screen.dart';

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
    builder: (context, state) => const LoginScreen(),
  ),
  GoRoute(
    path: AppRoutes.list,
    builder: (context, state) => const ListScreen(),
  ),
  GoRoute(
    path: AppRoutes.detail,
    // 路径参数是 URL 字符串，帖子 ID 的域内类型为 int（契约 PostIdPath 为
    // int64，详细设计 §10.4.3），故解析收敛在路由这一处。
    // 解析失败取 -1 而不是抛异常：非法深链（如 /detail/abc）在语义上等于
    // 「这条信息不存在」，走 provider 返回 null → 页面显示「信息不存在」，
    // 与「已下架」是同一种用户可理解的结果；抛异常只会白屏。
    builder: (context, state) => DetailScreen(
      listingId: int.tryParse(state.pathParameters['id'] ?? '') ?? -1,
    ),
  ),
  GoRoute(
    path: AppRoutes.publish,
    builder: (context, state) => const PublishScreen(),
  ),
  GoRoute(
    path: AppRoutes.aiConfirm,
    // extra 传发布页的表单快照 —— 它就是 §5.10 Step 2 的 scope。
    // 允许为空是为了让路由可被直接访问时不崩，空则退化为空白表单。
    builder: (context, state) => AiConfirmScreen(
      form: state.extra as PublishFormState? ?? const PublishFormState(),
    ),
  ),
  GoRoute(
    path: AppRoutes.publishSuccess,
    // extra 为提交时的表单快照，用于算 §9.8 档位；为空时按 🔴 档展示。
    builder: (context, state) =>
        PublishSuccessScreen(form: state.extra as PublishFormState?),
  ),
  GoRoute(
    path: AppRoutes.contact,
    // 解析口径同 detail 路由（详细设计 §10.4.3）。
    builder: (context, state) => ContactScreen(
      listingId: int.tryParse(state.pathParameters['id'] ?? '') ?? -1,
    ),
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
    // extra 传入已选叶子 ID（可空），用于打开时展开到该分支。
    // 用 extra 而非 query 参数：它是一个 int? 而非字符串，
    // 走 query 要在两侧各做一次解析，而解析失败的表现是静默不回填。
    pageBuilder: (context, state) => MaterialPage(
      fullscreenDialog: true,
      child: CategorySelectorScreen(initialLeafId: state.extra as int?),
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
    // 用 CustomTransitionPage 而非 MaterialPage：抽屉是半透明的，
    // 需要透出下层的发布页，而 MaterialPage 没有 opaque 开关。
    pageBuilder: (context, state) => CustomTransitionPage<bool>(
      opaque: false,
      barrierDismissible: false,
      transitionsBuilder: (context, animation, secondary, child) =>
          FadeTransition(opacity: animation, child: child),
      child: CertModalScreen(
        // 直达此路由（深链、误跳）时没有 extra，退到「个人资质」——
        // 断言崩掉比显示一个略泛化的资质名更糟。
        cert:
            state.extra as RequiredCert? ?? RequiredCert.personalQualification,
      ),
    ),
  ),
];
