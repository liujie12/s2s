/// 详情页契约→域模型映射测试（[127]；§10.4 语义迁移）。
///
/// 单独为映射函数立测试而非只测 Provider：映射是「契约值 ≠ 本地值」的
/// 显式转换集中地，出错表现为「值静默错位」而非抛异常，只有直接断言
/// 域模型字段才能钉死（详细设计 §10.4 反复强调的「看着能跑」陷阱）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/core/network/api_exception.dart';
import 'package:zhaoyazhao/domain/listing_category.dart';
import 'package:zhaoyazhao/domain/listing_detail.dart';
import 'package:zhaoyazhao/features/detail/post_detail_provider.dart';
import 'package:zhaoyazhao/features/post/post_dto.dart';

import '../../support/post_fixtures.dart';

void main() {
  group('postDetailToListingDetail（§10.4 语义迁移）', () {
    test('type/leaf_category_id/completeness/realname/price 逐项转换', () {
      final detail = postDetailToListingDetail(
        PostDetailDto.fromJson(postDetailPayload()),
      );

      expect(detail.listing.id, 1001);
      expect(detail.listing.title, '九成新实木餐桌转让');
      // type "resource" → supply（§10.4.2 显式映射，非 values.byName）
      expect(detail.listing.supplyDemand, SupplyDemand.supply);
      // leaf_category_id 40101 → life（topCategoryOf 查表，非取前两位）
      expect(detail.listing.category, ListingCategory.life);
      expect(detail.listing.price, 299.0);
      expect(detail.listing.priceUnit, '元');
      // completeness_level 2 → green（显式 switch，非 values[index]）
      expect(detail.completeness, CompletenessLevel.green);
      // realname_status passed → 实名 true（四态坍缩布尔）
      expect(detail.publisher.realNameVerified, isTrue);
      expect(detail.publisher.nickname, '王师傅');
      expect(detail.leafCategoryId, 40101);
      expect(detail.expireAt, DateTime.utc(2026, 9, 8, 4));
      expect(detail.description, '九成新，无破损，可小刀');
    });

    test('realname_status 非 passed → realNameVerified false', () {
      final payload = postDetailPayload();
      (payload['author'] as Map<String, Object?>)['realname_status'] =
          'pending';
      final detail = postDetailToListingDetail(
        PostDetailDto.fromJson(payload),
      );

      expect(detail.publisher.realNameVerified, isFalse);
    });

    test('attributes → templateFields 有序键值对', () {
      final detail = postDetailToListingDetail(
        PostDetailDto.fromJson(postDetailPayload()),
      );

      expect(detail.templateFields, const [
        (label: '成色', value: '9 成新'),
        (label: '交易方式', value: '自提'),
      ]);
    });

    test('英文模板 key 映射为中文 label；模板外 key 原样保留', () {
      // 2026-10-18 真机：详情页「详细信息」直出 `condition`。契约 attributes 的
      // 键是模板 key，须按叶子类目模板映射成中文 label（401 → 二手闲置模板）。
      final payload = postDetailPayload();
      payload['attributes'] = <String, Object?>{
        'condition': '全新未拆',
        'unknown_key': 'x',
      };
      final detail = postDetailToListingDetail(PostDetailDto.fromJson(payload));

      expect(detail.templateFields, const [
        (label: '新旧程度', value: '全新未拆'),
        (label: 'unknown_key', value: 'x'),
      ]);
    });

    test('U5 起终点对象 → 「起点 → 终点」+ 距离行，不出现花括号', () {
      final payload = postDetailPayload();
      payload['attributes'] = <String, Object?>{
        'route': <String, Object?>{
          'origin': <String, Object?>{'name': '回龙观', 'lng': 116.337, 'lat': 40.071},
          'destination': <String, Object?>{
            'name': '中关村',
            'lng': 116.316,
            'lat': 39.983,
          },
          'distance_m': 18500,
          'duration_s': 2100,
        },
      };
      final detail = postDetailToListingDetail(PostDetailDto.fromJson(payload));

      expect(detail.templateFields.single.value, '回龙观 → 中关村\n约 19 km · 约 35 分钟');
      expect(detail.templateFields.single.value, isNot(contains('{')));
    });

    test('U5 历史文本 route 原样展示（不解析成对象）', () {
      final payload = postDetailPayload();
      payload['attributes'] = <String, Object?>{'route': '回龙观 → 中关村'};
      final detail = postDetailToListingDetail(PostDetailDto.fromJson(payload));

      expect(detail.templateFields.single.value, '回龙观 → 中关村');
    });

    test('media[] → mediaUrls（只取 url 且保序）', () {
      final detail = postDetailToListingDetail(
        PostDetailDto.fromJson(postDetailPayload()),
      );

      expect(detail.mediaUrls, [
        'https://oss.example.com/m-1.jpg',
        'https://oss.example.com/m-2.jpg',
      ]);
    });

    test('media 缺失 → 空列表（契约非 required，不退化为 null）', () {
      final payload = postDetailPayload()..remove('media');
      final detail = postDetailToListingDetail(PostDetailDto.fromJson(payload));

      expect(detail.mediaUrls, isEmpty);
    });

    test('media 非数组抛 parseError（不静默当空）', () {
      final payload = postDetailPayload()..['media'] = 'oops';

      expect(() => PostDetailDto.fromJson(payload), throwsA(isA<ApiException>()));
    });

    test('contact_mask → contactMasked（[147] DEC-13 未拉取态切真）', () {
      final detail = postDetailToListingDetail(
        PostDetailDto.fromJson(postDetailPayload()),
      );

      expect(detail.contactMasked, '138****8000');
      expect(detail.hasContact, isTrue);
    });

    test('contact_mask 缺失 → contactMasked 为 null（存量行无掩码）', () {
      final payload = postDetailPayload()..remove('contact_mask');
      final detail = postDetailToListingDetail(PostDetailDto.fromJson(payload));

      expect(detail.contactMasked, isNull);
    });
  });

  group('CompletenessLevel.fromApi（0/1/2 显式映射）', () {
    test('0→red 1→yellow 2→green', () {
      expect(CompletenessLevel.fromApi(0), CompletenessLevel.red);
      expect(CompletenessLevel.fromApi(1), CompletenessLevel.yellow);
      expect(CompletenessLevel.fromApi(2), CompletenessLevel.green);
    });

    test('非法值抛 parseError（契约外值不静默吞）', () {
      expect(() => CompletenessLevel.fromApi(3), throwsA(isA<ApiException>()));
    });
  });
}
