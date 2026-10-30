/// POI 候选解析与降级守门测试（计划 R6 / R13 / KTD5）。
///
/// **这些断言防的是什么**：候选列表来自一个第三方接口，字段形态随版本漂移
/// （`address` 有时是字符串、有时是空数组；`location` 是 `"lng,lat"` 字符串）。
/// 解析器若对其中任何一种形态抛错，用户一打字整个选择页就会崩；而若把缺失
/// 坐标的条目也放进来，点选后回填的是一个没有坐标的「地点」——确认按钮看起来
/// 可用，实际提交不了。故这里把「跳过坏条目、失败即空」钉死。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/features/location/poi_search.dart';

/// 构造一条正常的候选条目（测试基线）。
///
/// 参数：[id] POI ID，默认 `B000A1`。
/// 返回：高德 `tips[]` 中的一项。
Map<String, Object?> tip({String id = 'B000A1'}) => <String, Object?>{
  'id': id,
  'name': '回龙观地铁站',
  'address': '北京市昌平区回龙观',
  'district': '昌平区',
  'location': '116.337,40.071',
};

void main() {
  group('parseInputTips 正常路径', () {
    test('解析出名称、地址描述与坐标', () {
      final tips = parseInputTips(<String, Object?>{
        'status': '1',
        'tips': <Object?>[tip()],
      });

      expect(tips, hasLength(1));
      expect(tips.first.id, 'B000A1');
      expect(tips.first.name, '回龙观地铁站');
      expect(tips.first.address, '北京市昌平区回龙观');
      expect(tips.first.lng, 116.337);
      expect(tips.first.lat, 40.071);
    });

    test('address 为空数组时退回 district 作为描述', () {
      final raw = tip()..['address'] = const <Object?>[];

      final tips = parseInputTips(<String, Object?>{
        'status': '1',
        'tips': <Object?>[raw],
      });

      expect(tips.first.address, '昌平区');
    });

    test('超过上限只保留前 N 条', () {
      final tips = parseInputTips(<String, Object?>{
        'status': '1',
        'tips': <Object?>[
          for (var i = 0; i < 30; i++) tip(id: 'B$i'),
        ],
      });

      expect(tips.length, lessThanOrEqualTo(10));
    });
  });

  group('parseInputTips 坏条目跳过', () {
    test('缺 location / id / name 的条目跳过，其余保留', () {
      final noLocation = tip(id: 'B1')..remove('location');
      final noId = tip()..['id'] = '';
      final noName = tip()..['name'] = '   ';
      final good = tip(id: 'B9');

      final tips = parseInputTips(<String, Object?>{
        'status': '1',
        'tips': <Object?>[noLocation, noId, noName, good],
      });

      expect(tips, hasLength(1));
      expect(tips.first.id, 'B9');
    });

    test('location 不是两个数值 → 该条跳过', () {
      final bad = tip()..['location'] = '东经116,北纬40';

      final tips = parseInputTips(<String, Object?>{
        'status': '1',
        'tips': <Object?>[bad, tip(id: 'B2')],
      });

      expect(tips.map((t) => t.id), <String>['B2']);
    });
  });

  group('parseInputTips 失败路径', () {
    test('status != 1 → 空列表', () {
      expect(
        parseInputTips(<String, Object?>{'status': '0', 'tips': <Object?>[tip()]}),
        isEmpty,
      );
    });

    test('非 Map / tips 不是数组 → 空列表', () {
      expect(parseInputTips('不是 JSON 对象'), isEmpty);
      expect(parseInputTips(null), isEmpty);
      expect(parseInputTips(<String, Object?>{'status': '1', 'tips': 'x'}), isEmpty);
    });
  });

  group('请求侧降级', () {
    test('未注入 Key → 不发请求，返回空列表', () async {
      // 测试环境不带 --dart-define，Key 必为空；传入一个「一用就抛」的
      // 客户端，若实现先发了请求，用例会因异常失败而不是静默通过。
      final client = _ThrowingHttpClient();

      final result = await searchPoiSuggestions(
        keywords: '回龙观',
        client: client,
      );

      expect(result, isEmpty);
      expect(client.used, isFalse);
    });

    test('关键词为空 → 不发请求', () async {
      final client = _ThrowingHttpClient();

      await searchPoiSuggestions(keywords: '   ', client: client);

      expect(client.used, isFalse);
    });
  });
}

/// 一被使用就抛异常的 HttpClient（验证「未配置 Key 时不发请求」）。
class _ThrowingHttpClient implements HttpClient {
  /// 是否被调用过（任一请求入口）。
  bool used = false;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    used = true;
    throw StateError('不应发起网络请求');
  }
}
