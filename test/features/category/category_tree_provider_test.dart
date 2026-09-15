/// 分类树状态层测试（[124] 前端段 / B2）。
///
/// 三组覆盖：
///   - [CategoryTreeStore]：持久化存取与坏缓存自愈（shared_preferences
///     mock 注入，同 device_id_provider_test 模式）；
///   - [categoryNodesFromDtos]：DTO→domain 转换（requiredCert 本地映射三态）；
///   - [CategoryTreeNotifier]：缓存先行 → 版本协商 → unchanged 保持 /
///     full 替换 + 落盘 + 清 Pin 口子的全状态机，走 NetworkChainHarness
///     真 HTTP 栈（不 mock repository）。
library;

import 'dart:convert';
import 'dart:io' show HttpOverrides;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhaoyazhao/core/network/api_client.dart';
import 'package:zhaoyazhao/core/network/api_error_code.dart';
import 'package:zhaoyazhao/core/network/api_exception.dart';
import 'package:zhaoyazhao/domain/category_tree.dart';
import 'package:zhaoyazhao/features/category/category_dto.dart';
import 'package:zhaoyazhao/features/category/category_tree_provider.dart';

import '../../support/category_fixtures.dart';
import '../../support/network_chain_harness.dart';

void main() {
  // SharedPreferences.setMockInitialValues 需要 binding 持有 method channel
  // mock；但 TestWidgetsFlutterBinding 构造时会装禁网 HttpOverrides
  // （全部真实请求被拦成 HTTP 400 空 body）。本文件是「prefs mock + 真
  // HTTP 网络链」组合（notifier 走 harness 真栈），故建 binding 后立即
  // 恢复默认 HttpOverrides——prefs mock 走 method channel，不受影响。
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  group('CategoryTreeStore', () {
    /// 构造注入 mock 持久化实例的存储。
    ///
    /// 参数：[initial] shared_preferences 初始键值。
    /// 返回：[Future<(CategoryTreeStore, SharedPreferences)>] 存储与实例。
    Future<(CategoryTreeStore, SharedPreferences)> storeWith(
      Map<String, Object> initial,
    ) async {
      SharedPreferences.setMockInitialValues(initial);
      final prefs = await SharedPreferences.getInstance();
      return (CategoryTreeStore(prefs: prefs), prefs);
    }

    test('read：无键 → null（首启，不创建键）', () async {
      final (store, _) = await storeWith(const {});

      expect(await store.read(), isNull);
    });

    test('write → read 往返一致（含可选标记的出现与缺失两形态）', () async {
      final (store, _) = await storeWith(const {});
      final tree = CategoryTreeDto.fromJson(serverCategoryTreePayload());

      await store.write(tree);
      final restored = await store.read();

      expect(restored, isNotNull);
      expect(restored!.version, kServerTreeVersion);
      final mid = restored.categories.single.children!.single;
      final leaf = mid.children!.first; // 10101：可选标记出现形态
      expect(leaf.id, 10101);
      expect(leaf.sensitive, isTrue);
      expect(leaf.banned, isFalse);
      expect(leaf.icon, isNull);
      final leaf2 = mid.children!.last; // 10102：可选标记缺失形态
      expect(leaf2.sensitive, isNull);
      expect(leaf2.banned, isNull);
    });

    test('read：JSON 截断（写盘中断）→ 删坏键并按无缓存降级', () async {
      final raw = jsonEncode(serverCategoryTreePayload());
      final (store, prefs) = await storeWith({
        CategoryTreeStore.storageKey: raw.substring(0, raw.length ~/ 2),
      });

      expect(await store.read(), isNull);
      // 坏键已删：不留坏键让每次启动白解析一次。
      expect(prefs.getString(CategoryTreeStore.storageKey), isNull);
    });

    test('read：结构违约（缺 version）→ 删坏键并按无缓存降级', () async {
      final (store, prefs) = await storeWith({
        CategoryTreeStore.storageKey: jsonEncode({
          'categories': const <Object?>[],
        }),
      });

      expect(await store.read(), isNull);
      expect(prefs.getString(CategoryTreeStore.storageKey), isNull);
    });
  });

  group('categoryNodesFromDtos 转换', () {
    test('叶子 10101/10102 映射 enterprise（内置常量树显式声明档）', () {
      final nodes = categoryNodesFromDtos(
        CategoryTreeDto.fromJson(serverCategoryTreePayload()).categories,
      );

      final leaves = nodes.single.children.single.children;
      expect(leaves.first.id, 10101);
      expect(leaves.first.requiredCert, RequiredCert.enterprise);
      expect(leaves.last.id, 10102);
      expect(leaves.last.requiredCert, RequiredCert.enterprise);
    });

    test('线上新增叶子（内置常量树查不到）→ none 回退，不阻断不报错', () {
      final nodes = categoryNodesFromDtos([
        CategoryNodeDto.fromJson({
          'id': 9,
          'name': '新兴行业',
          'level': 1,
          'children': [
            {'id': 99999, 'name': '元宇宙陪逛', 'level': 3},
          ],
        }),
      ]);

      // 与 topCategoryOf 返 null 同取向：版本落后是预期内状态，
      // 由服务端 precheck 40302 兜底拦截，客户端不本地拦。
      expect(nodes.single.children.single.requiredCert, RequiredCert.none);
    });

    test('非叶子恒 none；children 缺失落实为空列表（递归转换）', () {
      final nodes = categoryNodesFromDtos(
        CategoryTreeDto.fromJson(serverCategoryTreePayload()).categories,
      );

      expect(nodes.single.requiredCert, RequiredCert.none); // 顶层非叶子
      final mid = nodes.single.children.single;
      expect(mid.requiredCert, RequiredCert.none); // 中层非叶子
      expect(mid.children, hasLength(2)); // children 递归转换生效
      // 10102 契约无 children 键 → 空列表而非 null（domain 语义）。
      expect(mid.children.last.children, isEmpty);
    });
  });

  group('CategoryTreeNotifier', () {
    late NetworkChainHarness harness;
    late SharedPreferences prefs;
    late ProviderContainer container;
    var pinClearCount = 0;

    /// 装配容器：dio 切 harness 网络链、store 注入 mock prefs、
    /// Pin 缓存口子登记计数回调。
    ///
    /// 参数：[initialPrefs] shared_preferences 初始键值（缓存用例预置旧树）。
    /// 返回：[Future<void>] 装配完成（provider 未激活，待 read/listen 触发）。
    Future<void> startContainer({
      Map<String, Object> initialPrefs = const {},
    }) async {
      SharedPreferences.setMockInitialValues(initialPrefs);
      prefs = await SharedPreferences.getInstance();
      container = ProviderContainer(
        overrides: [
          dioProvider.overrideWithValue(harness.dio),
          categoryTreeStoreProvider.overrideWithValue(
            CategoryTreeStore(prefs: prefs),
          ),
          pinCacheInvalidatorsProvider.overrideWithValue([
            () => pinClearCount++,
          ]),
        ],
      );
      addTearDown(container.dispose);
    }

    /// 轮询等待分类树状态命中条件（真 HTTP 栈异步推进，上限约 500ms）。
    ///
    /// 参数：[hit] 命中谓词（可联立 pinClearCount 等副作用条件——
    ///   state 赋值先于落盘/清 Pin，须等副作用完成再断言）。
    /// 返回：[Future<AsyncValue>] 命中时刻的状态。
    Future<AsyncValue<List<CategoryNode>>> waitTreeState(
      bool Function(AsyncValue<List<CategoryNode>>) hit,
    ) async {
      for (var i = 0; i < 100; i++) {
        final state = container.read(categoryTreeProvider);
        if (hit(state)) return state;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      fail('分类树状态等待超时：${container.read(categoryTreeProvider)}');
    }

    /// 轮询等待 mock 服务端收到至少 [n] 个请求（重试链走完信号）。
    Future<void> waitRequestCount(int n) async {
      for (var i = 0; i < 100; i++) {
        if (harness.server.received.length >= n) return;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      fail('请求计数等待超时：${harness.server.received.length} < $n');
    }

    setUp(() async {
      pinClearCount = 0;
      // 全组注入即时退避缝：失败用例会走 networkFailure 自动重试
      // （退避真睡 1s/2s），禁真睡（harness 约定）。
      harness = NetworkChainHarness(retrySleeper: (_) async {});
      await harness.start();
    });

    tearDown(() async {
      await harness.dispose();
    });

    test('首启无缓存：loading → data(线上树)，落盘 + 清 Pin 口子调 1 次',
        () async {
      stubCategoryTree(harness);
      await startContainer();

      final state = await waitTreeState(
        (s) => s is AsyncData && pinClearCount == 1,
      );

      final tree = state.value!;
      expect(tree.single.id, 1); // 工作：线上树
      final leaf = tree.single.children.single.children.first;
      expect(leaf.id, 10101);
      expect(leaf.requiredCert, RequiredCert.enterprise);
      // 无缓存时协商不带 version（契约：缺省即强制全量）。
      expect(
        Uri.parse(harness.server.received.single.path).queryParameters,
        isNot(contains('version')),
      );
      // 落盘内容与线上树一致。
      final raw = prefs.getString(CategoryTreeStore.storageKey);
      expect(raw, isNotNull);
      expect(
        CategoryTreeDto.fromJson(jsonDecode(raw!) as Map<String, Object?>)
            .version,
        kServerTreeVersion,
      );
    });

    test('缓存版本与服务端一致：unchanged 保持缓存树，清 Pin 口子不调',
        () async {
      stubCategoryTree(harness);
      // 缓存内容用生活分支、版本号借服务端当前版本：验证「unchanged 时
      // state 保持缓存内容」，而非被线上树替换。
      final cachedPayload = cachedCategoryTreePayload()
        ..['version'] = kServerTreeVersion;
      await startContainer(
        initialPrefs: {CategoryTreeStore.storageKey: jsonEncode(cachedPayload)},
      );
      // read 触发 build 激活 provider（waitRequestCount 不读 provider，
      // 不激活则 _load 永不执行，死等一个不会发出的请求）。
      container.read(categoryTreeProvider);

      await waitRequestCount(1); // 协商请求确已发出（非本地短路）
      final state = container.read(categoryTreeProvider);

      expect(state, isA<AsyncData>());
      expect(state.value!.single.id, 4); // 生活：仍是缓存树
      expect(
        state.value!.single.children.single.children.single.id,
        40101,
      );
      expect(pinClearCount, 0);
      // 缓存未被覆盖。
      expect(
        jsonDecode(prefs.getString(CategoryTreeStore.storageKey)!)['version'],
        kServerTreeVersion,
      );
    });

    test('缓存落后：data(缓存) → data(线上树)，prefs 覆盖 + 清 Pin 1 次',
        () async {
      stubCategoryTree(harness);
      await startContainer(
        initialPrefs: {
          CategoryTreeStore.storageKey: jsonEncode(cachedCategoryTreePayload()),
        },
      );
      final states = <AsyncValue<List<CategoryNode>>>[];
      container.listen(
        categoryTreeProvider,
        (prev, next) => states.add(next),
        fireImmediately: true,
      );

      final state = await waitTreeState(
        (s) => s is AsyncData && pinClearCount == 1,
      );

      expect(state.value!.single.id, 1); // 工作：线上树
      // 状态序列：loading → data(缓存 40101) → data(线上 10101)。
      expect(states, hasLength(3));
      expect(states[0], isA<AsyncLoading>());
      expect(states[1].value!.single.children.single.children.single.id, 40101);
      // 线上树叶子层有两个节点（10101/10102），取 first 锁定 10101。
      expect(states[2].value!.single.children.single.children.first.id, 10101);
      // prefs 已被线上树覆盖。
      expect(
        CategoryTreeDto.fromJson(
          jsonDecode(prefs.getString(CategoryTreeStore.storageKey)!)
              as Map<String, Object?>,
        ).version,
        kServerTreeVersion,
      );
      // 协商请求携带的是本地缓存版本号。
      expect(
        Uri.parse(harness.server.received.single.path)
            .queryParameters['version'],
        kCachedTreeVersion,
      );
    });

    test('首启无缓存 + 请求失败：error 态（ApiException networkFailure）',
        () async {
      // 不 stub：mock 501 非信封纯文本 → dio 拒绝 5xx 走传输侧错误，
      // 链尾归一 networkFailure（autoRetry，退避缝即时，首发 + 重试 2 次）。
      await startContainer();

      final state = await waitTreeState((s) => s is AsyncError);

      final error = (state as AsyncError).error;
      expect(error, isA<ApiException>());
      expect((error as ApiException).code, ApiErrorCode.networkFailure);
      // 重试链走完：首发 + 重试 2 次（全链路总数 2，详设 §14）。
      expect(harness.server.received, hasLength(3));
      expect(pinClearCount, 0);
      expect(prefs.getString(CategoryTreeStore.storageKey), isNull);
    });

    test('有缓存 + 请求失败：静默保持缓存树（本端点永不报错口径）', () async {
      await startContainer(
        initialPrefs: {
          CategoryTreeStore.storageKey: jsonEncode(cachedCategoryTreePayload()),
        },
      );
      // read 触发 build 激活 provider（waitRequestCount 不读 provider）。
      container.read(categoryTreeProvider);

      await waitRequestCount(1); // 501 → networkFailure 经退避缝即时重试
      // 重试链 3 次（首发 + 2 次，详设 §14 全链路总数 2）走完仍失败，
      // 且失败落回 _load 的 catch（静默保持不写 state）。
      await waitRequestCount(3);
      final state = container.read(categoryTreeProvider);

      expect(state, isA<AsyncData>());
      expect(state.value!.single.id, 4); // 生活：缓存树静默保持
      expect(pinClearCount, 0);
    });
  });
}
