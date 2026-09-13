/// HTTP `Retry-After` 响应头整数秒解析（详设 §11.3 / §14.1，
/// 编码规范 §5.3/§1.2 唯一实现处）。
///
/// 为什么单建此文件：信封失败分流（EnvelopeInterceptor，§11.3）与重试
/// 等待决策（RetryInterceptor，§14.1）都需要同一个「整数秒、失败回退」
/// 语义；按编码规范 §1.1，同一逻辑出现第 2 次前提取共享实现，禁止两处
/// 各写一遍 `int.tryParse(raw.trim())`（评审 #7/#8）。
///
/// 边界口径（与详设 §11.3「服务端约定整数秒而非 HTTP-date」一致）：
///   - 本函数**只解析、不钳制**：429 段不自动重试，
///     [ApiException.retryAfterSec] 承载的是服务端给 UI 倒计时的原始指令
///     （可能合法地大于客户端自动等待上界，如 3600s），在此钳制会篡改
///     UI 语义；
///   - 自动重试路径的上界钳制是「客户端后台等待」的独立纪律，唯一落点
///     是 RetryInterceptor 的等待时长计算（引
///     [NfrNetwork.retryAfterMaxSec]），不放在本函数；
///   - 头缺失、空白、非整数（含 HTTP-date 形态、浮点）一律回退 null，
///     调用方据此退回 §14.1 默认退避表；解析本身**永不抛异常**。
library;

/// `Retry-After` HTTP 响应头名（小写形态：dio Headers.value 按
/// 大小写不敏感匹配，统一此处为唯一字面量真源）。
const String retryAfterHeaderName = 'retry-after';

/// 解析 `Retry-After` 头原始值为整数秒。
///
/// 参数：[rawHeaderValue] 响应头原始字符串（dio 经
///   `response.headers.value('retry-after')` 取得，多值时取首个）；
///   null 表示头缺失。
/// 返回：[int?] 去空白后可解析为整数时返回该整数（含 0 与负值——
///   是否/如何钳制由消费方按各自语义决定）；其余形态返回 null。
int? parseRetryAfterHeader(String? rawHeaderValue) {
  if (rawHeaderValue == null) return null;
  return int.tryParse(rawHeaderValue.trim());
}
