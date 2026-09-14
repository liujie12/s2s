/// 统一异常形态测试（详细设计 §11.3 / §10.3，计划 R5 / KTD1 / KTD9）。
///
/// 这些断言防的是「异常两份口径」：
///
/// 1. `ApiException` 是迁移后的唯一异常形态（`lib/core/network/`），
///    `{code, message, requestId?, retryAfterSec?}` 四字段与 §11.3 构造
///    形状逐字对齐；旧失败分类枚举退役，`parseError` 语义由
///    `ApiErrorCode.parseError(-2)` 吸收（KTD1）。
/// 2. `ApiException.parse` 是 parseError 的规范工厂构造、永久保留
///    （评审 #12 订正：非「待退役兼容构造」）；现有 12 处生产调用点
///    （core/network 9、domain 2、features 1）统一经它抛出，签名一变
///    这里立刻编译失败，比「跑一遍应用看看」可靠。
/// 3. `parseError` 的 message 有定长上限（R5）：解析失败最常见于服务端
///    返了非契约 body，若 message 吞进原始 body 全文，日志与报错弹窗会
///    被大体积 body 灌爆（编码规范 §4.11 日志纪律的客户端落地）。
///
/// 运行：flutter test test/core/api_exception_test.dart
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/core/network/api_error_code.dart';
import 'package:zhaoyazhao/core/network/api_exception.dart';

void main() {
  group('主构造：四字段形态与 §11.3 对齐（R5）', () {
    test('code/message/requestId/retryAfterSec 逐字段存取', () {
      const exception = ApiException(
        code: ApiErrorCode.contactLimit,
        message: '查看联系方式过于频繁',
        requestId: 'req_01JABC',
        retryAfterSec: 58,
      );
      expect(exception.code, ApiErrorCode.contactLimit);
      expect(exception.message, '查看联系方式过于频繁');
      expect(exception.requestId, 'req_01JABC');
      expect(exception.retryAfterSec, 58);
    });

    test('requestId 与 retryAfterSec 缺省为 null（§11.3：缓存命中可无 request_id）', () {
      const exception = ApiException(
        code: ApiErrorCode.internalError,
        message: '服务端内部错误',
      );
      expect(exception.requestId, isNull);
      expect(exception.retryAfterSec, isNull);
    });
  });

  group('ApiException.parse 规范工厂（评审 #12）', () {
    test('产生 code=parseError，requestId/retryAfterSec 为 null', () {
      final exception = ApiException.parse('未知 post_type: supply');
      expect(exception.code, ApiErrorCode.parseError);
      expect(exception.requestId, isNull);
      expect(exception.retryAfterSec, isNull);
    });

    test('12 处生产调用点共用的单参数 String 表达式形态保持稳定', () {
      // 代表性复刻 domain ×2 与 features ×1 的调用表达式（另 9 处在
      // core/network，同形态）。签名若变（如改成命名参数或加必填参），
      // 本组立即编译失败 —— 这是「全部解析失败点单一入口」的可执行断言。
      final fromPostType = ApiException.parse('未知 post_type: supply');
      final fromCompactCode = ApiException.parse('未知 type 码: 2');
      final fromRadius = ApiException.parse('未知 radius: 20');
      for (final exception in [fromPostType, fromCompactCode, fromRadius]) {
        expect(exception.code, ApiErrorCode.parseError);
      }
    });
  });

  group('解析失败 message：含实际值且有定长上限（§10.3 / R5）', () {
    test('message 原样保留实际收到的值', () {
      // 只写「解析失败」的报错等于没写 —— 排查时最需要知道非法值长什么样。
      final exception = ApiException.parse('未知 post_type: supply');
      expect(exception.message, '未知 post_type: supply');
      expect(exception.message, contains('supply'));
    });

    test('超长 message 被截断到定长上限，不含原始全文', () {
      // 模拟非契约 body 全文被拼进 message 的场景：截断是最后防线。
      final oversizedBody = 'x' * (ApiException.maxParseMessageLength * 25);
      final exception = ApiException.parse('非信封 body: $oversizedBody');
      expect(
        exception.message.length,
        lessThanOrEqualTo(ApiException.maxParseMessageLength),
      );
      expect(exception.message, isNot(contains(oversizedBody)));
      expect(exception.message, isNot(endsWith('xxxx')));
    });

    test('长度恰为上限的 message 原样保留不截断', () {
      final exact = 'y' * ApiException.maxParseMessageLength;
      final exception = ApiException.parse(exact);
      expect(exception.message, exact);
    });

    test('截断结果带截断标记，避免被误读为完整信息', () {
      final oversized = 'z' * (ApiException.maxParseMessageLength + 1);
      final exception = ApiException.parse(oversized);
      expect(exception.message.length, ApiException.maxParseMessageLength);
      expect(exception.message, endsWith('…'));
    });
  });

  group('诊断输出', () {
    test('toString 含码名与 message，定位时不依赖外部上下文', () {
      final exception = ApiException.parse('未知 post_type: supply');
      expect(exception.toString(), contains('parseError'));
      expect(exception.toString(), contains('未知 post_type: supply'));
    });
  });
}
