/// 发布模板装配（[124] B3）：`GET /templates/{leaf}` 字段与本地模板合成。
///
/// **为什么字段以服务端为真源、框架文案以本地为真源**：契约 `Template`
/// 只下发 `fields`（key/label/type/required/options/unit/placeholder），
/// 且 `required` 标记兼 `post.attributes` 完整度 `required_full` 的判定
/// 依据 —— 判定口径必须由服务端独持，客户端本地四模板只是同源副本。
/// 而标题提示 / 价格单位 / 描述引导三项契约没有，只能恒取本地。
///
/// **失败降级而非阻断**：拉取失败（含信封业务错误与传输侧错误两形态）
/// 返回本地模板 —— 发布链路不被模板接口单点拖死，服务端 precheck
/// （B4 接线）才是字段口径的最终兜底。降级不区分错误码：任何失败后的
/// 行为一致，用户不可感知。
///
/// **family 即缓存**：键为叶子类目 ID，同一容器内同叶子只拉一次。模板
/// 与分类树同属低频变更数据；树版本换代引起的模板失效本轮不联动
/// （树刷新在 B2，模板缓存在本文件，两侧均无跨域通知通道，列入边界）。
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhaoyazhao/core/network/api_exception.dart';

import '../../domain/publish_template.dart';
import '../category/category_dto.dart';
import '../category/category_repository.dart';

/// 按叶子类目拉取并合成发布模板。
///
/// 数据到达后由发布页回写 `PublishFormState.loadedTemplate`（页面
/// `ref.watch` + 帧后回写：WidgetRef.listen 无 fireImmediately，family
/// 缓存命中时不再有「下一次变化」，必须在 build 里核对当前值）。
///
/// 参数 [leafCategoryId] 叶子类目 ID（family 键）。
/// 返回：服务端字段 + 本地框架文案的合成模板；拉取失败为本地模板。
final publishTemplateProvider =
    FutureProvider.family<PublishTemplate, int>((ref, leafCategoryId) async {
      final local = templateForLeaf(leafCategoryId);
      try {
        final dto = await ref
            .watch(categoryRepositoryProvider)
            .fetchTemplate(leafCategoryId);
        return local.withExtraFields([
          for (final field in dto.fields) templateFieldSpecFromDto(field),
        ]);
      } on ApiException {
        // 信封业务错误 / 解析失败（含 40001 脏 ID）：降级本地模板。
        return local;
      } on DioException catch (e) {
        // 传输侧错误（链上形态为 DioException 包 ApiException，如 5xx
        // 归一 networkFailure 重试耗尽后）：同样降级。非 ApiException
        // 的 DioException 不在链上契约内，向外抛出让测试暴露。
        if (e.error is ApiException) return local;
        rethrow;
      }
    });

/// 契约模板字段 → 本地字段 spec 的映射（唯一实现处，编码规范 §1.1）。
///
/// 参数 [dto] `TemplateField` DTO（解析校验已在 DTO 层完成）。
/// 返回：[TemplateFieldSpec]。两轮降级的分工：`type` 未知字符串已在
/// DTO 层降级 [TemplateFieldTypeDto.text]；这里是控件能力维度的第二轮
/// —— 本地无多选与日期控件，multi_select 降级单选（值仍落单一字符串键），
/// date 降级文本输入，两处降级语义不同，不合并。
///
/// `unit`（如「吨」）不落 spec：本地 spec 无单位位，发布页暂无单位渲染
/// 位，且 B5 提交 `template_values` 用不到它。
TemplateFieldSpec templateFieldSpecFromDto(TemplateFieldDto dto) {
  return TemplateFieldSpec(
    key: dto.key,
    label: dto.label,
    type: switch (dto.type) {
      TemplateFieldTypeDto.text => TemplateFieldType.text,
      TemplateFieldTypeDto.number => TemplateFieldType.number,
      TemplateFieldTypeDto.select => TemplateFieldType.select,
      TemplateFieldTypeDto.multiSelect => TemplateFieldType.select,
      TemplateFieldTypeDto.date => TemplateFieldType.text,
    },
    placeholder: dto.placeholder,
    required: dto.isRequired,
    options: dto.options ?? const [],
  );
}
