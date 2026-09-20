---
title: 注入凭证与作废凭证分属不同平台：挂账摘要会混淆处置对象，必须回读检出原文
date: 2026-09-09
category: workflow-issues
module: deploy
problem_type: workflow_issue
component: documentation
severity: high
root_cause: missing_validation
resolution_type: workflow_improvement
applies_when:
  - 向 .env 注入密钥或凭证前，需要区分「本次注入对象」与「历史泄露待作废对象」
  - 进度文档或挂账摘要中出现「某平台 key 作废」类待办，准备据以执行处置动作
  - G-Q2 密钥扫描等安全检出需要到对应供应商控制台作废凭证
  - 摘要性文字（挂账、纪要、转述）驱动不可逆操作（作废、删除、替换密钥）
  - 项目并存多个供应商多套密钥（阿里云 OSS、高德、火山方舟），处置对象与操作平台为多对多关系
tags: [secrets-management, credential-rotation, env-injection, g-q2-secret-scan, source-verification, ledger-summary, revocation-workflow, misattribution]
---

# 注入凭证与作废凭证分属不同平台：挂账摘要会混淆处置对象，必须回读检出原文

## Context

项目 s2s 的「注入阿里云密钥到 .env」工作流中存在一条事实纠偏链。进度文档条目 [120] 的「并行行政项提示」写有一句挂账摘要：「**阿里云泄露两把 key 控制台作废** + 新密钥注入 `.env` 阻塞 [121] 配置填充」（说明文档.md:4411）。但回读条目 [115] 原文实测：G-Q2 密钥扫描真实检出的是 `prototype/` 早期 HTML/JS 原型中硬编码的 **2 把真实形态 key——高德 Web Key 1 把、火山方舟 sk- key 1 把**，且这 4 处在此前已随 git 历史存在（说明文档.md:4386）；豁免册 remediation 写明的唯一彻底处置是**到高德/火山控制台作废更换**（行政动作，已在说明文档.md:4389 长期挂账）——**没有任何一把属于阿里云**。

而本次实际要注入的才是**阿里云 OSS 的 AK/SK**（媒体直传用）：变量 `OSS_ACCESS_KEY_ID` / `OSS_ACCESS_KEY_SECRET`，落 `deploy/env/.env.dev`，模板占位见 deploy/env/.env.dev.example:43-47；dev 是否真调 OSS 由 deploy/config/app/application-dev.yml:67-71 的 `s2s.oss.enabled` 控制（2026-09-09 起已为 `true`，注释注明「直传到 s2s-bucket 真测媒体链路」）。

混淆点：「注入对象（阿里云 OSS）」与「作废对象（高德/火山，控制台非阿里云）」被一句含混的挂账摘要绑定在一起。若凭摘要记忆操作，会拿阿里云 key 去走「作废」流程，或以为要作废的是阿里云 key——两类对象、两个控制台、两套处置全错位。

## Guidance

- **凭证类挂账一律回原文核对 provider 与控制台归属，不凭摘要记忆行动。** 摘要里出现「<云厂商>泄露 key 作废」字样时，先回检出条目原文（本例为说明文档.md:4386）确认三件事：key 的 provider 是谁、泄在哪个文件/目录、对应哪个控制台。
- **「注入新凭证」与「作废旧泄露凭证」拆成两个独立动作、分开记账。** 本例中两者分属不同 provider、零依赖：注入的是阿里云新 OSS 凭证（此前从未入库）；作废的是高德/火山已泄露凭证（删代码不等于撤销泄露，key 已在 git 历史中）。不要把它们写进同一句话，更不要理解为「同一凭证的先作废再注入」。
- **作废动作执行前再核一遍控制台归属**：高德 key → 高德开放平台控制台；火山方舟 sk- key → 火山引擎控制台。阿里云控制台在本案中只涉及「创建/管理新 OSS 凭证」，无任何作废任务。
- **注入侧安全边界已固化，直接遵循**：.gitignore:62-63 用 `deploy/env/.env*` 通配忽略 + `!deploy/env/.env*.example` 放行模板（注释明确顺序不可颠倒，gitignore 后规则覆盖前规则）；deploy/config/app/application-dev.yml:13-16 纪律「本文件入 git，禁止出现任何密钥，敏感值一律走 `${ENV_VAR}` 占位，实际值由 deploy/env/.env.dev 注入」。
- **凭证相关文字一律只用变量名/掩码，绝不落真实 AK/SK 值**——本条对本学习文档自身同样适用（正文只出现变量名与模板文件名）。

## Why This Matters

凭挂账摘要记忆操作有两个错位后果，且凭证作废是**不可逆行政动作**（作废即生效、不可撤回），对象搞错没有 undo：

1. **防御动作打在健康凭证上，真泄露面原样暴露。** 若按摘要以为要作废的是阿里云 key，就会到阿里云控制台把正要注入使用的 OSS AK/SK 作废轮换——媒体直传链路（application-dev.yml:68 注明的真测对象）当场中断，[121] 配置填充反被自己的「处置」阻塞；而 git 历史里真正泄露的高德/火山 key 继续有效，泄露零收敛。
2. **两个独立动作被搅成一件事。** 摘要把「作废旧 key」与「注入新 key」并列成一条阻塞项，容易诱导出「先作废再注入」的单凭证替换流程理解。实际上说明文档.md:4386 写得很清楚：「key 已在历史中，删代码不等于撤销泄露……唯一彻底处置是到高德/火山控制台作废更换」——作废对象与注入对象从检出那一刻起就是两组凭证。

这正是 G-Q2 纪律「凭据进 git 历史即泄露，唯一处置是控制台作废换密钥」的执行前提：**先确证「作废哪一把」，再谈作废**。摘要省略归属，原文才有归属。

## When to Apply

- 进度文档/待办中出现「<厂商> key 泄露作废」类挂账摘要，准备执行作废或注入凭证时。
- 同一轮工作里同时存在「注入新凭证」与「作废旧凭证」两类动作，且摘要把它们写在同一句话里时。
- 任何凭证类不可逆操作（控制台作废、轮换、降权）执行前——先回检出条目/扫描记录原文核对 provider、泄露位置、控制台归属三元组。
- 反向适用——撰写凭证相关挂账摘要时：必须写明 provider + 文件位置 + 目标控制台，禁写「<某云>泄露 N 把」这类省略归属的含混句式（本例的混淆正是这样被制造出来的）。

## Examples

**Before（凭挂账摘要行动，险些作废错对象）**

读条目 [120] 提示「阿里云泄露两把 key 控制台作废 + 新密钥注入 `.env`」，直接理解为「要作废阿里云的两把 key，然后把阿里云 key 注入 .env」。带着这个理解去阿里云控制台，把刚申请下来、正要填入 `OSS_ACCESS_KEY_ID` / `OSS_ACCESS_KEY_SECRET` 的 OSS AK/SK 作废轮换——媒体直传链路随即鉴权失败，`s2s.oss.enabled: true` 的 dev 真测被自己的处置打断；与此同时，git 历史里真正泄露的高德 Web Key 与火山方舟 sk- key 继续有效，泄露面零收敛。

**After（回原文核对 provider 与控制台，分对象处置）**

1. 回读条目 [115] 原文（说明文档.md:4386），确认检出事实：泄露 2 把 = 高德 Web Key ×1 + 火山方舟 sk- key ×1，位于 `prototype/`，已入 git 历史；与阿里云无关。
2. 拆成两个独立动作，各自对号入座：
   - **作废（对象：高德/火山旧凭证）**：高德 key → 高德开放平台控制台作废换新；火山方舟 key → 火山引擎控制台作废换新（用户侧行政动作，说明文档.md:4389 已挂账；作废后须替换占位符并删除豁免登记条目，双向核对测试会逼出这一步）。
   - **注入（对象：阿里云 OSS 新凭证）**：往 deploy/env/.env.dev 填 `OSS_ACCESS_KEY_ID` / `OSS_ACCESS_KEY_SECRET`（模板见 deploy/env/.env.dev.example:45-46），.gitignore:62-63 保证该文件不入库；与作废动作无任何依赖，先后随意。
3. 结果：两条动作的「对象—控制台—凭证」三元组全部正确归位；阿里云控制台在本案中只承担「创建/管理新 OSS 凭证」，无任何作废任务。

## Related

- [评审结论的实测核验](review-findings-require-empirical-verification.md)：姊妹篇——不凭二手结论（评审断言/挂账摘要）直接行动，先实证核验再执行处置；本篇覆盖凭证作废对象核对场景。
- [破坏性脚本参数尽调](destructive-script-parameter-audit.md)：不可逆/破坏性操作前必须对「作用对象」做尽调——参数/对象就是写入授权。
- [跨文档引用核对](cross-document-reference-verification.md)：摘要/搬运文本会掩盖事实差别，须回权威原文逐字核对。
- [fail-closed-gate-judgments-with-mutation-self-checks.md](fail-closed-gate-judgments-with-mutation-self-checks.md)：同一 G-Q2 密钥检出事件的另一侧面——本篇讲处置对象张冠李戴的纠正，该篇讲检出判据在合并态的活体验证（实证守门读工作区而非 git 索引），闭合「检出→处置」链。
