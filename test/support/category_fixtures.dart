/// category 域公共测试夹具（[124] 前端段 / B2、B3 提取）。
///
/// 原为 category_repository_test.dart 的私有 fixture，provider 层测试出现
/// 第二处需求后按反冗余纪律（编码规范 §1.1）上浮为唯一实现处：
///   - [serverCategoryTreePayload] / [stubCategoryTree]：线上树与版本协商桩；
///   - [cachedCategoryTreePayload] / [kCachedTreeVersion]：本地缓存旧树，
///     内容与线上树刻意不同，便于用例凭叶子 id 判断 state 数据来源；
///   - [serverTemplatePayload] / [stubTemplate]：叶子发布模板桩（B3）。
/// post 域桩见 post_fixtures.dart（域与文件对应，不混装）。
library;

import 'api_envelope.dart';
import 'mock_api_server.dart';
import 'network_chain_harness.dart';

/// mock 服务端分类树版本（夹具唯一字面量处，改版本只动这里）。
const String kServerTreeVersion = '2026-09-14.1';

/// 本地缓存分类树版本（落后于服务端，与 [kServerTreeVersion] 故意不同）。
const String kCachedTreeVersion = '2026-09-01.1';

/// 构造三级分类树响应 data（含 sensitive/banned/icon 三种可选标记的
/// 出现与缺失两种形态）。
///
/// 参数：[version] 版本号。
/// 返回：[Map] 契约 `CategoryTree` 形态的 data 对象。
Map<String, Object?> serverCategoryTreePayload({
  String version = kServerTreeVersion,
}) =>
    {
      'version': version,
      'categories': [
        {
          'id': 1,
          'name': '工作',
          'level': 1,
          'children': [
            {
              'id': 101,
              'name': '全职招聘',
              'level': 2,
              'children': [
                {
                  'id': 10101,
                  'name': '餐饮服务',
                  'level': 3,
                  'sensitive': true,
                  'banned': false,
                  'icon': null,
                },
                {'id': 10102, 'name': '零售导购', 'level': 3},
              ],
            },
          ],
        },
      ],
    };

/// 构造本地缓存分类树 data：生活 > 二手闲置转让 > [家具家电] 单分支。
///
/// 内容与线上树（[serverCategoryTreePayload]）刻意不同：用例可凭叶子 id
/// （40101 vs 10101）判断渲染的是缓存树还是线上树；40101 在内置常量树中
/// 未显式声明 requiredCert，顺带覆盖「映射回退 none」路径。
///
/// 返回：[Map] 契约 `CategoryTree` 形态的 data 对象。
Map<String, Object?> cachedCategoryTreePayload() => {
      'version': kCachedTreeVersion,
      'categories': [
        {
          'id': 4,
          'name': '生活',
          'level': 1,
          'children': [
            {
              'id': 401,
              'name': '二手闲置转让',
              'level': 2,
              'children': [
                {'id': 40101, 'name': '家具家电', 'level': 3},
              ],
            },
          ],
        },
      ],
    };

/// 登记 `/categories/tree` 版本协商桩：query version 与服务端一致回
/// `data=null`（304 语义），否则回全量树；无 version 参数回全量树。
///
/// 参数：[harness] 网络链 harness；[serverVersion] 服务端当前版本。
/// 返回：void。
void stubCategoryTree(
  NetworkChainHarness harness, {
  String serverVersion = kServerTreeVersion,
}) {
  harness.stub('GET', '/api/v1/categories/tree', (req) async {
    final queryVersion = Uri.parse(req.path).queryParameters['version'];
    if (queryVersion != null && queryVersion == serverVersion) {
      return MockResponse(body: ApiEnvelope.success(data: null));
    }
    return MockResponse(
      body: ApiEnvelope.success(
        data: serverCategoryTreePayload(version: serverVersion),
      ),
    );
  });
}

/// 构造叶子类目发布模板响应 data（契约 `Template`：required =
/// leaf_category_id/fields）。
///
/// 默认字段集与 B1 repository 用例逐字一致（number 必填 + select 非必填、
/// 可选键 `unit` 显式 JSON null 形态），B3 provider 用例可传 [fields]
/// 覆盖为任意字段集。
///
/// 参数：[leafCategoryId] 叶子 ID；[fields] 契约 `TemplateField` 形态
///   列表，null 用默认两字段。
/// 返回：[Map] 契约 `Template` 形态的 data 对象。
Map<String, Object?> serverTemplatePayload({
  int leafCategoryId = 10101,
  List<Map<String, Object?>>? fields,
}) => {
  'leaf_category_id': leafCategoryId,
  'fields':
      fields ??
      [
        {
          'key': 'headcount',
          'label': '招聘人数',
          'type': 'number',
          'required': true,
          'placeholder': '如：3',
        },
        {
          'key': 'board',
          'label': '食宿情况',
          'type': 'select',
          'required': false,
          'options': ['包吃包住', '包吃不包住', '不包吃住'],
          'unit': null,
        },
      ],
};

/// 登记 `/templates/{leaf}` 模板桩：恒回 200 + 模板信封。
///
/// 参数：[harness] 网络链 harness；[leafCategoryId] 路径中的叶子 ID；
///   [fields] 透传 [serverTemplatePayload]，null 用默认字段集。
/// 返回：void。
void stubTemplate(
  NetworkChainHarness harness, {
  int leafCategoryId = 10101,
  List<Map<String, Object?>>? fields,
}) {
  harness.stub('GET', '/api/v1/templates/$leafCategoryId', (req) async {
    return MockResponse(
      body: ApiEnvelope.success(
        data: serverTemplatePayload(
          leafCategoryId: leafCategoryId,
          fields: fields,
        ),
      ),
    );
  });
}
