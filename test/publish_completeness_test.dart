/// 完整度三档与 AI 配额守门测试（PRD §9.8 三档表 / §5.10 配额二维分层）。
///
/// **这些断言防的是什么**：§9.8 末条要求「本表是 🟢🟡🔴 的唯一判定处」。
/// 判定一旦被复制到第二个地方，表现是「确认页说能升 🟢，发完却显示 🟡」——
/// 用户看到的是两个页面互相打脸，而两边的代码各自都「没错」。
/// 故这里把三档映射、权重、差项清单、配额六种组合全部钉在一处断言上。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/domain/listing_detail.dart';
import 'package:zhaoyazhao/domain/publish_completeness.dart';
import 'package:zhaoyazhao/features/publish/publish_form_state.dart';

void main() {
  /// 构造一份指定三条件达成情况的判定。
  ///
  /// 参数 [required] 必填是否齐、[door] 门牌号是否有、[leaf] 三级类目是否精准。
  /// 返回对应的 [CompletenessAssessment]。
  CompletenessAssessment of({
    bool required = false,
    bool door = false,
    bool leaf = false,
  }) {
    return CompletenessAssessment(
      requiredFieldsComplete: required,
      hasDoorNumber: door,
      leafCategoryPrecise: leaf,
    );
  }

  group('契约常量（原则 134：必须有一处字面量钉死并被直接比对）', () {
    test('三档推荐池权重 2 / 1 / 0.5（§9.8「推荐池权重」列）', () {
      expect(kWeightGreen, 2.0);
      expect(kWeightYellow, 1.0);
      expect(kWeightRed, 0.5);
    });

    test('档名逐字取自 §9.8（改档名会连带改掉所有页面文案，必须有断言拦一次）', () {
      expect(CompletenessLevel.green.label, '完整');
      expect(CompletenessLevel.yellow.label, '半完整');
      expect(CompletenessLevel.red.label, '待补');
    });
  });

  group('§9.8 三档映射：3 个 → 🟢，2 个 → 🟡，≤1 个 → 🔴', () {
    test('三条件全达成 → 完整', () {
      final a = of(required: true, door: true, leaf: true);
      expect(a.metCount, 3);
      expect(a.level, CompletenessLevel.green);
      expect(a.isTop, isTrue);
    });

    test('恰好两个 → 半完整（三种组合都是同一档，条件之间无主次）', () {
      // §9.8 的口径是「满足几个」而非「满足哪几个」。若哪天有人把它写成
      // if 链并给某个条件加权，这三条里会有一条掉出黄档。
      expect(of(required: true, door: true).level, CompletenessLevel.yellow);
      expect(of(required: true, leaf: true).level, CompletenessLevel.yellow);
      expect(of(door: true, leaf: true).level, CompletenessLevel.yellow);
    });

    test('只满足一个 → 待补', () {
      expect(of(required: true).level, CompletenessLevel.red);
      expect(of(door: true).level, CompletenessLevel.red);
      expect(of(leaf: true).level, CompletenessLevel.red);
    });

    test('一个都不满足 → 待补（不是崩、也不是默认最高档）', () {
      final a = of();
      expect(a.metCount, 0);
      expect(a.level, CompletenessLevel.red);
      expect(a.isTop, isFalse);
    });
  });

  group('权重随档位走', () {
    test('三档权重各自对上（这是「升档能换到什么」的唯一依据）', () {
      expect(of(required: true, door: true, leaf: true).weight, kWeightGreen);
      expect(of(required: true, door: true).weight, kWeightYellow);
      expect(of(required: true).weight, kWeightRed);
    });
  });

  group('missing：列全部差项而非只报第一条', () {
    test('三项全缺 → 三条，且顺序 = 条件声明顺序', () {
      // 顺序即「§5.11 30 秒补上」的补齐顺序。乱序会让用户在页面上
      // 先看到最难补的那项，从而放弃。
      expect(of().missing, [
        CompletenessCondition.requiredFields,
        CompletenessCondition.doorNumber,
        CompletenessCondition.leafCategory,
      ]);
    });

    test('与发布页 blocker 只报一条刚好相反 —— 缺两项就返回两条', () {
      expect(of(required: true).missing, [
        CompletenessCondition.doorNumber,
        CompletenessCondition.leafCategory,
      ]);
    });

    test('已达最高档 → 差项为空（否则完成页会显示一个空的「还差这些」标题）', () {
      expect(of(required: true, door: true, leaf: true).missing, isEmpty);
    });

    test('每个条件的两套文案都非空 —— 达成态说事实，未达成态说待办', () {
      for (final c in CompletenessCondition.values) {
        expect(c.label.trim(), isNotEmpty);
        expect(c.gapLabel.trim(), isNotEmpty);
      }
    });
  });

  group('§8 T6-④ 权益三条', () {
    test('恰好三条 —— PRD 写的是「对应具体权益三条」', () {
      expect(of().benefits.length, 3);
    });

    test('第一条把目标权重与当前权重同时说出来', () {
      // 只说「升级能得 ×2」不说现在是多少，用户无法判断值不值得花 30 秒。
      expect(of().benefits.first, '推荐池权重 ×2 优先展示（当前 ×0.5）');
      expect(
        of(required: true, door: true).benefits.first,
        '推荐池权重 ×2 优先展示（当前 ×1）',
      );
    });

    test('权重文案：2.0 显示为 2，0.5 保留小数（「×2.0」读起来像精度而非倍数）', () {
      expect(of().benefits.first, contains('×0.5'));
      expect(of().benefits.first, isNot(contains('×2.0')));
    });
  });

  group('§5.10 AI 配额二维分层', () {
    test('实名 + 三档：20 / 10 / 3', () {
      expect(
        dailyAiQuota(verified: true, level: CompletenessLevel.green),
        20,
      );
      expect(
        dailyAiQuota(verified: true, level: CompletenessLevel.yellow),
        10,
      );
      expect(dailyAiQuota(verified: true, level: CompletenessLevel.red), 3);
    });

    test('未实名一律 3 次 —— 哪怕内容是 🟢 档（§5.10 原文「未实名或 🔴」）', () {
      // 这条是最容易被「优化」掉的：看着像可以按档给额度，
      // 但未实名与 🔴 是合并档，实名才是解锁前提。
      for (final level in CompletenessLevel.values) {
        expect(dailyAiQuota(verified: false, level: level), 3);
      }
    });

    test('高敏类目额外 +10，且叠加在各档基数之上', () {
      expect(
        dailyAiQuota(
          verified: true,
          level: CompletenessLevel.green,
          sensitiveCategory: true,
        ),
        30,
      );
      expect(
        dailyAiQuota(
          verified: false,
          level: CompletenessLevel.red,
          sensitiveCategory: true,
        ),
        13,
      );
    });
  });

  group('PublishFormState.completeness：表单 → 三个布尔的翻译', () {
    /// 构造一份必填齐全的表单（可提交）。
    PublishFormState complete() => const PublishFormState(
      leafCategoryId: 40101,
      hasLocation: true,
      title: '九成新实木餐桌转让',
      priceText: '350',
      priceUnit: '元',
      description: '搬家出售，无磕碰。',
      templateValues: {'condition': '几乎全新'},
      contact: '13800138000',
      agreed: true,
    );

    test('必填项判定复用 canSubmit —— 不另建一套必填计数', () {
      // 另写一套会出现「按钮能点但完整度说必填没齐」这种自相矛盾。
      final form = complete();
      expect(form.canSubmit, isTrue);
      expect(form.completeness.requiredFieldsComplete, isTrue);
      expect(
        form.copyWith(agreed: false).completeness.requiredFieldsComplete,
        isFalse,
      );
    });

    test('门牌号空白字符不算达成（trim 后判定）', () {
      expect(complete().completeness.hasDoorNumber, isFalse);
      expect(
        complete().copyWith(doorNumber: '   ').completeness.hasDoorNumber,
        isFalse,
      );
      expect(
        complete()
            .copyWith(doorNumber: '3 号楼 2 单元 501')
            .completeness
            .hasDoorNumber,
        isTrue,
      );
    });

    test('选了分类即为三级精准命中（§9.8 兜底列「判定按该类目实际最深层级」）', () {
      expect(complete().completeness.leafCategoryPrecise, isTrue);
      expect(const PublishFormState().completeness.leafCategoryPrecise, isFalse);
    });

    test('脏叶子 ID 不算命中 —— 查不到的类目不能白送一个条件', () {
      expect(
        complete().copyWith(leafCategoryId: 999999).completeness
            .leafCategoryPrecise,
        isFalse,
      );
    });

    test('补上门牌号即从半完整跳到完整（§5.9「再花 5 秒」的兑现）', () {
      final before = complete();
      expect(before.completeness.level, CompletenessLevel.yellow);
      final after = before.copyWith(doorNumber: '3 号楼 501');
      expect(after.completeness.level, CompletenessLevel.green);
    });

    test('空表单落 🔴 档', () {
      expect(const PublishFormState().completeness.level, CompletenessLevel.red);
    });

    test('换分类保留门牌号 —— 门牌跟着位置走，与分类无关', () {
      final form = complete().copyWith(doorNumber: '3 号楼 501');
      expect(form.withCategory(50101).doorNumber, '3 号楼 501');
    });
  });
}
