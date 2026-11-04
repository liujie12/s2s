/// 真模式只读契约：出包前对正式环境的关键只读端点做一次契约校验。
///
/// 与 `api_contract_example_test.dart` 的分工：
///   - 那个文件是「契约怎么写」的示范，大量场景依赖 mock 桩值；
///   - 本文件只打**真实只读端点**，不做任何写操作，可直接指向正式环境。
///
/// 运行方式：
///   `flutter test test/contract/readonly_contract_test.dart --dart-define=S2S_API_BASE_URL=https://s2s.build110.com`
///
/// 未注入 `S2S_API_BASE_URL` 时整组跳过（CI 默认无外网依赖），不伪装通过。
library;

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_support.dart';

/// 编译期注入的真实基址；为空表示未启用真模式。
const String _injectedBaseUrl = String.fromEnvironment('S2S_API_BASE_URL');

/// 分类树版本号格式：`YYYY-MM-DD.N`（契约 components/schemas/CategoryVersion）。
final RegExp _categoryVersionPattern = RegExp(r'^\d{4}-\d{2}-\d{2}\.\d+$');

void main() {
  final bool enabled = _injectedBaseUrl.isNotEmpty;

  late Dio dio;
  Map<String, Object?>? treeData;
  String categoryVersion = '';
  int leafCategoryId = 0;

  /// 构造请求客户端。
  ///
  /// 功能：统一 baseUrl、关闭状态码异常（契约错误用响应体表达）、带两个必要头。
  /// 参数：无。
  /// 返回：无（写入外层 [dio]）。
  void initDio() {
    dio = Dio(
      BaseOptions(
        baseUrl: _injectedBaseUrl,
        validateStatus: (_) => true,
        headers: {
          'X-Interaction-Id': TestFixtures.interactionId,
          'X-Device-Id': TestFixtures.deviceId,
        },
      ),
    );
  }

  /// 发起 GET 并解析为 JSON Map。
  ///
  /// 功能：读取响应体并按 JSON 解码，非 JSON 时给出可读失败而不是解码异常。
  /// 参数：[path] 以 `/` 开头的契约路径；[query] 可选查询参数。
  /// 返回：解析后的响应体 Map。
  Future<Map<String, Object?>> getJson(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    final Response<String> resp = await dio.get<String>(
      path,
      queryParameters: query,
    );
    final Object? decoded;
    try {
      decoded = jsonDecode(resp.data ?? '');
    } on FormatException {
      fail('$path 返回非 JSON（HTTP ${resp.statusCode}）：${resp.data}');
    }
    expect(
      decoded,
      isA<Map>(),
      reason: '$path 响应体必须是 JSON 对象（HTTP ${resp.statusCode}）：${resp.data}',
    );
    return Map<String, Object?>.from(decoded! as Map);
  }

  /// 从分类树节点中取出第一个叶子类目 ID。
  ///
  /// 功能：递归向下查找没有 children 的节点，作为 `/map/pins` 与 `/posts/search` 的合法类目。
  /// 参数：[nodes] 分类节点数组。
  /// 返回：叶子类目 ID；找不到返回 0。
  int firstLeafId(List<dynamic> nodes) {
    for (final dynamic node in nodes) {
      if (node is! Map) continue;
      final Object? children = node['children'];
      if (children is List && children.isNotEmpty) {
        final int nested = firstLeafId(children);
        if (nested != 0) return nested;
      }
      final Object? id = node['id'];
      if (id is int) return id;
    }
    return 0;
  }

  /// 断言响应为成功信封并返回 data。
  ///
  /// 功能：统一校验 code=0 与四字段包形态，避免每个用例各写一套。
  /// 参数：[body] 响应体；[path] 仅用于失败提示。
  /// 返回：`data` 字段（可能为 null）。
  Object? expectSuccess(Map<String, Object?> body, String path) {
    expect(body, isSuccessEnvelope, reason: '$path 未返回成功信封：$body');
    return body['data'];
  }

  group(
    '真模式只读契约',
    () {
      setUpAll(() {
        initDio();
      });

      test('GET /categories/tree 返回分类树与合法版本号', () async {
        final Map<String, Object?> body = await getJson('/categories/tree');
        final Object? data = expectSuccess(body, '/categories/tree');
        expect(data, isA<Map>(), reason: '未传 version 时必须回全量分类树');

        treeData = Map<String, Object?>.from(data! as Map);
        final Object? rawVersion = treeData!['version'];
        expect(rawVersion, isA<String>(), reason: '分类树必须带 version');
        final String version = rawVersion! as String;
        expect(
          _categoryVersionPattern.hasMatch(version),
          isTrue,
          reason: '版本号格式应为 YYYY-MM-DD.N，实际 $version',
        );
        categoryVersion = version;

        final Object? rawCategories = treeData!['categories'];
        expect(rawCategories, isA<List>(), reason: '分类树必须带 categories 数组');
        final List<dynamic> categories = rawCategories! as List<dynamic>;
        expect(categories.isNotEmpty, isTrue, reason: '分类树不得为空');
        leafCategoryId = firstLeafId(categories);
        expect(leafCategoryId, isNot(0), reason: '分类树中未找到叶子类目');
      });

      test('GET /cities 返回城市数组', () async {
        final Map<String, Object?> body = await getJson('/cities');
        final Object? data = expectSuccess(body, '/cities');
        expect(data, isA<Map>(), reason: '/cities 的 data 必须是对象');
        final Object? cities = (data! as Map)['cities'];
        expect(cities, isA<List>(), reason: '/cities 必须带 cities 数组');
      });

      test('GET /map/pins 返回与 mode 匹配的图钉结构', () async {
        expect(leafCategoryId, isNot(0), reason: '前置分类树用例未就绪');
        final Map<String, Object?> body = await getJson(
          '/map/pins',
          query: <String, dynamic>{
            'category_ids': '$leafCategoryId',
            'post_type': 'resource',
            'radius': '5',
            'grid_id': '26700_6728',
            'category_version': categoryVersion,
            'lng': '120.15',
            'lat': '30.28',
            'zoom': '14.5',
          },
        );
        final Object? data = expectSuccess(body, '/map/pins');
        expect(data, isA<Map>(), reason: '/map/pins 的 data 必须是对象');

        final Map<String, Object?> payload = Map<String, Object?>.from(data! as Map);
        final Object? mode = payload['mode'];
        expect(mode, anyOf('pin', 'cluster'), reason: 'mode 只能是 pin 或 cluster');
        expect(payload['total'], isA<int>(), reason: '必须带整数 total');

        if (mode == 'pin') {
          expect(payload['pins'], isA<List>(), reason: 'mode=pin 时 pins 必须是数组');
          for (final dynamic pin in payload['pins']! as List) {
            expect(pin, isA<List>(), reason: 'pins 元素必须是二维数组');
            expect((pin as List).length, 6, reason: 'pins 固定 6 列');
          }
        } else {
          expect(payload['clusters'], isA<List>(), reason: 'mode=cluster 时 clusters 必须是数组');
        }
      });

      test('GET /posts/search 返回分页结构且无敏感字段', () async {
        expect(leafCategoryId, isNot(0), reason: '前置分类树用例未就绪');
        final Map<String, Object?> body = await getJson(
          '/posts/search',
          query: <String, dynamic>{
            'category_ids': '$leafCategoryId',
            'post_type': 'resource',
            'radius': '5',
            'grid_id': '26700_6728',
            'category_version': categoryVersion,
            'lng': '120.15',
            'lat': '30.28',
            'page': '1',
            'page_size': '20',
          },
        );
        final Object? data = expectSuccess(body, '/posts/search');
        expect(data, isA<Map>(), reason: '/posts/search 的 data 必须是对象');

        final Map<String, Object?> payload = Map<String, Object?>.from(data! as Map);
        expect(payload['items'], isA<List>(), reason: '必须带 items 数组');
        expect(payload['total'], isA<int>(), reason: '必须带整数 total');
        expect(payload['page'], isA<int>(), reason: '必须带整数 page');
        expect(payload['page_size'], isA<int>(), reason: '必须带整数 page_size');

        // 列表卡片不得出现完整敏感字段（编码规范 §7.2-④）。
        final String raw = jsonEncode(body);
        expect(raw.contains('real_name'), isFalse, reason: '列表响应不得出现 real_name');
        expect(raw.contains('id_card'), isFalse, reason: '列表响应不得出现 id_card');
      });

      test('GET /posts/{post_id} 返回详情（无数据则跳过）', () async {
        expect(leafCategoryId, isNot(0), reason: '前置分类树用例未就绪');
        final Map<String, Object?> listBody = await getJson(
          '/posts/search',
          query: <String, dynamic>{
            'category_ids': '$leafCategoryId',
            'post_type': 'resource',
            'radius': '5',
            'grid_id': '26700_6728',
            'category_version': categoryVersion,
            'lng': '120.15',
            'lat': '30.28',
            'page': '1',
            'page_size': '20',
          },
        );
        final Object? listData = expectSuccess(listBody, '/posts/search');
        final List<dynamic> items =
            ((listData! as Map)['items'] as List<dynamic>?) ?? <dynamic>[];
        if (items.isEmpty) {
          markTestSkipped('正式环境该分类暂无在架帖子，详情契约无可取样对象');
          return;
        }

        final Object? first = items.first;
        final Object? id = first is Map ? first['id'] : null;
        expect(id, isA<int>(), reason: '列表项必须带整数 id');

        final Map<String, Object?> body = await getJson('/posts/$id');
        final Object? data = expectSuccess(body, '/posts/$id');
        expect(data, isA<Map>(), reason: '详情 data 必须是对象');
        expect((data! as Map)['id'], id, reason: '详情 id 与请求不一致');
      });

      test('GET /map/pins 缺参数回 40001（负向契约）', () async {
        final Response<String> resp = await dio.get<String>('/map/pins');
        expect(resp.statusCode, 400, reason: '缺参数必须回 HTTP 400');
        final Map<String, Object?> body =
            Map<String, Object?>.from(jsonDecode(resp.data!) as Map);
        expect(body, isFailureEnvelope(40001), reason: '缺参数必须回 40001：$body');
        expect(body, hasCodeAlignedWithHttp(400), reason: '业务码前三位须与 HTTP 对齐');
      });

      test('GET /users/me 未登录回 40101（认证链契约）', () async {
        final Response<String> resp = await dio.get<String>('/users/me');
        expect(resp.statusCode, 401, reason: '未登录必须回 HTTP 401');
        final Map<String, Object?> body =
            Map<String, Object?>.from(jsonDecode(resp.data!) as Map);
        expect(body, isFailureEnvelope(40101), reason: '未登录必须回 40101：$body');
      });
    },
    skip: enabled
        ? false
        : '未注入 S2S_API_BASE_URL；本组只用于真模式（出包前）校验',
  );
}
