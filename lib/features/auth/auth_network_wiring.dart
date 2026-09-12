/// KTD5 焊接点：features → core 单向依赖的网络回调接线。
///
/// 职责边界（计划 KTD5 / U3 / U5）：
///   core 的 `networkHooksProvider` 默认抛 [StateError]，强制会话态到
///   [NetworkHooks] 七回调的映射必须落在 features 侧。本文件是唯一焊接
///   处：read [authSessionProvider] 与 [privacyConsentProvider]，
///   映射为不感知 Riverpod 的纯回调。`lib/core/` 永远不 import 本文件，
///   依赖方向保持 features → core 单向。
///
/// U5 新增的三个会话回调：
///   - writeToken → [AuthSessionNotifier.updateToken]（续期写回，不推进
///     代次；notifier 内部拒绝「已登出」写回，是代次校验外的第二道防线）；
///   - onSessionCleared → [AuthSessionNotifier.signOut]（认证类续期失败
///     清会话，跳登录由 UI watch 会话态完成）；
///   - readSessionEpoch → [AuthSessionNotifier.sessionEpoch]（续期发起
///     取样、写回前比对，R10 代次变更场景）。
///
/// 落点选择（计划允许 features/auth/ 或 main.dart，实现期定）：
///   落在本文件而非 main.dart —— U3 尚无 dio 消费方，main.dart 组装无
///   实际消费对象；业务接线条目（auth 页面/仓库接网络）再在组装根
///   override `networkHooksProvider`/`networkConfigProvider` 即可，
///   本 Provider 先作为可单测的映射存在。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/network/api_client.dart';
import '../privacy/privacy_consent.dart';
import 'auth_repository.dart';

/// UUID v4 生成器（无状态，全局共享一个实例）。
///
/// 必须用标准实现而非自拼随机串：`interaction_id` 是服务端去重唯一索引
/// `uk_event_dedup` 的最左列，碰撞会导致合法事件被静默去重（pubspec
/// 依赖旁已注明该理由）。
const Uuid _uuid = Uuid();

/// 把会话态/隐私同意态/设备标识/UUID 生成器焊接为 core [NetworkHooks]。
///
/// 返回：[NetworkHooks] 四回调均在**调用时**经 `ref.read` 实时取值：
///   登录态/同意态变化不需要重建 dio（HeaderInterceptor 每请求调回调），
///   故这里用 read 而非 watch——hooks 对象本身无状态，无需随态重建。
final Provider<NetworkHooks> wiredNetworkHooksProvider =
    Provider<NetworkHooks>((ref) {
      return NetworkHooks(
        // null/空串 = 未登录，HeaderInterceptor 据此不注入 Authorization
        // （连空串都不写，§11.2）。
        readToken: () async => ref.read(authSessionProvider)?.token,
        // 仅 agreed 视为同意；unknown（冷启动读盘完成前）按未同意处理，
        // 绝不外发设备 ID（PrivacyConsentNotifier 三态语义）。
        readPrivacyConsented: () async =>
            ref.read(privacyConsentProvider) == PrivacyConsentStatus.agreed,
        readDeviceId: () async {
          // DeviceIdProvider 自身惰性：未同意时 HeaderInterceptor 不会调
          // 本回调（§11.2 / PRD §6.5.1），同意后的首次调用才生成落盘。
          return ref.read(deviceIdProvider).getOrCreate();
        },
        // 显式闭包而非 tear-off：v4 带可选命名参数，封成零参函数与
        // NetworkHooks.newUuidV4 签名严格一致。
        newUuidV4: () => _uuid.v4(),
        // U5：续期成功写回（不推进代次；无会话时 notifier 内部拒绝写回）。
        writeToken: (token, expireAt) async {
          ref
              .read(authSessionProvider.notifier)
              .updateToken(token: token, expireAt: expireAt);
        },
        // U5：认证类续期失败（refresh 自身 40101/403xx）清会话。
        onSessionCleared: () async {
          ref.read(authSessionProvider.notifier).signOut();
        },
        // U5：续期发起取样、写回前比对；在途登出/换号则丢弃续期结果。
        readSessionEpoch: () async =>
            ref.read(authSessionProvider.notifier).sessionEpoch,
      );
    });
