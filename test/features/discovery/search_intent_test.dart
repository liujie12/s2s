/// 语义搜索槽位卡单测（U5）：契约反序列化、逐项删除、放宽半径、状态迁移。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/features/discovery/search_intent.dart';

void main() {
  group('SearchIntent.fromJson', () {
    test('按契约 snake_case 完整解析', () {
      final intent = SearchIntent.fromJson(<String, Object?>{
        'query_text': '1公里内 2000以内 合租',
        'transcript': '1公里内 2000以内 合租',
        'post_type': 'demand',
        'leaf_category_ids': <Object?>[20101, 20102],
        'category_labels': <Object?>['主卧出租', '次卧出租'],
        'radius': '1',
        'radius_meters': 1000,
        'anchor_lat': 30.28,
        'anchor_lng': 120.15,
        'anchor_name': '锦绣小区',
        'anchor_source': 'poi',
        'price_min': null,
        'price_max': 2000.0,
        'price_excludes_negotiable': true,
        'unresolved_fields': <Object?>['location'],
        'sources': <String, Object?>{'category': 'vocab'},
        'ai_used': false,
      });

      expect(intent.leafCategoryIds, <int>[20101, 20102]);
      expect(intent.categoryLabels, <String>['主卧出租', '次卧出租']);
      expect(intent.radius, '1');
      expect(intent.radiusMeters, 1000);
      expect(intent.priceLabel, '≤2000元');
      expect(intent.priceExcludesNegotiable, isTrue);
      expect(intent.unresolvedFields, <String>['location']);
      expect(intent.aiUsed, isFalse);
      expect(intent.hasNoSlot, isFalse);
    });

    test('空槽位卡 hasNoSlot 为真', () {
      final intent = SearchIntent.fromJson(<String, Object?>{
        'query_text': '嗯',
        'leaf_category_ids': <Object?>[],
        'category_labels': <Object?>[],
        'price_excludes_negotiable': false,
        'unresolved_fields': <Object?>[],
        'sources': <String, Object?>{},
        'ai_used': false,
      });
      expect(intent.hasNoSlot, isTrue);
    });

    test('小区候选解析，点选后写入 communityId 与锚点', () {
      final intent = SearchIntent.fromJson(<String, Object?>{
        'query_text': '鑫徽苑 2000以内',
        'leaf_category_ids': <Object?>[],
        'category_labels': <Object?>[],
        'community_id': null,
        'community_name': null,
        'community_candidates': <Object?>[
          <String, Object?>{
            'id': 'B0FFG001',
            'name': '新徽苑',
            'district': '长丰县',
            'lng': 117.2,
            'lat': 32.1,
          },
        ],
        'price_max': 2000.0,
        'price_excludes_negotiable': true,
        'unresolved_fields': <Object?>['location'],
        'sources': <String, Object?>{},
        'ai_used': false,
      });

      expect(intent.communityId, isNull);
      expect(intent.communityCandidates, hasLength(1));

      final selected = intent.selectCommunity(intent.communityCandidates.first);
      expect(selected.communityId, 'B0FFG001');
      expect(selected.communityLabel, '新徽苑');
      expect(selected.anchorLat, 32.1);
      expect(selected.anchorLng, 117.2);
      expect(selected.communityCandidates, isEmpty);
      expect(selected.priceMax, 2000.0);

      final cleared = selected.withoutCommunity();
      expect(cleared.communityId, isNull);
    });
  });

  group('逐项删除与放宽', () {
    final intent = SearchIntent.fromJson(<String, Object?>{
      'query_text': '1公里内 2000以内 合租',
      'post_type': 'demand',
      'leaf_category_ids': <Object?>[20101, 20102],
      'category_labels': <Object?>['主卧出租', '次卧出租'],
      'radius': '1',
      'radius_meters': 1000,
      'price_max': 2000.0,
      'price_excludes_negotiable': true,
      'unresolved_fields': <Object?>[],
      'sources': <String, Object?>{},
      'ai_used': false,
    });

    test('删除单个类目只移除对应项', () {
      final next = intent.withoutCategoryAt(0);
      expect(next.leafCategoryIds, <int>[20102]);
      expect(next.categoryLabels, <String>['次卧出租']);
      // 其他槽位保持不变
      expect(next.postType, 'demand');
      expect(next.radiusMeters, 1000);
      expect(next.priceMax, 2000.0);
    });

    test('删除价格/半径/供需互不影响', () {
      final noPrice = intent.withoutPrice();
      expect(noPrice.priceMax, isNull);
      expect(noPrice.priceExcludesNegotiable, isFalse);
      expect(noPrice.radiusMeters, 1000);

      final noRadius = intent.withoutRadius();
      expect(noRadius.radius, isNull);
      expect(noRadius.radiusMeters, isNull);
      expect(noRadius.priceMax, 2000.0);

      final noPostType = intent.withoutPostType();
      expect(noPostType.postType, isNull);
      expect(noPostType.leafCategoryIds, <int>[20101, 20102]);
    });

    test('放宽半径按档递进，全城后不再变化', () {
      expect(intent.widenRadius().radius, '3');
      expect(intent.widenRadius().radiusMeters, 3000);

      final city = intent
          .widenRadius()
          .widenRadius()
          .widenRadius()
          .widenRadius();
      expect(city.radius, 'city');
      expect(city.radiusMeters, isNull);
      expect(city.widenRadius().radius, 'city');
    });
  });

  group('SearchIntentNotifier', () {
    test('update 记录上一档，undo 回退，clear 清空', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(searchIntentProvider.notifier);

      const first = SearchIntent(queryText: '租房', radius: '1', radiusMeters: 1000);
      const second = SearchIntent(queryText: '租房', radius: '3', radiusMeters: 3000);

      notifier.update(first);
      expect(container.read(searchIntentProvider).intent, first);

      notifier.update(second);
      expect(container.read(searchIntentProvider).intent, second);
      expect(container.read(searchIntentProvider).previous, first);

      notifier.undo();
      expect(container.read(searchIntentProvider).intent, first);

      notifier.clear();
      expect(container.read(searchIntentProvider).intent, isNull);
      expect(container.read(searchIntentProvider).canUndo, isFalse);
    });
  });
}
