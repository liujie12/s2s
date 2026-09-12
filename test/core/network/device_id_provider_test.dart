/// DeviceIdProvider 测试（详设 §11.2 / 编码规范 §5.1，计划 Assumptions / R7）。
///
/// 设备 ID 纪律：
///   - 首次启动自生成 UUID v4 存 shared_preferences，此后固定（§11.2）；
///   - **惰性生成**：构造 Provider 不读盘、不写盘，首次被读取才生成
///     （Assumptions：隐私门不靠时序假设兜底，是否外发由 R7 同意态硬门控制）；
///   - 不采集 IMEI/MAC/IDFA/OAID（§5.1）；
///   - 不可信、可被重置：用户清数据/卸载后即换新值，函数级注释须标注。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhaoyazhao/core/network/device_id_provider.dart';

import '../../support/test_support.dart';

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  /// 重置内存态 shared_preferences（每个用例独立存储面）。
  void seedPrefs([Map<String, Object> initial = const {}]) {
    SharedPreferences.setMockInitialValues(initial);
  }

  test('首次读取生成 UUID v4 并落盘', () async {
    seedPrefs();
    final provider = DeviceIdProvider();

    final id = await provider.getOrCreate();

    expect(TestFixtures.uuidV4Pattern.hasMatch(id), isTrue,
        reason: '自生成设备标识必须是 UUID v4 形态（§11.2）');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(DeviceIdProvider.storageKey), id,
        reason: '生成后立即落盘，下次启动可恢复（§11.2：此后固定）');
  });

  test('重复读取返回同一值（不重新生成）', () async {
    seedPrefs();
    final provider = DeviceIdProvider();

    final first = await provider.getOrCreate();
    final second = await provider.getOrCreate();

    expect(second, first, reason: '同一进程内第二次读取直接复用，不再生成');
  });

  test('已存在落盘值时直接复用（跨启动固定）', () async {
    seedPrefs({DeviceIdProvider.storageKey: TestFixtures.deviceId});
    final provider = DeviceIdProvider();

    expect(await provider.getOrCreate(), TestFixtures.deviceId);
  });

  test('惰性：构造时不读取/写入 shared_preferences', () async {
    seedPrefs();
    // 仅构造：不触发 getInstance（mock 环境下 getInstance 在首次调用后才有缓存，
    // 这里通过「构造后存储面仍为空」侧面验证没有提前生成/写盘）。
    DeviceIdProvider();
    await Future<void>.delayed(Duration.zero);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(DeviceIdProvider.storageKey), isFalse,
        reason: '构造不生成设备 ID；隐私同意前即使被构造也不落盘（Assumptions）');
  });
}
