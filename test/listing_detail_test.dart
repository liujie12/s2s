/// 详情页域模型的单元测试（PRD §7.4.1 / §7.4.3 / §5.11）。
///
/// 测的是三处「算出来的值」：价格文案拼接、剩余有效期、需求态前缀。
/// 它们的共同点是错了不会崩溃 —— 页面照常渲染，只是显示的内容不对，
/// 而「50.0 元」「还剩 -1 天」这类错误在样例数据里未必碰得上。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/domain/listing.dart';
import 'package:zhaoyazhao/domain/listing_category.dart';
import 'package:zhaoyazhao/domain/listing_detail.dart';

final DateTime _now = DateTime(2026, 8, 28, 12);

Listing _listing({
  double? price,
  String? unit,
  ListingCategory category = ListingCategory.service,
  SupplyDemand sd = SupplyDemand.supply,
}) {
  return Listing(
    id: 'l1',
    title: '专业家庭日常保洁',
    category: category,
    supplyDemand: sd,
    latitude: 30.0,
    longitude: 120.0,
    createdAt: _now,
    price: price,
    priceUnit: unit,
  );
}

ListingDetail _detail({Listing? listing, DateTime? expireAt}) {
  return ListingDetail(
    listing: listing ?? _listing(),
    description: '描述',
    publisher: const Publisher(
      id: 'u1',
      nickname: '王师傅',
      realNameVerified: true,
    ),
    completeness: CompletenessLevel.green,
    expireAt: expireAt ?? _now.add(const Duration(days: 7)),
    contactChannel: ContactChannel.phone,
    contactMasked: '138****8888',
    leafCategoryId: 50101, // 服务 > 家政/保洁 > 日常保洁
  );
}

void main() {
  group('价格文案', () {
    test('整数价格不带小数尾巴 —— 「50 元/小时」而不是「50.0 元/小时」', () {
      final l = _listing(price: 50, unit: '小时');
      expect(l.priceLabel, '50 元/小时');
    });

    test('无单位时只显示金额 —— 单位属模板字段，未配置时不能拼出「50 元/null」', () {
      final l = _listing(price: 50);
      expect(l.priceLabel, '50 元');
    });

    test('无价格返回 null，由展示层决定显示「面议」还是留空', () {
      expect(_listing().priceLabel, isNull);
    });

    test('非整数价格保留两位 —— 对齐 §13.2 decimal(12,2)', () {
      final l = _listing(price: 12.5, unit: '件');
      expect(l.priceLabel, '12.50 元/件');
    });
  });

  group('剩余有效期（§5.11 默认 7 天）', () {
    test('整天数正常计算', () {
      final d = _detail(expireAt: _now.add(const Duration(days: 3)));
      expect(d.daysUntilExpire(_now), 3);
    });

    test('不足一天向上取整 —— 剩 25 小时显示 2 天，宁可让人以为还早也不要以为没了', () {
      final d = _detail(expireAt: _now.add(const Duration(hours: 25)));
      expect(d.daysUntilExpire(_now), 2);
    });

    test('已过期返回 0 而非负数 —— 负数会渲染成「-1 天后下架」', () {
      final d = _detail(expireAt: _now.subtract(const Duration(days: 1)));
      expect(d.daysUntilExpire(_now), 0);
    });
  });

  group('需求态前缀（§7.4.3 由分类自动推导）', () {
    test('资源态无前缀', () {
      final d = _detail(listing: _listing());
      expect(d.demandPrefix, isNull);
      expect(d.displayTitle, '专业家庭日常保洁');
    });

    test('房屋需求 = 求租', () {
      final d = _detail(
        listing: _listing(
          category: ListingCategory.house,
          sd: SupplyDemand.demand,
        ),
      );
      expect(d.displayTitle, '【求租】专业家庭日常保洁');
    });

    test('车辆需求 = 求搭', () {
      final d = _detail(
        listing: _listing(
          category: ListingCategory.vehicle,
          sd: SupplyDemand.demand,
        ),
      );
      expect(d.demandPrefix, '【求搭】');
    });

    test('生活需求 = 求购', () {
      final d = _detail(
        listing: _listing(
          category: ListingCategory.life,
          sd: SupplyDemand.demand,
        ),
      );
      expect(d.demandPrefix, '【求购】');
    });

    test('每个分类在需求态下都有前缀 —— 漏一个会让标题少掉语义', () {
      for (final c in ListingCategory.values) {
        final d = _detail(
          listing: _listing(category: c, sd: SupplyDemand.demand),
        );
        expect(d.demandPrefix, isNotNull, reason: '分类 ${c.label} 缺前缀');
      }
    });
  });
}
