/// 三级分类树（PRD §2.4 分类三级树 / §2.9 实现逻辑 / §12.3 `/categories/tree`）。
///
/// 为什么现在建：它是发布页的硬前置 —— 没有叶子类目就取不到模板 Schema
/// （§5.7 按 `leaf_category_id` 映射模板），级联选择器（§5.4.2 三列）也无数据源。
/// 同时它是条目 [67] 记下的架构欠账：详情页面包屑此前靠 `categoryPath`
/// 字符串字面量临时缓解，那些字面量与 §2.4 并不一致（例如写过
/// 「房屋 > 整租 > 一室一厅」，而 §2.4 的叶子是「整租出租」；写过
/// 「家政 > 保洁 > 日常保洁」，一级实为「服务」）。**字面量对不上真源这件事
/// 本身查不出来，因为没有任何一处拿它跟 §2.4 比过** —— 建树即消除该类漂移。
///
/// 为什么用单一 [CategoryNode] 自引用结构而不是三个层级类：§13.2 的 `category`
/// 表就是自引用单表（`parent_id`），三个类会让「按 parent_id 回溯面包屑」这件事
/// 退化成三段 switch。级联选择器也只需对同一种节点做三次列表渲染。
///
/// 2026-11-08 扩类：按用户反馈「二三级分类 item 不够多」，参照闲鱼一级类目、
/// 58 同城（保洁清洗 / 家电维修 / 搬家 / 管道疏通 / 招聘 / 房产 / 二手）与
/// 啄木鸟家庭维修（15 个服务大类）把规模从 5/21/48 扩到 5/25/120。
/// **只追加、不重排**：原有编号全部保留，新二级 104/105/205/305 与新叶子
/// 一律顺延，避免历史 `post.leaf_category_id` 指向错类。
library;

import 'listing_category.dart';

/// 分类树版本号（§2.9「版本号 + 本地缓存」，§12.3 `/categories/tree` 的 `version` 入参）。
///
/// 现为编译期常量，接后端后改为「本地缓存值 + 服务端下发值比对」：
/// 版本未变则服务端返回 `code=0,data=null`（§12.3），客户端继续用缓存。
/// TODO(M5)：改为可持久化字段，接 `GET /categories/tree`。
const String categoryTreeVersion = '2026-11-11.1';

/// 发布该叶子类目所需的认证类型（§4.3 认证类型表 / §2.9 末条高敏标记）。
///
/// 用枚举而非 bool：§5.8 的拦截动作要「弹浮层跳**对应**认证」，只知道
/// 「需要认证」却不知道需要哪一种，浮层就没法给出正确的跳转目标。
enum RequiredCert {
  /// 无强制认证（未实名仍可发，落 §3.7 先发后审受限态）
  none,

  /// 个人资质：证书 OCR + 人工审核（§4.3「发布服务类 5.x 叶子类目强制」）
  personalQualification,

  /// 企业认证：营业执照 OCR + 工商三要素（§4.3「发布房源/工作招聘等强制」）
  enterprise,

  /// 车辆认证：行驶证 OCR（§4.3「发布拼车/租车强制」）
  vehicle,
}

/// 认证类型的显示名（拦截浮层与「信任与认证」页共用）。
extension RequiredCertProps on RequiredCert {
  String get label => switch (this) {
    RequiredCert.none => '无',
    RequiredCert.personalQualification => '个人资质',
    RequiredCert.enterprise => '企业认证',
    RequiredCert.vehicle => '车辆认证',
  };
}

/// 分类树节点（一级 / 二级 / 三级共用）。
class CategoryNode {
  const CategoryNode({
    required this.id,
    required this.name,
    this.icon,
    this.children = const [],
    this.requiredCert = RequiredCert.none,
  });

  /// 稳定数字 ID，编号规则即层级：一级 `N`、二级 `N*100+M`、三级 `N*10000+M*100+K`。
  ///
  /// 这样编号而非自增序号的用意：`10101` 能直接推出它的二级是 `101`、一级是 `1`，
  /// 于是「按 id 回溯面包屑」不需要在树里做一次深搜（[categoryPathOf] 即靠此）。
  /// 该 ID 对应 §13.2 `post.leaf_category_id`，属契约，**已发布的编号不得重排**。
  final int id;

  /// 类目名，逐字取自 §2.4。
  final String name;

  /// 服务端下发的图标名（`category.icon`，Material Symbols 名；`nullable`）。
  ///
  /// 数据链路：DB `category.icon` → `/categories/tree` → 本字段 → 渲染。
  /// 由 `categoryIconByName` 解析成字形；**本层不持字形**，理由同
  /// `listing_category_style.dart` 文件头：域模型不该绑 Flutter 的 `IconData`，
  /// 聚合层还要在纯 Dart 下跑（POC-A 基准）。
  ///
  /// 为 null 的两种正常情况：契约本身可缺失；内置常量树不重复登记服务端数据
  /// （离线兜底走 `l2CategoryIcon`）。渲染层按「服务端名 → 本地二级 → 一级」
  /// 逐级降级，见 `nodeIconOf`。
  final String? icon;

  /// 子节点。叶子为空列表。
  final List<CategoryNode> children;

  /// 发布本类目所需认证。仅叶子有意义（§2.9「在分类树上加标记」）。
  final RequiredCert requiredCert;

  /// 是否叶子类目（能绑定模板、能被发布选中的那一层）。
  bool get isLeaf => children.isEmpty;

  /// 所属一级大类 —— 决定大类色（§2 末条「1 个大类色」）。
  ///
  /// 由 id 首位取一级编号而非另存字段：另存等于同一事实有两份记录，
  /// 挪动节点时漏改一处就会出现「在房屋分支下显示蓝色」这类错。
  ///
  /// **一级编号到枚举的那一步用显式 switch，不用 `values[top - 1]`。**
  /// 下标写法在一级编号超出 1..5 时抛 `RangeError`，而 Dart 的 `assert`
  /// 在 release 不参与编译（详细设计 §10.4.1），于是「树里多了一个一级类目」
  /// 这种数据问题会以内测包崩溃的形式暴露。switch + 返回 null 让它退化为
  /// 「该节点没有大类色」，页面用中性配色即可。
  ///
  /// 返回：对应的一级大类；一级编号不在 1..5 时返回 null。
  ListingCategory? get topCategory => _topCategoryOfTopId(
    id >= 10000
        ? id ~/ 10000
        : id >= 100
        ? id ~/ 100
        : id,
  );
}

/// 一级类目编号（1..5）→ 本地渲染枚举。
///
/// 这层映射是**本地枚举与分类树树根的绑定**，唯此一处，故显式写死。
/// 不用 `ListingCategory.values[topId - 1]`：那样枚举顺序与树根编号就成了
/// 隐式耦合，调整枚举顺序不会有任何编译错误，只会让配色整体串一位。
///
/// [topId] 一级类目编号，取自 §2.4（工作 1 / 房屋 2 / 车辆 3 / 生活 4 / 服务 5）
///
/// 返回：对应枚举；编号不在 1..5 时返回 null（不抛异常，理由见 [topCategory]）
ListingCategory? _topCategoryOfTopId(int topId) => switch (topId) {
  1 => ListingCategory.work,
  2 => ListingCategory.house,
  3 => ListingCategory.vehicle,
  4 => ListingCategory.life,
  5 => ListingCategory.service,
  _ => null,
};

/// 由叶子类目 ID 取所属二级类目 ID（编号规则见 [CategoryNode.id]）。
///
/// 参数 [leafCategoryId] 服务端下发的叶子类目 ID（如 `10101`）。
/// 返回：二级类目 ID（如 `101`）。**不做合法性校验** —— 未登记的编号由调用方
///   按「查不到」降级（与 [topCategory] 返回 null 同取向）。
///
/// 为什么单独成一个函数而不是各处写 `leaf ~/ 100`：这条整除规则与
/// [categoryPathOf] 的回溯是同一份契约，散在调用点写就会有一处写错而无人发现
/// —— 表现是「某个分类的图标不对」，肉眼极难归因。
int midCategoryIdOf(int leafCategoryId) => leafCategoryId ~/ 100;

/// 由**叶子类目 ID** 反查一级大类（详细设计 §10.4.1 第 2、3 步）。
///
/// 这是 `listingCategoryFromId` 的替代品。后者把服务端下发的叶子类目 ID
/// （如 `10101`）当成本地枚举下标用，debug 下被 `assert` 拦住、release 下
/// 直接 `values[10101]` 抛 `RangeError` —— 那个函数已删除。
///
/// **实现刻意遍历分类树，而不是按编码规则取前几位。** `10101` 的前两位是 `10`，
/// 看起来能映射，但那依赖服务端类目编码规则永不变；而分类树带版本号
/// （[categoryTreeVersion]）且会演进。遍历 120 个叶子的成本可忽略，换来的是
/// 「编码规则改了也不会静默错」。
///
/// [leafCategoryId] 服务端下发的叶子类目 ID（如 `10101`）
/// [tree] 当前生效的分类树，默认取内置 [categoryTree]（版本协商见 §16.4）
///
/// 返回：对应的一级大类；树中查不到该叶子时返回 null
///
/// **返回 null 而不抛异常**：本地分类树版本落后于服务端数据时，新增类目查不到
/// 是 §16.4 明确规定的**预期内状态**（版本不一致不报错）。调用方应降级为
/// 「中性配色（`neutralCategoryColor`）+ 触发异步拉树」，**不要丢弃该条数据** ——
/// 丢弃会让用户觉得「东西不见了」，比配色不对严重得多。
ListingCategory? topCategoryOf(
  int leafCategoryId, {
  List<CategoryNode> tree = categoryTree,
}) {
  for (final top in tree) {
    for (final mid in top.children) {
      for (final leaf in mid.children) {
        if (leaf.id == leafCategoryId) return top.topCategory;
      }
    }
  }
  return null;
}

/// 全量分类树（§2.4 逐字建模，5 一级 / 25 二级 / 120 叶子）。
///
/// 名称与层级严格照抄 §2.4，不做「顺手规整」——
/// 例如二级「二手闲置转让」不简写为「闲置」、「家政/保洁」保留斜杠：
/// 一旦此处与 PRD 有一字之差，日后就无从判断是 PRD 改了还是这里抄错了。
const List<CategoryNode> categoryTree = [
  // ── 1. 工作 JOB ──
  CategoryNode(
    id: 1,
    name: '工作',
    children: [
      CategoryNode(
        id: 101,
        name: '全职招聘',
        children: [
          // 招聘方为雇主，故按 §4.3「发布工作招聘强制企业认证」打标。
          CategoryNode(
            id: 10101,
            name: '餐饮服务',
            icon: 'restaurant',
            requiredCert: RequiredCert.enterprise,
          ),
          CategoryNode(
            id: 10102,
            name: '零售导购',
            icon: 'storefront',
            requiredCert: RequiredCert.enterprise,
          ),
          CategoryNode(
            id: 10103,
            name: '家政保洁',
            icon: 'MOP',
            requiredCert: RequiredCert.enterprise,
          ),
          CategoryNode(
            id: 10104,
            name: '保安仓管',
            icon: 'security',
            requiredCert: RequiredCert.enterprise,
          ),
          CategoryNode(
            id: 10105,
            name: '其他全职',
            icon: 'MISC_WORK',
            requiredCert: RequiredCert.enterprise,
          ),
          CategoryNode(
            id: 10106,
            name: '普工/技工',
            icon: 'precision_manufacturing',
            requiredCert: RequiredCert.enterprise,
          ),
        ],
      ),
      CategoryNode(
        id: 102,
        name: '兼职/临时工',
        children: [
          CategoryNode(
            id: 10201,
            name: '日结零工',
            icon: 'today',
            requiredCert: RequiredCert.enterprise,
          ),
          CategoryNode(
            id: 10202,
            name: '周末兼职',
            icon: 'calendar_view_week',
            requiredCert: RequiredCert.enterprise,
          ),
          CategoryNode(
            id: 10203,
            name: '小时工',
            icon: 'schedule',
            requiredCert: RequiredCert.enterprise,
          ),
          CategoryNode(
            id: 10204,
            name: '促销/展会兼职',
            icon: 'local_activity',
            requiredCert: RequiredCert.enterprise,
          ),
          CategoryNode(
            id: 10205,
            name: '快递分拣/打包',
            icon: 'inventory',
            requiredCert: RequiredCert.enterprise,
          ),
          CategoryNode(
            id: 10206,
            name: '传单派发',
            icon: 'newspaper',
            requiredCert: RequiredCert.enterprise,
          ),
        ],
      ),
      CategoryNode(
        id: 103,
        name: '求职找工作',
        children: [
          // 求职方是个人、发布的是自己的劳动力，不是招聘岗位 ——
          // 对他要求企业认证等于把找工作的人挡在门外，与 §3.7
          // 「不做成必须认证才能用」的取向相反，故不打标。
          CategoryNode(id: 10301, name: '个人求职', icon: 'assignment_ind'),
          CategoryNode(id: 10302, name: '全职求职', icon: 'badge'),
          CategoryNode(id: 10303, name: '兼职求职', icon: 'more_time'),
        ],
      ),
      CategoryNode(
        id: 104,
        name: '司机/物流',
        children: [
          // 与 101/102 同为「雇主招人」，沿用企业认证口径。
          CategoryNode(
            id: 10401,
            name: '货运司机',
            icon: 'moving',
            requiredCert: RequiredCert.enterprise,
          ),
          CategoryNode(
            id: 10402,
            name: '网约车/代驾',
            icon: 'local_taxi',
            requiredCert: RequiredCert.enterprise,
          ),
          CategoryNode(
            id: 10403,
            name: '快递员/外卖骑手',
            icon: 'delivery_dining',
            requiredCert: RequiredCert.enterprise,
          ),
          CategoryNode(
            id: 10404,
            name: '装卸搬运',
            icon: 'forklift',
            requiredCert: RequiredCert.enterprise,
          ),
          CategoryNode(
            id: 10405,
            name: '跟车/押运',
            icon: 'local_police',
            requiredCert: RequiredCert.enterprise,
          ),
        ],
      ),
      CategoryNode(
        id: 105,
        name: '销售/客服',
        children: [
          CategoryNode(
            id: 10501,
            name: '销售专员',
            icon: 'trending_up',
            requiredCert: RequiredCert.enterprise,
          ),
          CategoryNode(
            id: 10502,
            name: '电话销售',
            icon: 'call',
            requiredCert: RequiredCert.enterprise,
          ),
          CategoryNode(
            id: 10503,
            name: '网络销售',
            icon: 'chat',
            requiredCert: RequiredCert.enterprise,
          ),
          CategoryNode(
            id: 10504,
            name: '客服专员',
            icon: 'headset_mic',
            requiredCert: RequiredCert.enterprise,
          ),
          CategoryNode(
            id: 10505,
            name: '售后客服',
            icon: 'reviews',
            requiredCert: RequiredCert.enterprise,
          ),
        ],
      ),
    ],
  ),

  // ── 2. 房屋 HOUSE ──
  CategoryNode(
    id: 2,
    name: '房屋',
    children: [
      CategoryNode(
        id: 201,
        name: '整租/合租',
        children: [
          // §4.3「发布房源强制企业认证」。房东个人出租亦走此档 ——
          // 该口径由 §4.3 定，若日后要放开个人房东，改的是 PRD 不是这里。
          CategoryNode(
            id: 20101,
            name: '主卧出租',
            icon: 'bedroom_parent',
            requiredCert: RequiredCert.enterprise,
          ),
          CategoryNode(
            id: 20102,
            name: '次卧出租',
            icon: 'single_bed',
            requiredCert: RequiredCert.enterprise,
          ),
          CategoryNode(
            id: 20103,
            name: '整租出租',
            icon: 'villa',
            requiredCert: RequiredCert.enterprise,
          ),
          CategoryNode(
            id: 20104,
            name: '单间出租',
            icon: 'door_front_door',
            requiredCert: RequiredCert.enterprise,
          ),
          CategoryNode(
            id: 20105,
            name: '床位出租',
            icon: 'bed',
            requiredCert: RequiredCert.enterprise,
          ),
          CategoryNode(
            id: 20106,
            name: '合租找室友',
            icon: 'groups',
            requiredCert: RequiredCert.enterprise,
          ),
        ],
      ),
      CategoryNode(
        id: 202,
        name: '求租/找房',
        // 求租方不发布房源，不适用房源认证。
        children: [
          CategoryNode(id: 20201, name: '个人求租', icon: 'travel_explore'),
          CategoryNode(id: 20202, name: '合租求租', icon: 'person_add'),
          CategoryNode(id: 20203, name: '整租求租', icon: 'holiday_village'),
        ],
      ),
      CategoryNode(
        id: 203,
        name: '短租/日租',
        children: [
          CategoryNode(
            id: 20301,
            name: '短租民宿',
            icon: 'cottage',
            requiredCert: RequiredCert.enterprise,
          ),
          CategoryNode(
            id: 20302,
            name: '日租公寓',
            icon: 'calendar_view_day',
            requiredCert: RequiredCert.enterprise,
          ),
          CategoryNode(
            id: 20303,
            name: '短租床位',
            icon: 'night_shelter',
            requiredCert: RequiredCert.enterprise,
          ),
        ],
      ),
      CategoryNode(
        id: 204,
        name: '租房信息咨询',
        children: [
          CategoryNode(
            id: 20401,
            name: '房源线索/中介合作',
            icon: 'location_city',
            requiredCert: RequiredCert.enterprise,
          ),
          CategoryNode(
            id: 20402,
            name: '租房政策咨询',
            icon: 'gavel',
            requiredCert: RequiredCert.enterprise,
          ),
          CategoryNode(
            id: 20403,
            name: '验房/带看服务',
            icon: 'fact_check',
            requiredCert: RequiredCert.enterprise,
          ),
        ],
      ),
      CategoryNode(
        id: 205,
        name: '二手房/商业地产',
        children: [
          // 房源发布 / 经营类挂载沿用 §4.3 企业认证；求购方不发布房源，不认证。
          CategoryNode(
            id: 20501,
            name: '二手房出售',
            icon: 'home_work',
            requiredCert: RequiredCert.enterprise,
          ),
          CategoryNode(id: 20502, name: '二手房求购', icon: 'request_quote'),
          CategoryNode(
            id: 20503,
            name: '商铺出租/转让',
            icon: 'store',
            requiredCert: RequiredCert.enterprise,
          ),
          CategoryNode(
            id: 20504,
            name: '写字楼出租',
            icon: 'business',
            requiredCert: RequiredCert.enterprise,
          ),
          CategoryNode(
            id: 20505,
            name: '厂房/仓库',
            icon: 'warehouse',
            requiredCert: RequiredCert.enterprise,
          ),
          CategoryNode(
            id: 20506,
            name: '车位租售',
            icon: 'local_parking',
            requiredCert: RequiredCert.enterprise,
          ),
        ],
      ),
    ],
  ),

  // ── 3. 车辆 CAR ──
  CategoryNode(
    id: 3,
    name: '车辆',
    children: [
      CategoryNode(
        id: 301,
        name: '顺风车/拼车',
        children: [
          // §4.3「发布拼车/租车强制车辆认证」：车主须证明车是自己的。
          CategoryNode(
            id: 30101,
            name: '上下班拼车',
            icon: 'COMMUTE',
            requiredCert: RequiredCert.vehicle,
          ),
          CategoryNode(
            id: 30102,
            name: '跨城顺风车',
            icon: 'CROSS_CITY',
            requiredCert: RequiredCert.vehicle,
          ),
          CategoryNode(
            id: 30103,
            name: '周末拼车',
            icon: 'WEEKEND',
            requiredCert: RequiredCert.vehicle,
          ),
          CategoryNode(
            id: 30104,
            name: '机场/车站接送',
            icon: 'FLIGHT',
            requiredCert: RequiredCert.vehicle,
          ),
          CategoryNode(
            id: 30105,
            name: '长期拼车',
            icon: 'LONGTERM',
            requiredCert: RequiredCert.vehicle,
          ),
        ],
      ),
      CategoryNode(
        id: 302,
        name: '租车/借车',
        children: [
          CategoryNode(
            id: 30201,
            name: '私家车出租',
            icon: 'KEY',
            requiredCert: RequiredCert.vehicle,
          ),
          CategoryNode(
            id: 30202,
            name: '货车出租',
            icon: 'TRUCK',
            requiredCert: RequiredCert.vehicle,
          ),
          CategoryNode(
            id: 30203,
            name: '大巴/中巴出租',
            icon: 'BUS',
            requiredCert: RequiredCert.vehicle,
          ),
          CategoryNode(
            id: 30204,
            name: '婚车租赁',
            icon: 'CAR_BOW',
            requiredCert: RequiredCert.vehicle,
          ),
          CategoryNode(
            id: 30205,
            name: '以租代购',
            icon: 'PAPER',
            requiredCert: RequiredCert.vehicle,
          ),
        ],
      ),
      CategoryNode(
        id: 303,
        name: '二手车转让',
        // 转让是一次性买卖，§4.3 只对「拼车/租车」强制车辆认证，
        // 不擅自扩大到转让 —— 扩大范围等于我替产品改了准入门槛。
        children: [
          CategoryNode(id: 30301, name: '个人二手车', icon: 'CAR_PERSON'),
          CategoryNode(id: 30302, name: '轿车转让', icon: 'SEDAN'),
          CategoryNode(id: 30303, name: 'SUV/MPV 转让', icon: 'SUV'),
          CategoryNode(id: 30304, name: '货车/工程车转让', icon: 'DUMP'),
          CategoryNode(id: 30305, name: '摩托车/电动车转让', icon: 'two_wheeler'),
        ],
      ),
      CategoryNode(
        id: 304,
        name: '求搭车/求拼',
        // 求搭车方没有车，要求行驶证会是一道无法满足的门。
        children: [
          CategoryNode(id: 30401, name: '个人求搭车', icon: 'HITCH_ROAD'),
          CategoryNode(id: 30402, name: '长期拼车求带', icon: 'HITCH_CAL'),
          CategoryNode(id: 30403, name: '顺路捎带', icon: 'HITCH_ROUTE'),
        ],
      ),
      CategoryNode(
        id: 305,
        name: '汽车维修/保养',
        // §4.3 只对「拼车/租车」强制车辆认证；维修保养属普通服务，
        // 不擅自把行驶证要求扩大到修车方（否则等于替产品加门槛）。
        children: [
          CategoryNode(id: 30501, name: '维修保养', icon: 'handyman'),
          CategoryNode(id: 30502, name: '洗车美容', icon: 'local_car_wash'),
          CategoryNode(id: 30503, name: '轮胎/电瓶', icon: 'tire_repair'),
          CategoryNode(id: 30504, name: '钣金喷漆', icon: 'format_paint'),
          CategoryNode(id: 30505, name: '汽车改装', icon: 'settings_suggest'),
          CategoryNode(id: 30506, name: '道路救援', icon: 'health_and_safety'),
        ],
      ),
    ],
  ),

  // ── 4. 生活 LIFE ──
  CategoryNode(
    id: 4,
    name: '生活',
    children: [
      CategoryNode(
        id: 401,
        name: '二手闲置转让',
        children: [
          CategoryNode(id: 40101, name: '家具家电', icon: 'SOFA_TV'),
          CategoryNode(id: 40102, name: '母婴儿童', icon: 'child_care'),
          CategoryNode(id: 40103, name: '数码电子', icon: 'devices'),
          CategoryNode(id: 40104, name: '服饰鞋包', icon: 'checkroom'),
          CategoryNode(id: 40105, name: '其他二手', icon: 'JUNK'),
          CategoryNode(id: 40106, name: '运动户外', icon: 'hiking'),
        ],
      ),
      CategoryNode(
        id: 402,
        name: '借物/互助',
        children: [
          CategoryNode(id: 40201, name: '临时借物', icon: 'pan_tool'),
          CategoryNode(id: 40202, name: '邻里互助', icon: 'diversity_3'),
          CategoryNode(id: 40203, name: '物品交换', icon: 'swap_horiz'),
          CategoryNode(id: 40204, name: '工具借用', icon: 'hardware'),
        ],
      ),
      CategoryNode(
        id: 403,
        name: '寻物启事/失物招领',
        children: [
          CategoryNode(id: 40301, name: '寻找失物', icon: 'manage_search'),
          CategoryNode(id: 40302, name: '招领失物', icon: 'record_voice_over'),
        ],
      ),
      CategoryNode(
        id: 404,
        name: '宠物相关',
        children: [
          CategoryNode(id: 40401, name: '宠物寄养', icon: 'PAW:house'),
          CategoryNode(id: 40402, name: '宠物领养', icon: 'PAW:heart'),
          CategoryNode(id: 40403, name: '宠物用品', icon: 'PAW:bag'),
          CategoryNode(id: 40404, name: '宠物代遛', icon: 'PAW:walk'),
          CategoryNode(id: 40405, name: '宠物医疗', icon: 'PAW:cross'),
        ],
      ),
      CategoryNode(
        id: 405,
        name: '求购/求助',
        children: [
          CategoryNode(id: 40501, name: '个人求购', icon: 'shopping_cart'),
          CategoryNode(id: 40502, name: '邻里求助', icon: 'help'),
          CategoryNode(id: 40503, name: '好物推荐', icon: 'thumb_up'),
        ],
      ),
    ],
  ),

  // ── 5. 服务 SERVICE ──
  // §4.3 明写「发布服务类 5.x 叶子类目强制」个人资质，故本分支叶子全部打标。
  CategoryNode(
    id: 5,
    name: '服务',
    children: [
      CategoryNode(
        id: 501,
        name: '家政/保洁',
        children: [
          CategoryNode(
            id: 50101,
            name: '日常保洁',
            icon: 'soap',
            requiredCert: RequiredCert.personalQualification,
          ),
          CategoryNode(
            id: 50102,
            name: '深度清洁',
            icon: 'sanitizer',
            requiredCert: RequiredCert.personalQualification,
          ),
          CategoryNode(
            id: 50103,
            name: '开荒保洁',
            icon: 'BRUSH',
            requiredCert: RequiredCert.personalQualification,
          ),
          CategoryNode(
            id: 50104,
            name: '家电清洗',
            icon: 'local_laundry_service',
            requiredCert: RequiredCert.personalQualification,
          ),
          CategoryNode(
            id: 50105,
            name: '玻璃/窗户清洗',
            icon: 'SQUEEGEE',
            requiredCert: RequiredCert.personalQualification,
          ),
          CategoryNode(
            id: 50107,
            name: '保姆',
            icon: 'escalator_warning',
            requiredCert: RequiredCert.personalQualification,
          ),
          CategoryNode(
            id: 50108,
            name: '月嫂',
            icon: 'pregnant_woman',
            requiredCert: RequiredCert.personalQualification,
          ),
          CategoryNode(
            id: 50109,
            name: '钟点工',
            icon: 'av_timer',
            requiredCert: RequiredCert.personalQualification,
          ),
        ],
      ),
      CategoryNode(
        id: 502,
        name: '维修/安装',
        children: [
          CategoryNode(
            id: 50201,
            name: '家电维修',
            icon: 'FIX_APPLIANCE',
            requiredCert: RequiredCert.personalQualification,
          ),
          CategoryNode(
            id: 50202,
            name: '水电维修',
            icon: 'WATER_ELEC',
            requiredCert: RequiredCert.personalQualification,
          ),
          CategoryNode(
            id: 50203,
            name: '家具安装',
            icon: 'carpenter',
            requiredCert: RequiredCert.personalQualification,
          ),
          CategoryNode(
            id: 50204,
            name: '管道疏通',
            icon: 'plumbing',
            requiredCert: RequiredCert.personalQualification,
          ),
          CategoryNode(
            id: 50205,
            name: '开锁换锁',
            icon: 'lock_open',
            requiredCert: RequiredCert.personalQualification,
          ),
          CategoryNode(
            id: 50206,
            name: '防水补漏',
            icon: 'water_damage',
            requiredCert: RequiredCert.personalQualification,
          ),
        ],
      ),
      CategoryNode(
        id: 503,
        name: '教学/培训',
        children: [
          CategoryNode(
            id: 50301,
            name: '家教辅导',
            icon: 'menu_book',
            requiredCert: RequiredCert.personalQualification,
          ),
          CategoryNode(
            id: 50302,
            name: '技能教学',
            icon: 'cast_for_education',
            requiredCert: RequiredCert.personalQualification,
          ),
          CategoryNode(
            id: 50303,
            name: '语言培训',
            icon: 'translate',
            requiredCert: RequiredCert.personalQualification,
          ),
          CategoryNode(
            id: 50304,
            name: '艺术/乐器',
            icon: 'ART_MUSIC',
            requiredCert: RequiredCert.personalQualification,
          ),
          CategoryNode(
            id: 50305,
            name: '职业考证',
            icon: 'workspace_premium',
            requiredCert: RequiredCert.personalQualification,
          ),
          CategoryNode(
            id: 50306,
            name: '体育培训',
            icon: 'fitness_center',
            requiredCert: RequiredCert.personalQualification,
          ),
        ],
      ),
      CategoryNode(
        id: 504,
        name: '美容/美发/按摩',
        children: [
          CategoryNode(
            id: 50401,
            name: '上门美容',
            icon: 'face_retouching_natural',
            requiredCert: RequiredCert.personalQualification,
          ),
          CategoryNode(
            id: 50402,
            name: '上门按摩',
            icon: 'MASSAGE',
            requiredCert: RequiredCert.personalQualification,
          ),
          CategoryNode(
            id: 50403,
            name: '美发造型',
            icon: 'brush',
            requiredCert: RequiredCert.personalQualification,
          ),
          CategoryNode(
            id: 50404,
            name: '美甲美睫',
            icon: 'back_hand',
            requiredCert: RequiredCert.personalQualification,
          ),
          CategoryNode(
            id: 50405,
            name: '上门理发',
            icon: 'content_cut',
            requiredCert: RequiredCert.personalQualification,
          ),
          CategoryNode(
            id: 50406,
            name: '足疗/采耳',
            icon: 'healing',
            requiredCert: RequiredCert.personalQualification,
          ),
        ],
      ),
      CategoryNode(
        id: 505,
        name: '代办/跑腿',
        children: [
          CategoryNode(
            id: 50501,
            name: '代取快递',
            icon: 'markunread_mailbox',
            requiredCert: RequiredCert.personalQualification,
          ),
          CategoryNode(
            id: 50502,
            name: '代跑腿',
            icon: 'directions_walk',
            requiredCert: RequiredCert.personalQualification,
          ),
          CategoryNode(
            id: 50503,
            name: '代排队',
            icon: 'TICKET',
            requiredCert: RequiredCert.personalQualification,
          ),
          CategoryNode(
            id: 50504,
            name: '代买代送',
            icon: 'shopping_bag',
            requiredCert: RequiredCert.personalQualification,
          ),
          CategoryNode(
            id: 50505,
            name: '代办证件',
            icon: 'assignment',
            requiredCert: RequiredCert.personalQualification,
          ),
          CategoryNode(
            id: 50506,
            name: '陪诊/陪护',
            icon: 'elderly',
            requiredCert: RequiredCert.personalQualification,
          ),
        ],
      ),
    ],
  ),
];

/// 按叶子 ID 回溯面包屑（§2.6 详情页「工作 > 全职招聘 > 餐饮服务」）。
///
/// 参数 [leafId] 为 §13.2 的 `post.leaf_category_id`。
/// 参数 [tree] 为当前生效的分类树，默认取内置 [categoryTree]——已接线
/// 页面（分类选择器等）应传入分类树 Provider 的当前树（[124] B2，
/// 版本协商见 §16.4）；未接线页面沿用默认内置树，随各自条目切换。
/// 返回：一级→二级→叶子三个节点；ID 不存在时返回空列表。
///
/// 返回空而不抛异常：脏数据（如运营删了某类目而旧帖仍指向它）在生产是
/// 会发生的，页面该退化成不显示面包屑，而不是整页崩掉。
List<CategoryNode> categoryPathOf(
  int leafId, {
  List<CategoryNode> tree = categoryTree,
}) {
  final topId = leafId ~/ 10000;
  final midId = leafId ~/ 100;

  final top = tree.where((n) => n.id == topId).firstOrNull;
  if (top == null) return const [];
  final mid = top.children.where((n) => n.id == midId).firstOrNull;
  if (mid == null) return const [];
  final leaf = mid.children.where((n) => n.id == leafId).firstOrNull;
  if (leaf == null) return const [];

  return [top, mid, leaf];
}

/// 面包屑文案（如「工作 > 全职招聘 > 餐饮服务」）。
///
/// 参数 [leafId] 叶子 ID；[tree] 同 [categoryPathOf]（默认内置树）。
/// 返回拼好的路径；ID 不存在时返回 null。
///
/// **为什么要有这个函数而不是各处自己 join**：AI 猜测生成的分类值与
/// §5.10 Step 4 的逆向比对必须用**同一拼法** —— 分隔符或取名方式散在两处时，
/// 改一处就会让校验把自己刚生成的合法值判成非法（本函数落地前，
/// 两处写的是 `categoryPathOf(id).join(' > ')`，拼出的是对象的 toString）。
String? categoryPathLabel(int leafId, {List<CategoryNode> tree = categoryTree}) {
  final path = categoryPathOf(leafId, tree: tree);
  return path.isEmpty ? null : path.map((n) => n.name).join(' > ');
}

/// 全量叶子类目（模板绑定与「不超过 120 个」上限校验的依据，§2.3）。
List<CategoryNode> get leafCategories => [
  for (final top in categoryTree)
    for (final mid in top.children) ...mid.children,
];

/// 按叶子 ID 取节点。不存在返回 null（同 [categoryPathOf] 的容错取向）。
CategoryNode? leafCategoryById(int leafId) =>
    categoryPathOf(leafId).lastOrNull;

/// 叶子的原始资质标记（§4.3 认证类型表 / §2.9 高敏标记），供与认证拦截
/// 无关的维度使用 —— 当前唯一消费方是 §5.10 AI 配额「高敏类目 +10」分层。
///
/// 与 `requiredCertForLeaf`（publish_template.dart）的分工：后者是发布前
/// 拦截判定，2026-11-01 起恒 `none`（0d9a2d5 取消发布链路认证要求）；
/// 本函数读内置常量树的原始映射，不受该裁定影响 —— 配额分层是额度规则，
/// 不是拦截，高敏类目耗费更多模型审查资源的事实不因取消拦截而改变。
///
/// 参数 [leafId] 叶子类目 ID。
/// 返回：[RequiredCert] 原始标记；ID 不存在返回 `none`（同 [categoryPathOf]
///   的容错取向，分类树版本落后是 §16.4 预期内状态）。
RequiredCert rawRequiredCertOfLeaf(int leafId) =>
    leafCategoryById(leafId)?.requiredCert ?? RequiredCert.none;
