/// 探索页契约 DTO 解析测试（[126] 前端段）。
///
/// 锁定 `PinsCompactResponse` 的「schema + 二维数组」解析口径与
/// `/posts/search` 分页/`PostCard` 字段映射：列序以 schema 为准（不按位置硬编码）、
/// 整数/浮点两种 JSON 数值形态都接受、required 缺失一律抛 [ApiException]。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/core/network/api_exception.dart';
import 'package:zhaoyazhao/features/discovery/map_dto.dart';

void main() {
  group('PinsCompactDto.fromJson', () {
    test('pin 模式：按 schema 列序解析二维数组', () {
      final dto = PinsCompactDto.fromJson({
        'mode': 'pin',
        'total': 2,
        'schema': ['id', 'lng', 'lat', 'category_id', 'type', 'completeness_level'],
        'pins': [
          [1001, 120.15012, 30.28034, 10101, 0, 2],
          [1002, 120.14887, 30.27991, 10102, 1, 1],
        ],
      });

      expect(dto.isPinMode, isTrue);
      expect(dto.pins, hasLength(2));
      expect(dto.pins.first.id, 1001);
      expect(dto.pins.first.lng, closeTo(120.15012, 1e-9));
      expect(dto.pins.first.lat, closeTo(30.28034, 1e-9));
      expect(dto.pins.first.leafCategoryId, 10101);
      expect(dto.pins.first.typeCode, 0);
      expect(dto.pins.first.completenessLevel, 2);
      expect(dto.pins[1].typeCode, 1);
    });

    test('schema 缺省时用契约固定列序兜底（description 定死，非猜值）', () {
      final dto = PinsCompactDto.fromJson({
        'mode': 'pin',
        'total': 1,
        'pins': [
          [7, 117.32, 31.90, 20101, 1, 0],
        ],
      });

      expect(dto.pins.single.leafCategoryId, 20101);
      expect(dto.pins.single.typeCode, 1);
    });

    test('schema 顺序与固定列序不同时，按 schema 取值（防按位置硬编码）', () {
      final dto = PinsCompactDto.fromJson({
        'mode': 'pin',
        'total': 1,
        'schema': ['lng', 'lat', 'id', 'type', 'category_id', 'completeness_level'],
        'pins': [
          [120.5, 30.5, 42, 1, 50101, 2],
        ],
      });

      expect(dto.pins.single.id, 42);
      expect(dto.pins.single.lng, 120.5);
      expect(dto.pins.single.typeCode, 1);
      expect(dto.pins.single.leafCategoryId, 50101);
    });

    test('整数值坐标（JSON 反序列化后是 int）以 double 承接', () {
      final dto = PinsCompactDto.fromJson({
        'mode': 'pin',
        'total': 1,
        'pins': [
          [1, 120, 30, 10101, 0, 1],
        ],
      });

      expect(dto.pins.single.lng, 120.0);
      expect(dto.pins.single.lat, 30.0);
    });

    test('cluster 模式：pins 缺失为空表，clusters 解析（category_id 可空）', () {
      final dto = PinsCompactDto.fromJson({
        'mode': 'cluster',
        'total': 30,
        'clusters': [
          {'lng': 120.15, 'lat': 30.28, 'count': 18, 'category_id': 10101},
          {'lng': 120.16, 'lat': 30.29, 'count': 12},
        ],
      });

      expect(dto.isClusterMode, isTrue);
      expect(dto.pins, isEmpty);
      expect(dto.clusters, hasLength(2));
      expect(dto.clusters.first.count, 18);
      expect(dto.clusters.first.categoryId, 10101);
      expect(dto.clusters[1].categoryId, isNull);
    });

    test('schema 缺少必需列抛 ApiException（不静默按位置取值）', () {
      expect(
        () => PinsCompactDto.fromJson({
          'mode': 'pin',
          'total': 1,
          'schema': ['id', 'lng'],
          'pins': [
            [1, 120.0],
          ],
        }),
        throwsA(isA<ApiException>()),
      );
    });

    test('行列数少于 schema 抛 ApiException', () {
      expect(
        () => PinsCompactDto.fromJson({
          'mode': 'pin',
          'total': 1,
          'pins': [
            [1, 120.0, 30.0],
          ],
        }),
        throwsA(isA<ApiException>()),
      );
    });

    test('非整数档位码（如 1.5）抛 ApiException，不被 toInt 静默截断', () {
      expect(
        () => PinsCompactDto.fromJson({
          'mode': 'pin',
          'total': 1,
          'pins': [
            [1, 120.0, 30.0, 10101, 0, 1.5],
          ],
        }),
        throwsA(isA<ApiException>()),
      );
    });

    test('mode/total 缺失抛 ApiException（required 不掩盖）', () {
      expect(
        () => PinsCompactDto.fromJson({'mode': 'pin'}),
        throwsA(isA<ApiException>()),
      );
    });
  });

  group('SearchPostsPageDto.fromJson', () {
    test('解析分页四要素与卡片项', () {
      final dto = SearchPostsPageDto.fromJson({
        'items': [
          {
            'id': 9001,
            'type': 'resource',
            'title': '餐饮门店招服务员',
            'leaf_category_id': 10101,
            'l2_category_id': 101,
            'summary': '包吃住',
            'lng': 120.1512,
            'lat': 30.2755,
            'distance_m': 320,
            'completeness_level': 2,
            'publish_at': '2026-10-08T10:00:00+08:00',
          },
        ],
        'total': 30,
        'page': 1,
        'page_size': 20,
        'category_version_stale': false,
      });

      expect(dto.items, hasLength(1));
      expect(dto.total, 30);
      expect(dto.page, 1);
      expect(dto.pageSize, 20);
      expect(dto.categoryVersionStale, isFalse);
      final card = dto.items.single;
      expect(card.id, 9001);
      expect(card.type, 'resource');
      expect(card.title, '餐饮门店招服务员');
      expect(card.leafCategoryId, 10101);
      expect(card.distanceM, 320);
      expect(card.completenessLevel, 2);
      expect(card.publishAt, isNotNull);
    });

    test('可选项缺失全部为 null（cover_url/summary/distance_m/publish_at）', () {
      final dto = SearchPostsPageDto.fromJson({
        'items': [
          {
            'id': 1,
            'type': 'demand',
            'title': '求租单间',
            'completeness_level': 0,
          },
        ],
        'total': 1,
        'page': 1,
        'page_size': 20,
      });

      final card = dto.items.single;
      expect(card.summary, isNull);
      expect(card.coverUrl, isNull);
      expect(card.distanceM, isNull);
      expect(card.publishAt, isNull);
      expect(card.leafCategoryId, isNull);
    });

    test('卡片 required（title）缺失抛 ApiException', () {
      expect(
        () => SearchPostsPageDto.fromJson({
          'items': [
            {'id': 1, 'type': 'demand', 'completeness_level': 0},
          ],
          'total': 1,
          'page': 1,
          'page_size': 20,
        }),
        throwsA(isA<ApiException>()),
      );
    });

    test('分页 required（total）缺失抛 ApiException', () {
      expect(
        () => SearchPostsPageDto.fromJson({
          'items': [],
          'page': 1,
          'page_size': 20,
        }),
        throwsA(isA<ApiException>()),
      );
    });
  });
}
