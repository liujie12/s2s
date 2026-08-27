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
import 'package:go_router/go_router.dart';

import '../features/placeholder/placeholder_screen.dart';

/// 路由路径常量。
///
/// 为什么用常量而非字面量：路径要在跳转处、路由表、埋点三个地方出现，
/// 写错字面量只会在运行时白屏，用常量则编译期就报错。
class AppRoutes {
  const AppRoutes._();

  // ── 准入 ──
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
/// 当前所有页面均为占位屏 —— 路由骨架的目的是先把导航拓扑固定下来，
/// 页面实现随 M4-3 逐个替换。占位屏会显著地显示「未实现」，避免
/// 空白页被误判为已完成。
final GoRouter appRouter = GoRouter(
  initialLocation: AppRoutes.home,
  routes: [
    GoRoute(
      path: AppRoutes.home,
      builder: (context, state) => const PlaceholderScreen(
        pageId: 'home-screen',
        pageName: '鸭圈首页（地图优先）',
        note: '分类分色 + 范围滑块 + Marker 聚合',
      ),
    ),
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
      builder: (context, state) => const PlaceholderScreen(
        pageId: 'list-screen',
        pageName: '列表页',
        note: '与地图共享同一套筛选与范围状态',
      ),
    ),
    GoRoute(
      path: AppRoutes.detail,
      builder: (context, state) => PlaceholderScreen(
        pageId: 'detail-screen',
        pageName: '详情页',
        note: '模板字段 + 信任卡 + 联系主按钮 · id=${state.pathParameters['id']}',
      ),
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
      builder: (context, state) => PlaceholderScreen(
        pageId: 'contact-screen',
        pageName: '联系中转页',
        note: '电话 / 微信二选一单轨 · id=${state.pathParameters['id']}',
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
  ],
);
