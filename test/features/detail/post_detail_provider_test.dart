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
  });

  group('completenessFromApi（0/1/2 显式映射）', () {
    test('0→red 1→yellow 2→green', () {
      expect(completenessFromApi(0), CompletenessLevel.red);
      expect(completenessFromApi(1), CompletenessLevel.yellow);
      expect(completenessFromApi(2), CompletenessLevel.green);
    });

    test('非法值抛 parseError（契约外值不静默吞）', () {
      expect(() => completenessFromApi(3), throwsA(isA<ApiException>()));
    });
  });
}
