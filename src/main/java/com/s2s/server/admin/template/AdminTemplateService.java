package com.s2s.server.admin.template;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.s2s.server.admin.dto.AdminTemplateResponse;
import com.s2s.server.admin.dto.AdminTemplateSaveRequest;
import com.s2s.server.category.TemplateService;
import com.s2s.server.category.entity.TemplateEntity;
import com.s2s.server.common.audit.AuditEntry;
import com.s2s.server.common.audit.AuditLogWriter;
import com.s2s.server.common.audit.OperatorRole;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * 后台模板 Schema 编辑器服务（[153] B2-5 ②；PRD §9.10.1 ②）。
 *
 * <p><b>RBAC</b>：模板配置属「运营专员」职责——运营专员与超级管理员可操作，
 * 其余角色一律 {@code 40305}。</p>
 *
 * <p><b>粒度</b>：本工程模板按 <b>L2 父级</b> 存储（{@code template.leaf_category_id}
 * 存 L2 ID，同 L2 下所有叶子共享），故 {@code templateKey} 实为 L2 类目 ID
 * ——与 {@code TemplateService} 的查找口径一致（{@code leafCategoryId ~/ 100} 的镜像）。</p>
 *
 * <p><b>审计</b>：模板保存（新版本）属「必留操作」，写库与审计<b>同事务</b>，
 * 审计记录新版本号。</p>
 */
@Service
public class AdminTemplateService {

    /** 审计动作：保存模板新版本。 */
    static final String ACTION_TEMPLATE_SAVE = "template.save";

    /** 审计目标类型：模板。 */
    static final String TARGET_TEMPLATE = "template";

    /** 模板服务（category 域 service 接口）。 */
    private final TemplateService templateService;

    /** 审计写入器（唯一写入处）。 */
    private final AuditLogWriter auditLogWriter;

    /** JSON 序列化器（把入参 JsonNode 存为 fields 原文）。 */
    private final ObjectMapper objectMapper;

    /**
     * 构造后台模板服务。
     *
     * @param templateService category 域模板服务
     * @param auditLogWriter  审计写入器
     * @param objectMapper    JSON 序列化器
     */
    public AdminTemplateService(TemplateService templateService, AuditLogWriter auditLogWriter,
            ObjectMapper objectMapper) {
        this.templateService = templateService;
        this.auditLogWriter = auditLogWriter;
        this.objectMapper = objectMapper;
    }

    /**
     * 读取模板（后台编辑页）。
     *
     * @param callerRole  调用者角色
     * @param templateKey 模板键（L2 类目 ID）
     * @return {@link AdminTemplateResponse} 版本号 + Schema；无自定义模板时 version=0、fields=null
     * @throws BizException 非运营专员/超管 → 40305
     */
    public AdminTemplateResponse get(OperatorRole callerRole, int templateKey) {
        requireOperatorOrSuper(callerRole);
        TemplateEntity entity = templateService.findRawForAdmin(templateKey);
        if (entity == null) {
            return new AdminTemplateResponse(templateKey, 0, null);
        }
        JsonNode fields;
        try {
            fields = objectMapper.readTree(entity.getFields());
        } catch (Exception e) {
            // 库里脏 JSON：返回 null 让前端走通用模板，而不是让编辑页报错
            fields = null;
        }
        return new AdminTemplateResponse(templateKey,
                entity.getTemplateVersion() == null ? 0 : entity.getTemplateVersion(), fields);
    }

    /**
     * 保存模板新版本（版本号 +1，立即生效；同事务写审计）。
     *
     * @param callerRole  调用者角色
     * @param adminId     操作人 ID（审计）
     * @param templateKey 模板键（L2 类目 ID）
     * @param req         入参（fields 必须为非空数组）
     * @throws BizException 非运营专员/超管 → 40305；Schema 非法 → 40001
     */
    @Transactional
    public void save(OperatorRole callerRole, Long adminId, int templateKey,
            AdminTemplateSaveRequest req) {
        requireOperatorOrSuper(callerRole);
        String fieldsJson;
        try {
            fieldsJson = objectMapper.writeValueAsString(req.fields());
        } catch (Exception e) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
        int nextVersion = templateService.saveForAdmin(templateKey, fieldsJson);
        auditLogWriter.write(new AuditEntry(adminId, callerRole, ACTION_TEMPLATE_SAVE,
                TARGET_TEMPLATE, (long) templateKey, null,
                String.format("{\"templateVersion\":%d}", nextVersion), null));
    }

    /**
     * RBAC：运营专员或超级管理员。
     *
     * @param callerRole 调用者角色
     * @throws BizException 不满足 → 40305
     */
    private void requireOperatorOrSuper(OperatorRole callerRole) {
        if (callerRole != OperatorRole.OPERATOR && callerRole != OperatorRole.SUPER_ADMIN) {
            throw BizException.of(ErrorCode.NO_PERMISSION);
        }
    }
}
