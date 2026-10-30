/// 起终点地点对守门测试（计划 R3 / R7 / R11，KTD1）。
///
/// **这些断言防的是什么**：`attributes.route` 在库里同时存在历史字符串形态与
/// 新的对象形态。读取端如果把「半截对象」当成已填，发布页会放行一条没有终点
/// 的拼车帖；如果解析时对缺失字段抛错，一条旧帖就能把详情页打崩。故这里把
/// 「对象 → 值对象」的容错口径钉死：缺失即空，绝不抛错。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/domain/route_pair.dart';

void main() {
  /// 构造一份两端齐备的合法对象形态（测试基线）。
  ///
  /// 返回：含起点「回龙观」与终点「中关村」的对象 map。
  Map<String, Object?> completeJson() => <String, Object?>{
    'origin': <String, Object?>{
      'name': '回龙观',
      'address': '北京市昌平区回龙观',
      'lng': 116.337,
      'lat': 40.071,
    },
    'destination': <String, Object?>{
      'name': '中关村',
      'address': '北京市海淀区中关村大街',
      'lng': 116.316,
      'lat': 39.983,
    },
    'distance_m': 18500,
    'duration_s': 2100,
  };

  group('RoutePair.fromJson', () {
    test('两端齐备 → 名称、地址、坐标与距离时长均解析，isComplete 为真', () {
      final pair = RoutePair.fromJson(completeJson());

      expect(pair, isNotNull);
      expect(pair!.origin.name, '回龙观');
      expect(pair.origin.address, '北京市昌平区回龙观');
      expect(pair.origin.lng, 116.337);
      expect(pair.destination.name, '中关村');
      expect(pair.distanceM, 18500);
      expect(pair.durationS, 2100);
      expect(pair.isComplete, isTrue);
    });

    test('只给起点 → isComplete 为假', () {
      final pair = RoutePair(
        origin: RoutePlace(name: '回龙观', lng: 116.337, lat: 40.071),
        destination: const RoutePlace(name: ''),
      );

      expect(pair.isComplete, isFalse);
    });

    test('对象缺 destination 键 → 返回 null（不是半条路线）', () {
      final json = completeJson()..remove('destination');

      expect(RoutePair.fromJson(json), isNull);
    });

    test('终点对象在但缺坐标 → 该端 isLocated 为假，解析不抛异常', () {
      final json = completeJson();
      (json['destination'] as Map<String, Object?>).remove('lat');

      final pair = RoutePair.fromJson(json);

      expect(pair, isNotNull);
      expect(pair!.destination.isLocated, isFalse);
      expect(pair.origin.isLocated, isTrue);
      expect(pair.isComplete, isFalse);
    });

    test('坐标是非数值 → 该端 isLocated 为假，解析不抛异常', () {
      final json = completeJson();
      (json['origin'] as Map<String, Object?>)['lng'] = '东经116';

      final pair = RoutePair.fromJson(json);

      expect(pair, isNotNull);
      expect(pair!.origin.lng, isNull);
      expect(pair.origin.isLocated, isFalse);
      expect(pair.isComplete, isFalse);
    });

    test('非对象入参 → null', () {
      expect(RoutePair.fromJson(null), isNull);
      expect(RoutePair.fromJson('回龙观 → 中关村'), isNull);
      expect(RoutePair.fromJson(<Object?>[]), isNull);
    });
  });

  group('RoutePair.parseAttribute（KTD1 双形态兼容）', () {
    test('历史字符串形态 → null（交给调用方按文本渲染）', () {
      expect(RoutePair.parseAttribute('回龙观 → 中关村'), isNull);
      expect(RoutePair.parseAttribute(''), isNull);
    });

    test('对象形态 → 正常解析', () {
      final pair = RoutePair.parseAttribute(completeJson());
      expect(pair?.destination.name, '中关村');
    });

    test('缺失 / null → null', () {
      expect(RoutePair.parseAttribute(null), isNull);
    });
  });

  group('序列化', () {
    test('toJson 往返保持名称、地址与坐标', () {
      final pair = RoutePair.fromJson(completeJson())!;
      final restored = RoutePair.fromJson(pair.toJson())!;

      expect(restored.origin, pair.origin);
      expect(restored.destination, pair.destination);
      expect(restored.distanceM, pair.distanceM);
      expect(restored.durationS, pair.durationS);
    });

    test('没有距离时不写 distance_m / duration_s', () {
      final pair = RoutePair(
        origin: RoutePlace(name: '回龙观', lng: 116.337, lat: 40.071),
        destination: RoutePlace(name: '中关村', lng: 116.316, lat: 39.983),
      );

      final json = pair.toJson();

      expect(json.containsKey('distance_m'), isFalse);
      expect(json.containsKey('duration_s'), isFalse);
    });

    test('未定位的一端不写 lng / lat（不写 null 占位）', () {
      const place = RoutePlace(name: '我的位置');
      expect(place.toJson().containsKey('lng'), isFalse);
      expect(place.toJson().containsKey('lat'), isFalse);
    });
  });

  group('值语义与派生', () {
    test('swapped 交换两端且不带距离（距离须按反方向重算）', () {
      final pair = RoutePair.fromJson(completeJson())!;
      final swapped = pair.swapped();

      expect(swapped.origin.name, '中关村');
      expect(swapped.destination.name, '回龙观');
      expect(swapped.distanceM, isNull);
      expect(swapped.durationS, isNull);
    });

    test('相同内容相等（值对象语义，供 widget 比较与 provider 缓存判断）', () {
      final a = RoutePair.fromJson(completeJson())!;
      final b = RoutePair.fromJson(completeJson())!;

      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });
}
