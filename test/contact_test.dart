/// 联系中转页的数据层测试（PRD §7.4.2 / §7.7 / §7.8 / §12.3）。
///
/// 这里测三件「错了不会崩、但会直接伤到用户」的事：
/// 1. `hasContact` 判空 —— 判错的表现是按钮可点却拨出一个空号；
/// 2. 完整值与脱敏值前后一致 —— 不一致会让用户以为平台给错了号码；
/// 3. 失败原因彼此不混用 —— 限频与熔断文案混用会让被冻结的用户
///    以为等到明天就好，而实际上需要走申诉（§12.3 42902 / 42903）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/domain/listing.dart';
import 'package:zhaoyazhao/domain/listing_category.dart';
import 'package:zhaoyazhao/domain/listing_detail.dart';
import 'package:zhaoyazhao/features/contact/contact_repository.dart';

final DateTime _now = DateTime(2026, 8, 28, 12);

ListingDetail _detail({
  ContactChannel channel = ContactChannel.phone,
  String? masked = '138****8000',
}) {
  return ListingDetail(
    listing: Listing(
      id: 'l1',
      title: '专业家庭日常保洁',
      category: ListingCategory.service,
      supplyDemand: SupplyDemand.supply,
      latitude: 30.0,
      longitude: 120.0,
      createdAt: _now,
    ),
    description: '描述',
    publisher: const Publisher(
      id: 'u1',
      nickname: '王师傅',
      realNameVerified: true,
    ),
    completeness: CompletenessLevel.green,
    expireAt: _now.add(const Duration(days: 7)),
    contactChannel: channel,
    contactMasked: masked,
    leafCategoryId: 50101, // 服务 > 家政/保洁 > 日常保洁
  );
}

void main() {
  group('hasContact（§7.8 对方联系方式未填边界）', () {
    test('填了联系方式为真', () {
      expect(_detail().hasContact, isTrue);
    });

    test('未填为假 —— 判错的表现是按钮可点但拨出空号', () {
      expect(_detail(masked: null).hasContact, isFalse);
    });
  });

  group('完整值派生（样例数据必须与脱敏展示前后一致）', () {
    test('手机号补回被遮的中间 4 位', () {
      expect(sampleFullValue(_detail()), '13866668000');
    });

    test('微信号补回被遮的中段', () {
      final d = _detail(channel: ContactChannel.wechat, masked: 'wx_h***12');
      expect(sampleFullValue(d), 'wx_happy12');
    });

    test('完整值保留脱敏值的首尾 —— 首尾变了用户会以为给错了号码', () {
      final full = sampleFullValue(_detail());
      expect(full.startsWith('138'), isTrue);
      expect(full.endsWith('8000'), isTrue);
    });
  });

  group('拉取完整联系方式', () {
    test('未填联系方式时抛 noContact，而不是返回空串', () async {
      expect(
        () => const ContactRepository().fetchFullContact(
          postId: 'l1',
          detail: _detail(masked: null),
        ),
        throwsA(
          isA<ContactException>().having(
            (e) => e.failure,
            'failure',
            ContactFailure.noContact,
          ),
        ),
      );
    });

    test('手机号渠道 callable 为真，微信为假 —— 决定按钮是拨号还是复制', () async {
      final repo = const ContactRepository();
      final phone = await repo.fetchFullContact(
        postId: 'l1',
        detail: _detail(),
      );
      expect(phone.callable, isTrue);

      final wechat = await repo.fetchFullContact(
        postId: 'l1',
        detail: _detail(channel: ContactChannel.wechat, masked: 'wx_h***12'),
      );
      expect(wechat.callable, isFalse);
    });
  });

  group('失败原因文案（§12.3）', () {
    test('每种原因都有非空文案 —— 缺一条页面就会显示空白横幅', () {
      for (final f in ContactFailure.values) {
        expect(f.message, isNotEmpty, reason: '${f.name} 缺文案');
      }
    });

    test('限频与熔断文案不同 —— 混用会让被冻结的用户误以为等到明天就好', () {
      expect(
        ContactFailure.rateLimited.message,
        isNot(ContactFailure.circuitBroken.message),
      );
    });

    test('文案彼此不重复 —— 重复等于用户分不清自己遇到了哪种情况', () {
      final messages = ContactFailure.values.map((f) => f.message).toSet();
      expect(messages.length, ContactFailure.values.length);
    });
  });
}
