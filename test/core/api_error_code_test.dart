/// 错误码枚举与行为映射的机器对齐测试（详细设计 §12.1 / §12.2）。
///
/// 这些断言防的是「码表漂移」：
///
/// 1. `ApiErrorCode` 是客户端唯一的错误码实现处（编码规范 §1.2），服务端 24 码
///    + `ok` + 2 个本地负数码共 27 值。若与 `TestFixtures.allBusinessCodes`
///    （契约 openapi.yaml 错误码表的硬编码镜像）不一致，说明契约与客户端
///    枚举有一侧改了而另一侧没跟上 —— 必须双向相等，只测子集会放过
///    「客户端多造一个码」这类私自占号（编码规范 §0.2 不新增错误码）。
/// 2. `code ~/ 100 == httpStatus` 是服务端 §2.3 的对齐纪律，客户端枚举逐个
///    抄码时最容易把 40903 抄进 403 段之类的错位，逐条断言才能拦住。
/// 3. 行为映射查表驱动（计划 R4）：每个码经 `.behavior` 有且仅有一个行为，
///    `40903`/`42906`/`40101` 三个特殊语义码钉死唯一性，防「再为某码写
///    特例分支」——特例分支一多，§12.2 的表驱动就名存实亡。
///
/// 运行：flutter test test/core/api_error_code_test.dart
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/core/network/api_error_code.dart';
import 'package:zhaoyazhao/core/network/api_exception.dart';

import '../support/test_support.dart';

void main() {
  group('码全集：与契约 fixtures 双向相等（§12.1 / R3）', () {
    test('服务端码 + ok 集合与 allBusinessCodes 双向相等', () {
      // 本地负数码不占服务端码段（§12.1），比对前先剔除。
      final serverSideCodes = ApiErrorCode.values
          .where((c) => c.code >= 0)
          .map((c) => c.code)
          .toSet();
      expect(serverSideCodes, TestFixtures.allBusinessCodes);
      // 双向相等的显式两半：只写 Set == 已覆盖，拆开是为失败时更容易读。
      expect(
        serverSideCodes.difference(TestFixtures.allBusinessCodes),
        isEmpty,
        reason: '客户端枚举存在契约外私占码',
      );
      expect(
        TestFixtures.allBusinessCodes.difference(serverSideCodes),
        isEmpty,
        reason: '契约码在客户端枚举中缺失',
      );
    });

    test('枚举总数 27 = 24 服务端码 + ok + 2 本地负数码，且无重复码', () {
      expect(ApiErrorCode.values.length, 27);
      final allCodes = ApiErrorCode.values.map((c) => c.code).toList();
      // 长度比较能抓住「同一个码抄两遍」——Set 去重后数量必然缩水。
      expect(allCodes.toSet().length, allCodes.length);
    });

    test('本地负数码恰为 networkFailure(-1) 与 parseError(-2)', () {
      expect(ApiErrorCode.networkFailure.code, -1);
      expect(ApiErrorCode.parseError.code, -2);
      final localCodes =
          ApiErrorCode.values.where((c) => c.code < 0).map((c) => c.code);
      expect(localCodes, unorderedEquals([-1, -2]));
    });

    test('code ~/ 100 == httpStatus 逐条成立（服务端 §2.3 对齐纪律）', () {
      for (final entry in TestFixtures.codeToHttpStatus.entries) {
        final code = ApiErrorCode.fromCode(entry.key);
        expect(
          code.code ~/ 100,
          entry.value,
          reason: '${code.name}(${code.code}) 未对齐 HTTP ${entry.value}',
        );
      }
    });
  });

  group('Retry-After 8 码：集合与 fixtures 一致（§12.2 / 契约 §3）', () {
    // §12.2 定案行为：42906 为 silentRequeue（埋点静默回队），其余 7 码为
    // promptWithRetryAfter（按 Retry-After 提示、用户显式重试）。
    const expectedRetryAfterBehaviors = <int, ErrBehavior>{
      40105: ErrBehavior.promptWithRetryAfter,
      42901: ErrBehavior.promptWithRetryAfter,
      42902: ErrBehavior.promptWithRetryAfter,
      42903: ErrBehavior.promptWithRetryAfter,
      42904: ErrBehavior.promptWithRetryAfter,
      42905: ErrBehavior.promptWithRetryAfter,
      42906: ErrBehavior.silentRequeue,
      42907: ErrBehavior.promptWithRetryAfter,
    };

    test('Retry-After 码集合与 TestFixtures.retryAfterCodes 逐值相等', () {
      expect(
        expectedRetryAfterBehaviors.keys.toSet(),
        TestFixtures.retryAfterCodes,
      );
      expect(TestFixtures.retryAfterCodes.length, 8);
    });

    test('8 码逐条行为为 promptWithRetryAfter 或其 §12.2 定案行为', () {
      for (final entry in expectedRetryAfterBehaviors.entries) {
        expect(
          ApiErrorCode.fromCode(entry.key).behavior,
          entry.value,
          reason: '${entry.key} 的行为映射与 §12.2 定案不符',
        );
      }
    });
  });

  group('六值行为映射：查表驱动、无特例分支（§12.2 / R4）', () {
    /// 按 behavior 反查全部持有码，供多组断言复用。
    ///
    /// [behavior] 要反查的行为
    /// 返回：持有该行为的全部服务端/本地码集合
    Set<int> codesWithBehavior(ErrBehavior behavior) => ApiErrorCode.values
        .where((c) => c.behavior == behavior)
        .map((c) => c.code)
        .toSet();

    test('每个码查表有且仅有一个行为（行为全集覆盖，无遗漏无多重）', () {
      for (final code in ApiErrorCode.values) {
        // 行为是枚举构造期字段，天然唯一；此处断言它落在 ErrBehavior 全集内，
        // 防的是将来新增 ErrBehavior 值后枚举行漏改编译不过之外的路径。
        expect(ErrBehavior.values, contains(code.behavior));
      }
      // 六个动作行为各自至少有一个持有码 —— 行为表不允许出现「死行为」。
      const actionBehaviors = [
        ErrBehavior.autoRetry,
        ErrBehavior.promptWithRetryAfter,
        ErrBehavior.silentRequeue,
        ErrBehavior.forceRefetch,
        ErrBehavior.deterministicFail,
        ErrBehavior.refreshToken,
      ];
      for (final behavior in actionBehaviors) {
        expect(
          codesWithBehavior(behavior),
          isNotEmpty,
          reason: '$behavior 无任何持有码，行为表出现死行为',
        );
      }
    });

    test('autoRetry 恰好覆盖 5xx 四码与 networkFailure', () {
      expect(
        codesWithBehavior(ErrBehavior.autoRetry),
        unorderedEquals([50001, 50301, 50302, 50303, -1]),
      );
    });

    test('promptWithRetryAfter 恰好覆盖 40105 与 42901–42905、42907', () {
      expect(
        codesWithBehavior(ErrBehavior.promptWithRetryAfter),
        unorderedEquals([40105, 42901, 42902, 42903, 42904, 42905, 42907]),
      );
    });

    test('40903 为 forceRefetch 唯一码（禁自动带新 version 重发）', () {
      expect(ApiErrorCode.fromCode(40903).behavior, ErrBehavior.forceRefetch);
      expect(codesWithBehavior(ErrBehavior.forceRefetch), unorderedEquals([40903]));
    });

    test('42906 为 silentRequeue 唯一码（唯一不向用户呈现的码）', () {
      expect(ApiErrorCode.fromCode(42906).behavior, ErrBehavior.silentRequeue);
      expect(codesWithBehavior(ErrBehavior.silentRequeue), unorderedEquals([42906]));
    });

    test('40101 为 refreshToken 唯一码（走 §13 单飞续期）', () {
      expect(ApiErrorCode.fromCode(40101).behavior, ErrBehavior.refreshToken);
      expect(codesWithBehavior(ErrBehavior.refreshToken), unorderedEquals([40101]));
    });

    test('deterministicFail 覆盖其余全部确定性失败码与 parseError', () {
      expect(
        codesWithBehavior(ErrBehavior.deterministicFail),
        unorderedEquals([
          40001, 40002,
          40301, 40302, 40303, 40304, 40305,
          40901, 40902,
          41001,
          -2,
        ]),
      );
    });

    test('ok 的行为为 none，不进任何错误处理分支', () {
      expect(ApiErrorCode.ok.behavior, ErrBehavior.none);
      expect(codesWithBehavior(ErrBehavior.none), unorderedEquals([0]));
    });
  });

  group('fromCode 查表与未知码 default 降级（§10.3）', () {
    test('全部已知码 round-trip 可查回自身', () {
      for (final code in ApiErrorCode.values) {
        expect(ApiErrorCode.fromCode(code.code), code);
      }
    });

    test('未知服务端码抛 ApiException(parseError)，message 含实际收到的码值', () {
      // §10.3：解析失败不返 null、不静默吞；default 分支给出可定位信息。
      // 若这里兜底成某个既有码，服务端新增码会被按错误行为处理而无任何痕迹。
      expect(
        () => ApiErrorCode.fromCode(49999),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', ApiErrorCode.parseError)
              .having((e) => e.message, 'message', contains('49999')),
        ),
      );
    });

    test('未知本地负数码同样抛 parseError，不静默兜底', () {
      expect(
        () => ApiErrorCode.fromCode(-3),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            ApiErrorCode.parseError,
          ),
        ),
      );
    });
  });
}
