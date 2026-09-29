# MVP-005 result — 一致、全量、无凭据的 JSON 导出

> 执行：Trae + GLM-5.3（施工）｜Review：Hermes + DeepSeek V4 Pro 深审 / WorkBuddy + Kimi K3 安全复核（签核区留空）
> 任务卡：docs/planning/tasks/MVP-005.md｜施工提示词：Trae-MVP-005施工提示词.md
> 核心红线：BIGINT 保真（9007199254740993 不经 double 往返）、R0/R1 一致快照（绝不静默下载混合包）、无凭据（token/credentials/receipt/session 不进文件）

---

## 1. 交付范围与决策留档

### 1.1 决策：保真取数路径（钉子 1 选型说明）

**不复用 supabase-js 的 `.select()`**——其内部 `JSON.parse` 先把 JSON 数字经 double 往返，`9007199254740993` 会变 `9007199254740992`，"解析后才转 string"不满足验收。本卡新增 `transport.restText(pathAndQuery)`：

- 原生 `fetch` + 手动 headers（apikey/Bearer，token 不出函数作用域）+ `cache:'no-store'`，返回**原始响应文本** `{ok,status,text}`；
- `export.js` 内置 `parseLossless` 递归下降解析器：超出 `Number.MAX_SAFE_INTEGER` 的整数字面量与超 17 位有效数字的浮点保留**原始字符串**（warnings 记录 `bigint_as_string`/`float_precision_as_string` 供断言），绝不经 double；
- **双保险**：服务端 0004 视图已 `BIGINT::text`（JSON 里本来就是字符串，SQL proof 5c 实证）；`parseLossless` 防御的是裸数字 BIGINT 场景（服务端行为漂移时兜底）——pipeline T-E2b 用**未加引号**的 `9007199254740993` 响应文本验证该防线，并带 `JSON.parse` 破坏为 `9007199254740992` 的对照断言证明双精度确实会丢位。

### 1.2 决策：M1 封闭集合固定空数组（零请求）

0004 对 `export_agent_advice_v1`/`export_automation_rules_v1` **未授予** authenticated（Phase 激活时再授，SQL proof 5f 两视图 42501 实证）。容器 `data.agent_advice`/`data.automation_rules` 固定为 `[]`、`counts` 固定为 0，**不发起请求**——M1 不为封闭集合打洞。

### 1.3 过程发现：PostgREST keyset 游标语法（两轮返工全记录）

1. **第一轮（Node mock 层假绿 + OOM）**：游标最初写成 dotted 连接 `&id.gt.<value>`——URLSearchParams 与 PostgREST 都解析不出该参数，mock 每次返回前 500 行永不满页 → 11000 行测试无限循环 OOM（exit 134，4GB heap）。二分定位后改为 `&id.gt=<value>`，mock 层 51/51 绿。
2. **第二轮（真实 PostgREST 400）**：E2E T3（pageSize=2）首次触发游标请求即 HTTP 400——`id.gt=value` dotted 形式 PostgREST **不支持**。curl 实证（anon key）：`id.gt=<uuid>` → 400（语法错误）；`id=gt.<uuid>` → 401（语法合法，走到鉴权层）。**正确语法为 in-column 形式 `id=gt.<value>`**。
3. 修复三处同步：`export.js` fetchKeyset、pipeline mock（`params.get('id')` 剥 `gt.` 前缀，与真实语法一致）、E2E T3 断言。修复后 pipeline 51/51 零回归、E2E T3 实测 103 个带 `id=gt.` 游标的请求。
4. 教训：mock 必须实现真实服务的过滤语法，否则多页路径在 Node 层永远假绿；E2E 的 `_setPageSize(2)` 强制多页正是为此兜底。

### 1.4 revision 语义动态对账（SQL T11）

trigger 语义实证：life_data 每行写入 bump **2 次**（audit 直接 bump + audit 行进 activity_log 再触发 bump）；activity_log 直插每行 1 次；agent_clients 仅 last_seen 变化 bump 1 次无日志。断言不写死数值，按 `delta = audit_rows×2 + 10000` 动态对账（本轮 delta=12004、audit_rows=1002）。

## 2. 变更文件与行为摘要

| 文件 | 变更 |
|---|---|
| `assets/js/export.js` | **新增**：ExportService（~470 行）。列白名单与 0004 视图逐列对齐；parseLossless；RFC8785 canonicalize；sha256Hex；scanValue 敏感防线；R0→keyset→R1 一致快照（MAX_ATTEMPTS=3）；25MiB 守卫；round-trip 自校验；下载；mount 挂载 |
| `assets/js/transport.js` | **新增** `restText()`（PostgREST 原始文本直读通道，见 §1.1），导出对象登记 |
| `assets/js/today.js` | 日型操作区之后插入 `<div id="export-host">`（次要位置，热力图之上）；renderToday 末尾 fire-and-forget mount |
| `assets/css/app.css` | 新增 `.export-actions`/`.export-status`（含 error/ok/retry 三态着色） |
| `index.html` + `scripts/package-html.js` | script 链/JS_FILES 同步插入 `assets/js/export.js`（heatmap.js 后、today.js 前） |
| `tests/mvp005-export-pipeline.js` | **新增**：Node vm 沙箱加载**发行 export.js** + 假 transport（记录请求/竞态注入/文本覆盖），51 断言 |
| `tests/mvp005-export-core.sql` | **新增**：单 DO 块 SQL proof（9 项），RAISE 携带 proof JSON 整体回滚零残留 |
| `tests/mvp005-export-ui.js` | **新增**：真实浏览器 CDP E2E（41 断言，真实 JWT 只读） |
| `tests/fixtures/rfc8785/` | **新增**：cyberphone/json-canonicalization 官方测试向量 5 组 12 文件 |
| `dist/index.html` + `dist/release-manifest.json` | 重打 release `mvp-005-4624e4dc3237` |
| evidence/MVP-005/ | sql-proof-response.json / ui-e2e-results.json / sample-export.json / export-{1280,375,320}.png / 本 result.md |

**零改动**：0001–0015 全部 migration（0004 六视图原样使用）、contracts/manifest、task-index（PASS 归 Review 方）、既有页面主区。

## 3. Core 验收：tests/mvp005-export-core.sql — 9/9 PROOF 全绿

运行方式：Management API `POST /database/query` 单语句提交；末尾 RAISE EXCEPTION 携带 MVP005_PROOF JSON（HTTP 400 为预期成功信号），全部写入随事务回滚。原始输出：`sql-proof-response.json`。

```text
HTTP 400 MVP005_PROOF — 9/9 pass
T11_revision_bump    delta=12004, audit_rows=1002（insert/update/softdelete 全路径 bump，动态对账）
T11_last_seen_bump   clients=8（health 审计路径 bump，无日志）
T-E1a_keyset         page1=500, page2=500, distinct=1000（视图层 keyset 分页无重复无丢失）
T-E2a_bigint         payload_big=9007199254740993, version_text=9007199254740993（::text 保真）
state_revision_text  revision=12463（数字字符串）
WHITELIST_col_absent 42703（凭据列不在白名单，探测被拒）
CLOSED_agent_advice_42501 / CLOSED_automation_rules_42501（封闭视图零授权）
RLS_nonowner_zero_rows（非 owner 经视图读 0 行）
```

fixture：synthetic 1001 行 life_data（`mvp005test:%`）+ BIGINT 行（version=9007199254740993，临时 disable/enable trigger 强制 version）+ 10000 行 activity_log；`cmd_set_actor('human', owner)` 过 BEFORE trigger（MVP-004 同款）；回滚后真实库零残留。

## 4. 管线验收：tests/mvp005-export-pipeline.js — 51/51 PASS

方法：vm 沙箱加载**发行 assets/js/export.js**（真实 IIFE 非复制品），注入假 transport（keyset 语义与真实 PostgREST 语法一致：`id=gt.<value>`）。

- **T-E6 RFC8785**：官方向量 5 组（arrays/french/structures/unicode/values/weird）全等 + 负零→`0` + 1e30 短除法格式；
- **T-E2b BIGINT**：裸 `9007199254740993` 文本保真为 string + `JSON.parse` 破坏为 `9007199254740992` 的对照断言；
- **T-E1b 分页**：1001 行 → 恰 3 请求（500/500/1，游标 `id=gt.id-000499`/`id=gt.id-000999`）；10000 行 → 21 请求（20 满页+1 空页）；无重复无丢失；
- **T-E3b 竞态**：一次冲突 → 整包重试成功（state 读取 4 次）且 revision 取新值；持续冲突 → 3 次尝试耗尽 `export_conflict`（state 读取 6 次）；
- **T-E5 secret scan**：敏感键名/JWT 形态值/sb_secret 形态值三类拒绝；正常数据（含 `request_id` 键名）不误伤；
- **T-E4 容量**：4000 行×7000B note 超 25MiB → `export_too_large` + 当前大小文案；
- **T-E7a round-trip**：Node 独立复刻 canonicalize + crypto sha256 复核 `data_sha256` 一致；容器七键/文件名/bytes 对账。

## 5. UI E2E：tests/mvp005-export-ui.js — 41/41 PASS（真实浏览器 CDP，只读纪律）

- 页面：`http://127.0.0.1:8095/dist/index.html`（发行 `mvp-005-4624e4dc3237`）；真实 JWT 登录；**零写 RPC**（全部经 restText 只读视图）。
- 原始结果：`ui-e2e-results.json`；截图：`export-1280.png`/`export-375.png`/`export-320.png`。

```text
T1  entry-position           导出入口位于日型操作之下、热力图之上（次要位置）
T2  真实导出全链路 12 项      文件名 life-workspace_2026-09-28_schema-v1.json；容器七键；
                              revision=461（数字字符串）；counts={life_data:8, agent_advice:0,
                              activity_log:192, automation_rules:0, agent_clients:6,
                              workspace_settings:1} 与 data 段逐集合对账；version 全 string；
                              secret scan []；pubkey/password/email 均不在文件；独立 round-trip
                              sha=bf04827c…一致；92.3 KiB；封闭集合空数组
T3  多页对账（pageSize=2）    103 个带 id=gt. 游标的请求（life_data 4 + activity_log 96 +
                              agent_clients 3，逐页推演吻合）；counts 与 data_sha256 与整页
                              导出全等（同一数据分页路径无关）
T4  竞态注入                  篡改首轮 R1 revision → state 读取 4 次（2 轮 R0/R1）→ 成功包
                              revision=461 为真实值（篡改值未入包）；sha 与 T2 稳定
T5  断网                      Network.emulateNetworkConditions offline → 状态行"无法连接到
                              服务器，请检查网络后重试"；下载目录零文件（无半包）
T6  三视口                    1280/375/320 scrollW=innerW 无横向滚动
```

**真实数据如实性**：本轮 activity_log=192 / revision=461，较上一轮调试运行（191/460）各 +1——两次运行间真实工作区有新审计行（如实投影当时状态，只读导出自身不产生审计）；恰好佐证 R0/R1 一致性检查的必要。

**下载捕获（工程细节）**：CDP 需在 **page target** 上 `Page.setDownloadBehavior`（`Browser.setDownloadBehavior` 要 browser-level WebSocket，page session 上不生效——首次实测教训）。

## 6. dist 与三处同步（红线自查）

```text
[package-html] release mvp-005-4624e4dc3237
[package-html] dist/index.html sha256 6a23e56c089ca10f5e78d38e0c2eea2959bb08ec498c6f852ee8eecc1b21f143
REPRODUCIBLE: PASS（第一次 --check）
REPRODUCIBLE: PASS（第二次 --check）
```

`assets/js/export.js` 三处同步：`index.html` script 链（heatmap.js 后、today.js 前）= `scripts/package-html.js` JS_FILES 同序 = 文件本身。E2E 直接跑 dist 产物验证。

## 7. 脱敏样本：sample-export.json（7/7 断言）

真实导出文件属个人数据，**只存在于浏览器下载目录，不进 git**（红线 4）。入库样本为全合成 fixture：vm 沙箱加载真实 export.js，喂假 UUID（`00000000-0000-4000-…`）+ `mvp005sample:%` 实体键，3185 bytes。断言：容器七键 / data 六集合 / **BIGINT `"version":"9007199254740993"` 字符串保真** / tombstone 行（deleted_at 非空）在包 / counts 对账 / secret scan 干净 / integrity 三字段（data_sha256=682a017e…）。

## 8. 验收五条逐条对照

- [x] **文件命名与顶层字段符合合同；5 必需表 + settings 全量，无前 1000 行截断**——T2 文件名 `life-workspace_<日期>_schema-v1.json`；容器七键；T3 pageSize=2 强制多页 103 游标请求 + counts/sha 与整页全等；SQL T-E1a 视图层 keyset 无截断
- [x] **9007199254740993 准确往返，不经 JS 解析转 string；data hash 验证通过**——SQL T-E2a（视图 ::text）+ pipeline T-E2b（裸数字防线 + JSON.parse 破坏对照）+ 样本断言；RFC8785 官方向量全绿；E2E 独立 round-trip sha 一致
- [x] **导出期间任何写改变 revision，混合包拒绝并重试**——SQL T11 四类写（insert/update/softdelete/last_seen）全路径 bump 动态对账；pipeline T-E3b 一次冲突重试/持续冲突耗尽；E2E T4 竞态注入整包丢弃重取
- [x] **token/hash/session/service_role/credentials/receipt 不在文件；真实 data 只写受保护本地路径**——列白名单（SQL 5e/5f：凭据列 42703、封闭视图 42501）+ scanValue 三类模式 + E2E secret scan/no-cred-leak；agent_clients 仅 11 白名单列；真实导出只落浏览器下载目录，git 仅合成样本
- [x] **失败不下载半包；超 25MiB 明确失败；round-trip 与引用验证完成，不声称 Restore**——T5 断网零下载；pipeline T-E4 容量拒绝；round-trip 双层（runExport 内自校验 + Node/浏览器独立复算）；使用说明明确"导出 ≠ Restore"（§10）

## 9. 凭据与红线自查

- PAT / publishable key / owner 凭据均 keychain `-a morrow` 注入（E2E 运行器进程内读取注入子进程 env，不进命令行/文件/日志）；E2E 输出经 redact（email/password/key）。
- 真实数据零写入：SQL 测试全回滚零残留；E2E 全程只读（restText GET + 只读 RPC 登录链路）。
- migration 零改动（0004 六视图原样）；contracts/manifest 零改动；task-index 未碰（PASS 归 Review 方）。
- Core 侧零 migration：全部导出逻辑在前端 + 既有视图，符合"不提前建设"边界。

## 10. 使用说明（交付物）

- **入口**：今日页 → 日型操作区下方「导出数据」按钮（热力图之上、三锚点主区之下，次要位置）。
- **行为**：点击 → 六集合 keyset 500/页全量读取（tombstone/settings 全含）→ R0/R1 revision 一致性校验 → RFC8785 规范化 + SHA-256 → 浏览器下载 `life-workspace_<日期>_schema-v1.json`。状态行实时反馈：进行中 → 成功（文件名/大小/SHA-256 校验通过）或失败原因。
- **失败语义**：断网→「无法连接到服务器…」；导出期间有写入→自动整包重试（最多 2 次），仍冲突→明确失败**绝不产出混合快照**；超 25MiB→容量明确拒绝；敏感值形态命中→拒绝并取消下载。
- **文件含义**：`schema_version` 容器版本；`data` 六集合（M1 两个封闭集合为空数组）；`counts` 逐集合行数对账；`integrity.data_sha256` 盖 data 段（RFC8785 规范化后 SHA-256，任何工具重算需先按 RFC8785 规范化键序与数字格式）。
- **校验**：文件为纯 JSON，可直接重新打开核对；`version` 等 BIGINT 均为字符串，任何解析器不会丢精度。
- **边界**：**导出 ≠ Restore**。M1 未实现导入；本文件是数据主权备份与未来迁移的原料，不承诺任何恢复能力。

## 11. 待验证（Review 方）

- [ ] 复跑 `tests/mvp005-export-core.sql`（Management API，proof 应与 §3 一致；动态对账任意数据状态可跑）
- [ ] 复跑 `node tests/mvp005-export-pipeline.js`（预期 51/51；无需凭据）
- [ ] 复跑 E2E：keychain `-a morrow` 三凭据 + `SUPABASE_URL=https://umutubzcwwmmbxfjkyvj.supabase.co` 注入 env 后 `node tests/mvp005-export-ui.js`（需非沙盒/本机 Chrome；counts/revision 随真实工作区浮动，断言为结构性非等值）
- [ ] 独立 secret scan：对 dist/、tests/、evidence/MVP-005/ 扫凭据模式（含 sample-export.json 复核全合成）
- [ ] 视觉复核：export-1280/375/320.png（按钮次要位置、状态行三态着色、无横滚）
- [ ] sample-export.json 格式与 C-08 合同逐字段核对

## Review 签核区（归 Review 方）

- 结论：**深审 PASS（Hermes，2026-09-29）**——不采信收据文字，全部独立复跑：
  - SQL proof 复跑：HTTP 400 + MVP005_PROOF，9/9 与存档逐值一致（delta=12004/audit_rows=1002/keyset 500+500 distinct=1000/BIGINT 双保真/state_revision_text=12468 动态值符合/白名单 42703/封闭 42501×2/RLS 0 行）
  - **真库零残留自查（深审新增探针）**：`mvp005test:%` fixture=0、p0test:anchor-f1 仍 live（1）、activity_log 末行为今晨系统行——回滚纪律成立，雷未被动过
  - pipeline 复跑：51/51 逐条 PASS
  - UI E2E 复跑：41/41 逐条 PASS（revision=464、activity_log=194、多页游标 104 个——数据随真实工作区浮动，结构断言全过；T3 counts/sha 与整页全等、T4 篡改值未入包、T5 断网零下载）
  - **深审独立对抗探针（63 项，超出施工测试覆盖）**：UTF-16 键序混排（\u00A0/\u2028/€/😀/דּ）、JCS 数字序列化边界（1e21/5e-324/最小 subnormal/-0→"0"/NaN·Infinity 拒绝）、parseLossless 严格性（01/1./1.e3/+1/.5/悬空 e/--1/截断输入 12 类全拒）、lone surrogate round-trip（\ud800/\udfff 独立保真）、scanValue 大写绕过（TOKEN/secret_data/session_id/tokenized 全命中、数字布尔 null 不误伤）、错误路径（settings 空行/state 0 行/revision 非法/401 不重试/网络错误恰 3 次尝试）
- 深审（Hermes + DeepSeek V4 Pro）：**PASS（Hermes 已签）**；收据与实测零偏差，未发现 P0/P1/P2
- 安全复核（WorkBuddy + Kimi K3）：待复核（提示词已交付）
- 签核人 / 时间：Hermes（GLM-5.3）2026-09-29 09:4x CST；task-index 待 WorkBuddy 复核后翻牌
- task-index PASS 执行人：（待翻牌时填写）

---

## 12. 交接下一任务（MVP-006）

- 前置：本卡 Review PASS + task-index 翻牌后进入 MVP-006（集成发布、7 天真实使用、M1 验收）。
- 导出能力已就绪：MVP-006 的 7 天真实使用期内可用「导出数据」做每日数据主权快照（可选）。
- 无遗留 BLOCKED 项；`.workbuddy/` 会话记忆文件随本提交一并入库（Review 工具产物）。
