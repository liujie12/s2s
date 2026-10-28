/// 发布草稿本地存储（PRD §8.7「每编辑 3 秒自动存本地」+「退出页面提示保存」）。
///
/// **为什么草稿只存本地、且只存一份（2026-10 裁定）**：
///   - 服务端不落 `draft`（PRD §8.7 草稿为纯客户端概念），契约也没有草稿
///     端点，故草稿的持久化只能落在客户端；
///   - 发布页在同一时刻只承载「一份进行中的表单」——自动保存保存的就是这份
///     当前表单，不存在「同时编辑多份草稿」的入口。为不存在的需求造多份
///     草稿的键管理（列表/去重/选中）是纯复杂度，故这里**只维护单份草稿**：
///     用单键存储，[DraftStore.list] 至多返回 1 条，[DraftStore.remove] 只
///     对该单份生效。若将来产品确需多草稿，再改键结构并补测试。
///   - 载荷是 [PublishFormState] 的可序列化快照；`loadedTemplate` 不持久化
///     ——它是服务端模板的就位态，恢复时必须由页面重新拉取（否则会拿着一个
///     可能已过期的字段集合）。
///
/// 存储用 `shared_preferences`（项目既有依赖，隐私同意态同源用法）。
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'publish_form_state.dart';

/// 发布页草稿自动保存的防抖间隔（PRD §8.7「每编辑 3 秒自动存本地」）。
///
/// 具名常量而非业务代码里裸写 `Duration(seconds: 3)`：阈值口径收一处，
/// 改动只在此处（红线「不复制字面量」）。
const Duration kDraftAutosaveInterval = Duration(seconds: 3);

/// 一份发布草稿快照（可序列化）。
class DraftSnapshot {
  /// 构造草稿快照。
  ///
  /// 参数：[draftId] 草稿标识（单份模型下恒为 [DraftStore.singleDraftId]）；
  ///   [form] 表单快照；[savedAt] 保存时刻（草稿卡片副标题用）。
  const DraftSnapshot({
    required this.draftId,
    required this.form,
    required this.savedAt,
  });

  /// 由当前表单构造快照（保存时刻取当前时间）。
  ///
  /// 参数：[form] 待保存表单；[savedAt] 覆盖保存时刻（测试用，生产不传）。
  /// 返回：[DraftSnapshot]。
  factory DraftSnapshot.of(PublishFormState form, {DateTime? savedAt}) {
    return DraftSnapshot(
      draftId: DraftStore.singleDraftId,
      form: form,
      savedAt: savedAt ?? DateTime.now(),
    );
  }

  /// 由持久化 JSON 构造。
  ///
  /// 参数：[json] [toJson] 的逆。
  /// 返回：[DraftSnapshot]。
  factory DraftSnapshot.fromJson(Map<String, Object?> json) {
    return DraftSnapshot(
      draftId: (json['draft_id'] as String?) ?? DraftStore.singleDraftId,
      savedAt: DateTime.tryParse((json['saved_at'] as String?) ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      form: _formFromJson(json['form']),
    );
  }

  /// 草稿标识。
  final String draftId;

  /// 表单快照。
  final PublishFormState form;

  /// 保存时刻。
  final DateTime savedAt;

  /// 序列化为可 JSON 编码的对象。
  ///
  /// 返回：[Map]（键 snake_case，与持久化口径一致）。
  Map<String, Object?> toJson() => <String, Object?>{
    'draft_id': draftId,
    'saved_at': savedAt.toIso8601String(),
    'form': _formToJson(form),
  };
}

/// 表单快照 → JSON（`loadedTemplate` 不写：恢复时置 null 由页面重拉）。
Map<String, Object?> _formToJson(PublishFormState form) => <String, Object?>{
  'kind': form.kind.name,
  'leaf_category_id': form.leafCategoryId,
  'lng': form.lng,
  'lat': form.lat,
  'location_label': form.locationLabel,
  'door_number': form.doorNumber,
  'title': form.title,
  'price_text': form.priceText,
  'price_unit': form.priceUnit,
  'negotiable': form.negotiable,
  'description': form.description,
  'template_values': form.templateValues,
  'media_ids': form.mediaIds,
  'cert_id': form.certId,
  'contact': form.contact,
  'agreed': form.agreed,
};

/// JSON → 表单快照（容错：任何字段缺失/类型不符一律退默认值）。
///
/// 草稿是「尽力恢复」的本地便利数据，不是契约载荷；一条坏草稿不应让进入
/// 发布页直接崩，故这里逐字段兜底，坏数据退化为空白表单。
PublishFormState _formFromJson(Object? raw) {
  if (raw is! Map) return const PublishFormState();
  final map = raw.cast<String, Object?>();

  final templateRaw = map['template_values'];
  final templateValues = templateRaw is Map
      ? <String, String>{
          for (final entry in templateRaw.entries)
            if (entry.value is String) entry.key.toString(): entry.value as String,
        }
      : const <String, String>{};

  final mediaRaw = map['media_ids'];
  final mediaIds = mediaRaw is List
      ? <String>[for (final item in mediaRaw) if (item is String) item]
      : const <String>[];

  final kindName = map['kind'];
  final kind = PublishKind.values.firstWhere(
    (k) => k.name == kindName,
    orElse: () => PublishKind.supply,
  );

  return PublishFormState(
    kind: kind,
    leafCategoryId: map['leaf_category_id'] as int?,
    lng: (map['lng'] as num?)?.toDouble(),
    lat: (map['lat'] as num?)?.toDouble(),
    locationLabel: (map['location_label'] as String?) ?? '',
    doorNumber: (map['door_number'] as String?) ?? '',
    title: (map['title'] as String?) ?? '',
    priceText: (map['price_text'] as String?) ?? '',
    priceUnit: map['price_unit'] as String?,
    negotiable: (map['negotiable'] as bool?) ?? false,
    description: (map['description'] as String?) ?? '',
    templateValues: templateValues,
    mediaIds: mediaIds,
    certId: map['cert_id'] as int?,
    contact: (map['contact'] as String?) ?? '',
    agreed: (map['agreed'] as bool?) ?? false,
    // loadedTemplate 刻意不恢复：见文件头说明，由页面重新拉取。
  );
}

/// 发布草稿存储（单份模型，见文件头）。
class DraftStore {
  /// 构造无状态存储（每次读写即时取 SharedPreferences，不缓存实例）。
  const DraftStore();

  /// 单份草稿的固定标识。
  static const String singleDraftId = 'publish-draft';

  /// 持久化键名（带 `s2s.` 前缀避免与插件写入的键冲突）。
  static const String _draftKey = 's2s.publish.draft';

  /// 保存草稿（覆盖式：单份模型下后写覆盖前写）。
  ///
  /// 参数：[snapshot] 待保存快照。
  /// 返回：[Future<void>] 落盘完成。
  Future<void> save(DraftSnapshot snapshot) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_draftKey, jsonEncode(snapshot.toJson()));
  }

  /// 读取草稿。
  ///
  /// 返回：[Future<DraftSnapshot?>]；无草稿或内容损坏（JSON 非法）时为 null
  ///   —— 坏草稿当作无草稿，不让进入发布页崩。
  Future<DraftSnapshot?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_draftKey);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return DraftSnapshot.fromJson(decoded.cast<String, Object?>());
    } catch (_) {
      return null;
    }
  }

  /// 列出全部草稿（单份模型下至多 1 条）。
  ///
  /// 返回：[Future<List<DraftSnapshot>>]；无草稿为空列表。
  Future<List<DraftSnapshot>> list() async {
    final one = await load();
    return one == null ? const <DraftSnapshot>[] : <DraftSnapshot>[one];
  }

  /// 删除指定草稿（单份模型下仅 [singleDraftId] 生效）。
  ///
  /// 参数：[draftId] 草稿标识。
  /// 返回：[Future<void>]。
  Future<void> remove(String draftId) async {
    if (draftId != singleDraftId) return;
    await clear();
  }

  /// 清空草稿（提交成功后 / 用户选择不保存）。
  ///
  /// 返回：[Future<void>]。
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_draftKey);
  }
}

/// 草稿存储 Provider（页面经 `ref.read`/`ref.watch` 取；测试可覆写）。
final draftStoreProvider = Provider<DraftStore>((ref) => const DraftStore());

/// 草稿列表 Provider（「我的发布」草稿页签渲染用；删除后 `ref.invalidate` 刷新）。
final draftListProvider = FutureProvider<List<DraftSnapshot>>((ref) async {
  return ref.watch(draftStoreProvider).list();
});
