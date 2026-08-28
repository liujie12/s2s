/// 联系方式拉取数据源（PRD §7.4.2 联系中转页 / §7.7 反爬 / §12.3 `/contact`）。
///
/// **本文件模拟的是一个服务端接口，不是本地数据加工**。§14.3 规定「全系统仅
/// `/contact` 一个接口返回完整联系方式」，§7.7 要求「完整号码不写入前端初始
/// 状态，通过点击时走 API 拉取」。因此完整值必须表现为「一次会失败、会被限频、
/// 会有耗时的远程调用」，而不是一个可以随时从详情模型里读到的字段。
///
/// **接后端时只需替换 [ContactRepository.fetchFullContact] 的实现**，页面侧的
/// 加载态、错误态、限频提示都不用改 —— 这也是为什么这里要把失败建模成
/// 具名异常而不是返回 null：null 只能表达「没拿到」，无法区分「今日超限」
/// 与「被熔断冻结」，而这两者给用户的文案完全不同（§7.8）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/listing_detail.dart';

/// 拉取完整联系方式失败的原因（对齐 §12.3 错误码）。
enum ContactFailure {
  /// 未登录（§7.7：仅登录用户可拉取完整号码）。
  ///
  /// 使代理池换 IP 无法绕过账号维度上限 —— 这是三维限频里唯一不可伪造的一维。
  notLoggedIn('请先登录后再查看联系方式'),

  /// 三维限频任一超限，对应 §12.3 错误码 `42902`。
  rateLimited('今日联系数已达上限，明天再来'),

  /// 熔断：单账号 1 分钟内 ≥10 次拉取，对应 §12.3 错误码 `42903`。
  ///
  /// 与 [rateLimited] 分开：前者是正常使用到量，后者是异常访问被冻结，
  /// 且后者会「进运营风控待审列表」。文案混用会让被误判的正常用户
  /// 以为只要等到明天就好，而实际上需要走申诉。
  circuitBroken('访问过于频繁，该功能已暂停至明日'),

  /// 对方未留联系方式（§7.8 边界）。
  noContact('对方未留联系方式，尝试举报让其补充'),

  /// 网络或服务端异常。
  networkError('网络异常，请稍后重试');

  const ContactFailure(this.message);

  /// 面向用户的提示文案。文案与原因绑在一起，避免同一错误在不同页面说法不一。
  final String message;
}

/// 拉取完整联系方式失败。
class ContactException implements Exception {
  const ContactException(this.failure);

  final ContactFailure failure;

  @override
  String toString() => 'ContactException(${failure.name}): ${failure.message}';
}

/// 完整联系方式（仅存在于内存，用后即弃）。
class FullContact {
  const FullContact({required this.channel, required this.value});

  final ContactChannel channel;

  /// 完整联系方式明文。
  ///
  /// **不落盘、不进任何 Provider 缓存**：§9.6 数据最小化。一旦缓存，
  /// 「点击时才拉取」的防护就退化成「拉一次就永久持有」，
  /// 而限频只能限住请求次数，限不住已经拿到手的数据。
  final String value;

  /// 可拨号（仅手机号可拨）。
  bool get callable => channel == ContactChannel.phone;
}

/// 联系方式拉取仓库。
class ContactRepository {
  const ContactRepository();

  /// 拉取完整联系方式并记联系事件（§12.3 `POST /posts/{id}/contact`）。
  ///
  /// 参数 [detail] 用于取渠道与脱敏值；[postId] 为接口 path 参数（§12.3
  /// `POST /posts/{id}/contact`）。样例实现用不到它，但先固定在签名里 ——
  /// 接后端时若才发现要加参数，调用点已散落各处。
  /// 返回完整联系方式，失败抛 [ContactException]。
  ///
  /// **样例实现说明**：由脱敏值反推一个合法的完整值，仅用于界面验收。
  /// 真实实现须调服务端接口 —— 客户端永远无法自行「解密」联系方式，
  /// 若能，就说明完整值本来就在客户端，反爬形同虚设。
  Future<FullContact> fetchFullContact({
    required String postId,
    required ListingDetail detail,
  }) async {
    if (!detail.hasContact) {
      throw const ContactException(ContactFailure.noContact);
    }

    // 模拟网络往返：加载态必须真实存在，否则按钮点下去到号码出现之间没有
    // 任何反馈，用户会重复点击 —— 而重复点击在真实环境下直接撞熔断（§7.7）。
    await Future<void>.delayed(const Duration(milliseconds: 600));

    return FullContact(
      channel: detail.contactChannel,
      value: sampleFullValue(detail),
    );
  }
}

/// 由脱敏值派生一个合法的完整值（仅样例，暴露给测试）。
///
/// 手机号补齐中间 4 位、微信号补齐中段，保证与脱敏展示前后一致 ——
/// 若两者不一致，用户会以为平台给错了号码。
String sampleFullValue(ListingDetail detail) {
  final masked = detail.contactMasked!;
  return switch (detail.contactChannel) {
    // 「138****8000」→「13866668000」：补回被星号遮住的 4 位。
    ContactChannel.phone => masked.replaceFirst('****', '6666'),
    // 「wx_h***12」→「wx_happy12」：补回被星号遮住的中段。
    ContactChannel.wechat => masked.replaceFirst('***', 'appy'),
  };
}

final contactRepositoryProvider = Provider<ContactRepository>(
  (ref) => const ContactRepository(),
);
