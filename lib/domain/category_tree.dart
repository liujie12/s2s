/// 三级分类树（PRD §2.4 首期建议树 / §2.9 实现逻辑 / §12.3 `/categories/tree`）。
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
library;

import 'listing_category.dart';

/// 分类树版本号（§2.9「版本号 + 本地缓存」，§12.3 `/categories/tree` 的 `version` 入参）。
///
/// 现为编译期常量，接后端后改为「本地缓存值 + 服务端下发值比对」：
/// 版本未变则服务端返回 `code=0,data=null`（§12.3），客户端继续用缓存。
/// TODO(M5)：改为可持久化字段，接 `GET /categories/tree`。
const String categoryTreeVersion = '2026-08-31.1';

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

  /// 子节点。叶子为空列表。
  final List<CategoryNode> children;

  /// 发布本类目所需认证。仅叶子有意义（§2.9「在分类树上加标记」）。
  final RequiredCert requiredCert;

  /// 是否叶子类目（能绑定模板、能被发布选中的那一层）。
  bool get isLeaf => children.isEmpty;

  /// 所属一级大类 —— 决定大类色（§2 末条「1 个大类色」）。
  ///
  /// 由 id 首位推导而非另存字段：另存等于同一事实有两份记录，
  /// 挪动节点时漏改一处就会出现「在房屋分支下显示蓝色」这类错。
  ListingCategory get topCategory {
    final top = id >= 10000
        ? id ~/ 10000
        : id >= 100
        ? id ~/ 100
        : id;
    return ListingCategory.values[top - 1];
  }
}

/// 全量分类树（§2.4 逐字建模，5 一级 / 21 二级 / 48 叶子）。
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
            requiredCert: RequiredCert.enterprise,
          ),
          CategoryNode(
            id: 10102,
            name: '零售导购',
            requiredCert: RequiredCert.enterprise,
          ),
          CategoryNode(
            id: 10103,
            name: '家政保洁',
            requiredCert: RequiredCert.enterprise,
          ),
          CategoryNode(
            id: 10104,
            name: '保安仓管',
            requiredCert: RequiredCert.enterprise,
          ),
          CategoryNode(
            id: 10105,
            name: '其他全职',
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
            requiredCert: RequiredCert.enterprise,
          ),
          CategoryNode(
            id: 10202,
            name: '周末兼职',
            requiredCert: RequiredCert.enterprise,
          ),
          CategoryNode(
            id: 10203,
            name: '小时工',
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
          CategoryNode(id: 10301, name: '个人求职'),
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
            requiredCert: RequiredCert.enterprise,
          ),
          CategoryNode(
            id: 20102,
            name: '次卧出租',
            requiredCert: RequiredCert.enterprise,
          ),
          CategoryNode(
            id: 20103,
            name: '整租出租',
            requiredCert: RequiredCert.enterprise,
          ),
        ],
      ),
      CategoryNode(
        id: 202,
        name: '求租/找房',
        // 求租方不发布房源，不适用房源认证。
        children: [CategoryNode(id: 20201, name: '个人求租')],
      ),
      CategoryNode(
        id: 203,
        name: '短租/日租',
        children: [
          CategoryNode(
            id: 20301,
            name: '短租民宿',
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
            requiredCert: RequiredCert.vehicle,
          ),
          CategoryNode(
            id: 30102,
            name: '跨城顺风车',
            requiredCert: RequiredCert.vehicle,
          ),
          CategoryNode(
            id: 30103,
            name: '周末拼车',
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
            requiredCert: RequiredCert.vehicle,
          ),
          CategoryNode(
            id: 30202,
            name: '货车出租',
            requiredCert: RequiredCert.vehicle,
          ),
        ],
      ),
      CategoryNode(
        id: 303,
        name: '二手车转让',
        // 转让是一次性买卖，§4.3 只对「拼车/租车」强制车辆认证，
        // 不擅自扩大到转让 —— 扩大范围等于我替产品改了准入门槛。
        children: [CategoryNode(id: 30301, name: '个人二手车')],
      ),
      CategoryNode(
        id: 304,
        name: '求搭车/求拼',
        // 求搭车方没有车，要求行驶证会是一道无法满足的门。
        children: [CategoryNode(id: 30401, name: '个人求搭车')],
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
          CategoryNode(id: 40101, name: '家具家电'),
          CategoryNode(id: 40102, name: '母婴儿童'),
          CategoryNode(id: 40103, name: '数码电子'),
          CategoryNode(id: 40104, name: '服饰鞋包'),
          CategoryNode(id: 40105, name: '其他二手'),
        ],
      ),
      CategoryNode(
        id: 402,
        name: '借物/互助',
        children: [
          CategoryNode(id: 40201, name: '临时借物'),
          CategoryNode(id: 40202, name: '邻里互助'),
          CategoryNode(id: 40203, name: '物品交换'),
        ],
      ),
      CategoryNode(
        id: 403,
        name: '寻物启事/失物招领',
        children: [
          CategoryNode(id: 40301, name: '寻找失物'),
          CategoryNode(id: 40302, name: '招领失物'),
        ],
      ),
      CategoryNode(
        id: 404,
        name: '宠物相关',
        children: [
          CategoryNode(id: 40401, name: '宠物寄养'),
          CategoryNode(id: 40402, name: '宠物领养'),
        ],
      ),
      CategoryNode(
        id: 405,
        name: '求购/求助',
        children: [
          CategoryNode(id: 40501, name: '个人求购'),
          CategoryNode(id: 40502, name: '邻里求助'),
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
            requiredCert: RequiredCert.personalQualification,
          ),
          CategoryNode(
            id: 50102,
            name: '深度清洁',
            requiredCert: RequiredCert.personalQualification,
          ),
          CategoryNode(
            id: 50103,
            name: '开荒保洁',
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
            requiredCert: RequiredCert.personalQualification,
          ),
          CategoryNode(
            id: 50202,
            name: '水电维修',
            requiredCert: RequiredCert.personalQualification,
          ),
          CategoryNode(
            id: 50203,
            name: '家具安装',
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
            requiredCert: RequiredCert.personalQualification,
          ),
          CategoryNode(
            id: 50302,
            name: '技能教学',
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
            requiredCert: RequiredCert.personalQualification,
          ),
          CategoryNode(
            id: 50402,
            name: '上门按摩',
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
            requiredCert: RequiredCert.personalQualification,
          ),
          CategoryNode(
            id: 50502,
            name: '代跑腿',
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
/// 返回：一级→二级→叶子三个节点；ID 不存在时返回空列表。
///
/// 返回空而不抛异常：脏数据（如运营删了某类目而旧帖仍指向它）在生产是
/// 会发生的，页面该退化成不显示面包屑，而不是整页崩掉。
List<CategoryNode> categoryPathOf(int leafId) {
  final topId = leafId ~/ 10000;
  final midId = leafId ~/ 100;

  final top = categoryTree.where((n) => n.id == topId).firstOrNull;
  if (top == null) return const [];
  final mid = top.children.where((n) => n.id == midId).firstOrNull;
  if (mid == null) return const [];
  final leaf = mid.children.where((n) => n.id == leafId).firstOrNull;
  if (leaf == null) return const [];

  return [top, mid, leaf];
}

/// 全量叶子类目（模板绑定与「不超过 60 个」上限校验的依据，§2.3）。
List<CategoryNode> get leafCategories => [
  for (final top in categoryTree)
    for (final mid in top.children) ...mid.children,
];

/// 按叶子 ID 取节点。不存在返回 null（同 [categoryPathOf] 的容错取向）。
CategoryNode? leafCategoryById(int leafId) =>
    categoryPathOf(leafId).lastOrNull;
