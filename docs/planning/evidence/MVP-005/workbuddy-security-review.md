# MVP-005 安全复核报告 — WorkBuddy（Kimi K3）第三方独立复核

> 复核人：WorkBuddy + Kimi K3｜日期：2026-09-29
> 复核对象：HEAD `a22d279`（= 交付提交 `aa3d7fa` + Hermes 签核仅改 result.md 签核区，`git diff aa3d7fa..a22d279 --stat` 实证代码零变更）
> 纪律：不采信 Trae/Hermes 结论，全部探针自跑；fixture 前缀 `wb-s05:`；SQL 探针单 DO 块 + RAISE 强制回滚；凭据 keychain 注入进程 env，不落盘不打印；本文所有 key/token/密码值 [REDACTED]，owner uuid 仅留前 8 位 `0c645909…`。

---

## §0 结论：**PASS**

三线全绿，未发现 P0/P1/P2。NEW-FINDING 三条均为 P3 行为边界注记（详见 §2），不构成阻塞。与 Trae/Hermes 结论零实质偏差（§3）。真库零残留已自查（§4）。

---

## §1 三线证据表

### 线 A：无凭据红线

| 项 | 方法 | 期望 | 实测（自跑输出摘要） | 判定 |
|---|---|---|---|---|
| A1a `credentials` 列探测 | DO 块 `set role authenticated` + owner claims，`perform credentials from export_agent_clients_v1` | 42703 列不存在 | HTTP 400 `WB_S05_LINEA_PROOF: A1a_credentials_42703: pass` | PASS |
| A1b `locator` 列探测 | 同上 | 42703 | `A1b_locator_42703: pass` | PASS |
| A1c `credentials_hash` 补探 | 同上 | 42703 | `A1c_credentials_hash_42703: pass` | PASS |
| A1d 封闭视图 advice | authenticated 读 `export_agent_advice_v1` | 42501 零授权 | `A1d_agent_advice_42501: pass` | PASS |
| A1e 封闭视图 rules | authenticated 读 `export_automation_rules_v1` | 42501 | `A1e_automation_rules_42501: pass` | PASS |
| A1f anon 补刀（自加） | `set role anon` 读 `export_life_data_v1` | 42501（合同 S01） | `A1f_anon_life_data_42501: pass` | PASS |
| A1g 视图列清单对账 | `information_schema.columns` 实拉 7 个 `export_*_v1` 视图 | 与 C-08 白名单/0004 逐列一致 | 7 视图 58 列逐一比对：agent_clients 恰 11 列（id/user_id/name/type/scopes/enabled/created_at/updated_at/last_seen_at/revoked_at/version），无 credentials/locator/hash；其余 6 视图与 0004 migration 逐列相等，多一列少一列均无 | PASS |
| A2 scanValue 压力测 | Node vm 沙箱加载发行 `assets/js/export.js`，`_internals.scanValue`，16 变体 | 攻击变体全命中、正常数据不误伤 | **16/16 ALL_PASS**：大写 `API_KEY`/`CREDENTIAL` 命中、`api-key`/`api_key` 命中、嵌套数组内 `token` 命中、JWT(`eyJ…`)/`sb_secret_`/`sk-`/`sb_publishable_` 形态值全命中、深层混合双命中；`request_id`/数字/布尔/null/短 eyJ 不误伤；`tokenized` 命中（与 Hermes 记录一致的已知行为） | PASS |
| A2b `EyJ` 大小写边界 | 同上 V11/V12 | 如实记录行为边界 | `EyJ…`（大小写混合）hits=0 不命中；非开头 eyJ 不命中（`^` 锚定）→ 记 P3 注记（§2 F1），非缺陷 | PASS（注记） |
| A2c 样本独立扫描 | 自写扫描器（迭代遍历+独立正则集，**不 import export.js**）扫 `sample-export.json` 122 节点 | 零命中；无真实 owner uuid 全文；无 `sb_publishable_` 值 | 8/8 PASS：敏感键/值零命中；`0c645909-ebb5-4910-ab99-4f7b238c9529` 不在文件；owner_id 为合成 `00000000-0000-…`；`"9007199254740993"` 字符串保真在包；容器七键齐 | PASS |
| A3 dist 产物扫描 | 对 `dist/index.html`（342161 B）扫 `sb_secret_`/`sb_publishable_值`/真实三段 JWT/`service_role`/`password:"值"`/硬编码 supabase URL | 真实硬编码值零命中 | 精确扫描（区分真实值与正则字面量）**全 0 命中**；初筛 6 处命中逐个人工核对：4 处为 minified supabase-js SDK 内部码/config.js 密钥格式正则与注释、2 处为 `signInWithPassword({password: 变量})` 变量引用——均非凭据值。publishable key 运行时来自 localStorage/URL 参数注入（P0-006 设计），dist 无硬编码 | PASS |

### 线 B：一致性快照语义（`wb-s05:` 前缀，事务回滚）

| 项 | 方法 | 期望 | 实测（自跑输出摘要） | 判定 |
|---|---|---|---|---|
| S1a INSERT bump | 事务内插 `wb-s05:s1-insert`，前后读 `workspace_state.data_revision` | bump 2（audit 直接 +1，audit 行进 activity_log 再 +1） | `S1a_insert_bump2: pass, delta=2` | PASS |
| S1b UPDATE bump | 改同一行 payload | ≥1 | `S1b_update_bump: pass, delta=2`（与 INSERT 同路径） | PASS |
| S1c softdelete bump | `deleted_at=now()` | ≥1 | `S1c_softdelete_bump: pass, delta=2` | PASS |
| S1d last_seen bump | 更新 agent_clients.last_seen_at | bump 恰 1 且无配置日志 | `S1d_last_seen_bump1_nolog: pass, delta=1, clients=8`，`agent_clients.update` 日志行数前后不变 | PASS |
| S1 独立对账 | 自数 `wb-s05:%` audit 行 | 自算 delta 自洽 | 我的 audit_rows=3（insert/update/softdelete 各 1）×2 = 6 = S1a+S1b+S1c 实测 delta 之和（2+2+2），独立对账闭合（未复用 Trae 的 12004 结论） | PASS |
| S2 混合包反事实 | R0 读 → 插入 `wb-s05:s2-mid-export-write` → 切 authenticated 经视图分页读 → R1 读 | R1≠R0 可检出 | `S2_mixed_detectable: pass, R0=471, R1=473`（写入 bump 2），分页读见 wb-s05 行 2 条；前端重试逻辑的 DB 侧语义前提成立 | PASS |
| S3 封闭集合真实性 | postgres 直数底表 | count=0（空数组=真实状态） | `S3_closed_sets_zero: pass, agent_advice=0, automation_rules=0` | PASS |

### 线 C：前端安全审读（`export.js` 588 行 + `transport.js restText` L208-264 全文审读）

| 项 | 方法 | 期望 | 实测 | 判定 |
|---|---|---|---|---|
| C1 token 流向 | 静态审读 restText | Bearer 只进 headers，不进返回值/日志/错误文本 | token 取自 `auth.getSession()` 仅拼接 `Authorization` 头；返回 `{ok,status,text}` 或 `{ok:false,error:{kind,text,retryable}}`；错误 text 为固定文案+HTTP 状态码，不含响应体更不含 token；全函数无 console/log 调用 | PASS |
| C2 下载 XSS 面 | 静态审读 `downloadFile`/`mount`/`setStatus` | 无注入面 | Blob 固定 `application/json`；`a.download` 文件名 = 固定前后缀 + `localDateStr(tz)`（Intl en-CA 输出恒为 `YYYY-MM-DD` 数字与连字符，tz 异常有 catch 兜底）；href 为 `blob:` 对象 URL 不可注入；`mount` 的 innerHTML 为纯静态模板；状态文案一律 `textContent`；全文无动态数据进 innerHTML | PASS |
| C3 parseLossless 拒绝路径 | 实跑压测：10 万/1 万层嵌套、10 万层不闭合、10 万键宽对象、runExport 端到端 | 不打挂、不产半包 | 10 万层与 1 万层嵌套均 1-2ms 内抛 RangeError（可 catch，进程存活）；对照原生 JSON.parse 10 万层正常解析（实现差异见 §2 F2）；10 万键宽对象 53ms 正常解析；runExport 喂 10 万层响应 → `ok=false kind=internal`，无下载无崩溃 | PASS（注记 F2） |
| C4 `_setPageSize` 暴露面 | 静态评估 window.Morrow.export 挂载面 | 测试钩子无可利用危害 | `_setPageSize`/`_internals` 挂 window，仅同源页面上下文可调（该上下文本就持有用户 session，权限不扩大）；效果仅限本客户端后续导出的分页宽度：调小→请求变多自我 DoS（有 `MAX_PAGES_PER_TABLE=20000` 守卫与 25MiB 上限封顶）；调大→PostgREST 侧 max-rows 截断仍受 R0/R1 一致性保护；不触碰他人数据、不破坏 hash 校验（round-trip 不过则拒下载） | PASS（注记 F3） |

---

## §2 NEW-FINDING（均 P3，不阻塞）

- **F1（P3）scanValue JWT 正则的行为边界**：`JWT_LIKE_RE = /^eyJ[A-Za-z0-9_-]{20,}\./` 大小写敏感且 `^` 锚定——`EyJ…` 混合大小写或 eyJ 出现在字符串中段均不命中。实测 V11/V12 hits=0。真实 Supabase JWT 恒以小写 `eyJ` 开头且作为完整字段值出现，构造不出真实绕过场景；且列白名单（A1）才是主防线，scanValue 是兜底。定性：行为边界注记，非缺陷。
- **F2（P3）parseLossless 递归深度低于原生 JSON.parse**：约 1 万层嵌套即 RangeError（原生 10 万层仍正常）。后果链已实测闭环：RangeError → runExport catch → 重试耗尽 → `ok:false` 明确失败，**不崩溃、不下载半包**。M1 数据源是自己的库、PostgREST 响应为浅层业务 JSON，攻击面有限；唯一小瑕疵是此类失败的文案为通用「导出过程中发生未知错误」，不区分栈溢出。可选改进（非本卡范围）：parseLossless 加深度上限提前报错。
- **F3（P3）测试钩子生产暴露**：`_setPageSize` 与 `_internals`（含 runExport/scanValue 等）在生产 dist 挂 `window.Morrow.export`。评估见线 C C4 行：同源上下文本就持有 session，钩子的最坏后果是自我 DoS 且被多重守卫封顶，无数据外泄与完整性影响。有 `drafts.js _read` 先例，M1 可接受；Phase 后可用 `import.meta.env` 类构建期开关摘除。

---

## §3 与 Trae/Hermes 结论的偏差点

**零实质偏差。** 逐条对照：

1. Trae「life_data 每行写入 bump 2 / last_seen bump 1 无日志」——我的 S1 矩阵独立实测 insert=2/update=2/softdelete=2/last_seen=1，语义一致（我未复跑其 1001+10000 fixture 与 delta=12004，而是按提示词要求自构造最小矩阵自算 delta，audit_rows×2=6 与实测总 bump 闭合）。
2. Trae/Hermes「白名单 42703、封闭视图 42501×2」——我的 A1a-A1e 全部复现，另自加 anon 42501（A1f）与 information_schema 全列对账（A1g），一致。
3. Hermes「scanValue 大写绕过变体全命中、`tokenized` 命中」——我的 V1/V2/V14 复现一致。
4. Hermes「parseLossless 严格性 12 类全拒」——我不重复其清单，改测其未覆盖的深度维度（F2），结论互补不冲突。
5. Hermes 复核后真库 revision=464——我的回滚自查同值 464，期间无人动库。

---

## §4 凭据与残留自查

- **探针回滚证据**：线 A/线 B 两个 DO 块均以 `RAISE EXCEPTION 'WB_S05_LINE*_PROOF …'` 收尾（HTTP 400 为预期成功信号），全部写入随事务回滚。回滚后独立只读自查：`life_data where entity_key like 'wb-s05:%'` = **0**、`activity_log where metadata->>'entity_key' like 'wb-s05:%'` = **0**、Trae 旧 fixture `mvp005test:%` = **0**、`workspace_state.data_revision` = **464**（与 Hermes 签核时一致）。真实库零持久写。
- **凭据纪律**：PAT/publishable key/owner email+password 均 keychain `-a morrow` 注入探针进程 env（`security find-generic-password … -w` stdout 重定向 /dev/null 探测存在性，值从未打印、未落盘、未进命令行参数）；本报告及全部探针文件中 key/token/密码值为零（可 grep 复核）；owner uuid 仅出现前 8 位 `0c645909…` 与提示词已公开的全文引用（用于反向断言样本不含该值）。
- **git 纪律**：全程只读（log/diff/status），未 commit、未 push、未碰 task-index；探针脚本与 SQL 均在 `/tmp/wb-s05/`，仓库唯一新增文件即本报告。

---

## 一句话交付凯哥

MVP-005 三条安全线（无凭据红线 / 快照语义 / 前端审读）全部独立自跑复现通过，真库零残留、记录零凭据，仅三条 P3 行为边界注记不阻塞——安全复核签 **PASS**，task-index 可翻牌进入 MVP-006。
