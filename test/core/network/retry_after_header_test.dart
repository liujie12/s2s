/// Retry-After 头解析纯函数单元测试（详设 §11.3/§14.1，评审 #7/#8）。
///
/// 该函数是信封分流与重试等待共用的唯一解析处（编码规范 §1.2），
/// 覆盖 §11.3「整数秒、失败回退 null、解析永不抛」与评审 testing gaps
/// 列出的边界值矩阵（0/-1/2.5/带空白/空串/HTTP-date/999999999）。
/// 上界钳制不在本函数（由 RetryInterceptor 在 sleep 点负责），
/// 故此处断言巨值/负值**原样返回**。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/core/network/retry_after_header.dart';

void main() {
  group('parseRetryAfterHeader 整数秒口径（§11.3，评审 #7/#8）', () {
    /// 参数化断言：[raw] 输入与 [expected] 期望（null = 回退）。
    ///
    /// 参数：[raw] 头原始值；[expected] 期望解析结果；[reason] 断言理由。
    void expectParse(String? raw, int? expected, String reason) {
      expect(parseRetryAfterHeader(raw), expected, reason: reason);
    }

    test('头缺失（null）回退 null（调用方退默认退避表）', () {
      expectParse(null, null, '无头不是错误，退 §14.1 退避表');
    });

    test('正常整数（含 0）原样解析；0 = 服务端要求立即重试', () {
      expectParse('60', 60, '正常整数秒');
      expectParse('0', 0, '0 是合法的立即重试指令，不得回退 null');
    });

    test('首尾带空白 trim 后解析（" 5 " -> 5）', () {
      expectParse(' 5 ', 5, 'dio 头值可能带空白，trim 后仍须可解析');
    });

    test('非整数形态全部回退 null，解析永不抛', () {
      expectParse('abc', null, '非数字');
      expectParse('', null, '空串 int.tryParse 失败 -> null');
      expectParse('   ', null, '纯空白 -> null');
      expectParse('2.5', null, '浮点不是契约约定的整数秒形态 -> null');
      expectParse('Wed, 21 Oct 2026 07:28:00 GMT', null,
          'HTTP-date 形态：服务端约定整数秒，不做日期换算 -> null');
      expectParse('60s', null, '带单位后缀不接受 -> null');
    });

    test('巨值与负值原样返回：解析函数不钳制（钳制是重试 sleep 的职责）',
        () {
      expectParse('999999999', 999999999,
          '429 段 UI 倒计时需要服务端原始值；上界只夹自动重试 sleep');
      expectParse('-1', -1,
          '负值原样返回；是否夹 0 由 RetryInterceptor 等待点决定');
    });
  });
}
