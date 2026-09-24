/// 详情页真网络数据源（[127] 前端段）。
///
/// 为什么新建 [postDetailProvider] 而不是改造既有的 [listingDetailProvider]
/// （mock 派生）：后者被 contact 中转页（[128] 才接真后端）共享，且其 mock
/// 派生逻辑依赖 [allListingsProvider]。把详情页切换到真网络而不牵连 contact
/// 页，须新建独立 provider —— 否则 contact 页会在「详情接真、联系方式仍是 mock」
/// 的过渡期被连带改坏（[127] 用户裁定「新建独立 provider」）。
///
/// 本文件的唯一职责是「契约 DTO → 域模型」的语义迁移（详细设计 §10.4）与
/// 异步 Provider 装配。契约传输形态在 [PostDetailDto]，域模型是 [ListingDetail]。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../../domain/category_tree.dart';
import '../../domain/listing.dart';
import '../../domain/listing_category.dart';
import '../../domain/listing_detail.dart';
import '../post/post_dto.dart';
import '../post/post_repository.dart';

/// 详情数据 Provider（`FutureProvider.family<ListingDetail, int>`）。
///
/// 参数：帖子 ID（`int`，契约 `PostIdPath` 为 int64，详细设计 §10.4.3）。
///
/// 三态语义（详细设计 §15）：
///   - `loading`：首次拉取中，详情页显示加载态；
///   - `error`：`ApiException(41001)` 表示信息已下架/不存在（显示「信息不存在」），
///     其余（网络失败、42907 游客限频、50001）显示可重试错误态；
///   - `data`：映射后的 [ListingDetail]。
final postDetailProvider = FutureProvider.family<ListingDetail, int>((
  ref,
  postId,
) async {
  final dto = await ref
      .watch(postRepositoryProvider)
      .fetchDetail(postId);
  return postDetailToListingDetail(dto);
});

/// 契约 [PostDetailDto] → 域模型 [ListingDetail]（§10.4 语义迁移）。
///
/// 公开为顶层函数而非私有：这是 §10.4 迁移的**最高风险区**（多处「契约值 ≠
/// 本地值」的显式转换），须单测钉死，不能只靠 Provider 集成验证 —— 集成验证
/// 会漏掉「转换静默错位」这类不抛异常但值不对的缺陷（详细设计 §10.4 反复强调
/// 的「看着能跑」陷阱）。
///
/// 迁移点（每处都是一次显式转换，禁 values.byName / 算术推导）：
///   1. `type`(resource/demand) → [SupplyDemand]（`supplyDemandFromApi`）；
///   2. `leaf_category_id` → 五大类 [ListingCategory]（`topCategoryOf` 查表）；
///   3. `completeness_level`(0/1/2) → [CompletenessLevel]（[completenessFromApi]）；
///   4. `realname_status`(四态) → [Publisher.realNameVerified]（仅 passed 为 true）；
///   5. `attributes`(map) → [TemplateField] 有序键值对；
///   6. `price`/`price_unit` → [Listing.price]/[priceUnit]。
///
/// 降级（契约未定义、属其它条目口径，本轮不越界自创）：
///   - [ListingDetail.contactChannel] 恒 [ContactChannel.phone]：契约 `PostDetail`
///     不返回 `contact_channel`（联系方式渠道属 [128] contact 域口径），详情页
///     仅用其决定「联系 TA」按钮图标，降级默认电话图标，精确值待 [128]；
///   - [ListingDetail.contactMasked] 恒 null：详情接口 `contact_mask` 恒 null
///     （完整/脱敏值只由 `GET /posts/{id}/contact` 返回，[128]）；
///   - [ListingDetail.negotiable] 恒 false：契约与 DDL 均无「可议价」字段。
ListingDetail postDetailToListingDetail(PostDetailDto dto) {
  final listing = Listing(
    id: dto.id,
    title: dto.title,
    category: topCategoryOf(dto.leafCategoryId) ?? ListingCategory.service,
    supplyDemand: supplyDemandFromApi(dto.type),
    latitude: dto.lat,
    longitude: dto.lng,
    createdAt: dto.publishAt,
    price: dto.price,
    priceUnit: dto.priceUnit,
  );

  return ListingDetail(
    listing: listing,
    description: dto.description ?? '',
    publisher: Publisher(
      id: dto.author.id.toString(),
      nickname: dto.author.nickname,
      // §10.4 迁移：四态坍缩为「是否通过」布尔。non-passed 不展示认证标
      // （PRD §9.8「有认证才展示」），故 pending/rejected/none 均为 false。
      realNameVerified: dto.author.realnameStatus == 'passed',
      // 资质徽章数组取首个（Batch1 恒空，cert 空壳无数据源；未来多资质
      // 的展示形态由信任体系页 [trust] 定义，详情页只需「有没有」）。
      qualificationLabel: dto.author.qualificationBadges.isEmpty
          ? null
          : dto.author.qualificationBadges.first,
    ),
    completeness: completenessFromApi(dto.completenessLevel),
    expireAt: dto.expireAt,
    contactChannel: ContactChannel.phone,
    leafCategoryId: dto.leafCategoryId,
    templateFields: _templateFieldsFromAttributes(dto.attributes),
    address: dto.address,
  );
}

/// 完整度等级：契约 int(0/1/2) → 本地枚举（§10.4 迁移）。
///
/// 显式 switch 而非 `CompletenessLevel.values[code]`：契约 `0=红/1=黄/2=绿`，
/// 与本地枚举声明序（green/yellow/red）不同名不同序，下标写法会让「看着能跑」
/// 的错误实现掩盖语义错位。
CompletenessLevel completenessFromApi(int code) => switch (code) {
  0 => CompletenessLevel.red,
  1 => CompletenessLevel.yellow,
  2 => CompletenessLevel.green,
  _ => throw ApiException.parse('未知 completeness_level: $code'),
};

/// 动态属性 map → 有序模板字段（§10.4 迁移）。
///
/// 降级说明：契约 `attributes` 的键是模板字段 **key**（如 `work_time`），非
/// 中文 label；label 需模板 schema（`template.fields[].key → label`）映射，
/// 那是 [124] 模板域的活。本轮详情页以 key 直出为 label，值转字符串 —— 数据
/// 正确（值来自服务端）、结构正确（有序），label 中文化待模板 schema 接入时
/// 只改本函数一处。
List<TemplateField> _templateFieldsFromAttributes(Map<String, Object?> attributes) {
  return [
    for (final entry in attributes.entries)
      (label: entry.key, value: entry.value?.toString() ?? ''),
  ];
}
