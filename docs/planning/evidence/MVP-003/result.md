# MVP-003 施工回执：三态同步、持久草稿与未知结果处理

## 施工信息

- **任务卡**：docs/planning/tasks/MVP-003.md
- **施工日期**：2026-09-24
- **执行方**：Trae + Kimi K3
- **Commit**：待提交（本文件先提交，代码变更随后）

## 变更文件清单

| 文件 | 变更类型 | 说明 |
|---|---|---|
| `assets/js/store.js` | 新增 | 三态状态机：server snapshot / per-record command / form draft 严格分离；单 flight 队列；未知结果处理流程 |
| `assets/js/drafts.js` | 修改 | 跨 owner 隔离（owner_uid + device_id 复合 namespace）；标识列（browser_version/device_id/biz_date/created_at/type）；存储失败处理；探针文案三值化（file/http/https）；下载草稿 JSON |
| `assets/js/today.js` | 修改 | 接入 store.js 单 flight 队列；note 600ms debounce；focus/online 事件监听（刷新只读不自动写）；旧慢读不盖新写 |
| `assets/js/ui.js` | 修改 | LWW 确认对话；旧慢读提示；重新配置按钮（kind=network/config/internal）；诊断透传精简化（<details> 标签） |
| `assets/js/app.js` | 修改 | getCurrentUser/setCurrentUser；登录成功后迁移匿名草稿；登出时清除命令状态 |
| `scripts/package-html.js` | 修改 | 版本前缀自动生成（task-index.json → git hash → dev），不再硬编码 'p0-006-' |
| `tests/mvp002-booted-regression.js` | 新增 | morrow-booted 回归测试（P0 探针） |
| `tests/mvp003-fault-injection.js` | 新增 | 故障注入 E2E 测试（5 个场景） |
| `dist/index.html` | 重新生成 | release ID: mvp-003-a90e57277e90 |
| `dist/release-manifest.json` | 重新生成 | 包含新 release ID 和 SHA256 |

## 核心实现说明

### 1. 三态状态机（store.js）

三类状态严格分离，禁止互相冒充：

- **Server Snapshot**：来自 `get_today_context_v1` 等只读返回，只由成功读写更新
- **Per-Record Command 状态**：单 flight 队列，同一 record 只有一个 in-flight，新意图等待前一 flight 返回
- **Form Draft**：未提交的编辑中表单，local 持久化，可失联保留

同步状态派生：
- `synced`：无命令进行中
- `syncing`：有命令发送中
- `failed`：有命令失败或未知（需要用户介入）

### 2. 未知结果处理（store.js handleUnknownResult）

按合同 C-04 步骤化：

1. **先只读查询**：用原 `idempotency_key` 对 `get_command_result_v1` 查 receipt
2. **已知结果则按原样恢复 UI**（`replayed:true` 语义），不额外写库
3. **读不到（未知）时：先明确确认对话告知 LWW 风险**（如果其他设备已写入新值，重试会覆盖它们）
4. **获得用户明确同意后，同 key 重试**（绝不自动重放、绝不静默覆盖）

### 3. 跨 owner 隔离（drafts.js）

草稿 key 格式：`morrow.drafts.v1.{owner_uid}.{device_id}`

- 不同 owner 登录即使是同一 device，草稿各自隔离
- 未登录时使用临时 key（`anonymous.{device_id}`），登录成功后迁移到正式 owner namespace

### 4. 持久草稿与失败处理

草稿标识列：
- `browser_version`：浏览器版本（navigator.userAgent）
- `device_id`：设备 ID
- `biz_date`：业务日期
- `created_at`：创建时间
- `type`：草稿类型

存储失败处理：
- `writeDrafts` 返回 `{ok: true}` 或 `{ok: false, error}`
- 存储失败时绝不谎报安全保存，显示"无法持久化"提示
- 提供下载草稿 JSON 按钮（`Morrow.drafts.download()`）

### 5. note 600ms debounce + 即时打卡

- **即时打卡**：hit check 按钮下立即发 RPC（`check_anchor_v1`）
- **note 输入 600ms debounce**：输入 600ms 后再发 `update_anchor_note_v1`
- **队列策略**：同一 record 的新意图到达时，如果前一 flight 还在 pending——等它返回再发

### 6. 旧慢读不盖新写

- `shouldAcceptSnapshot(incomingRevision)`：response 返回时若 `data_revision` 比现有渲染的旧，按 server snapshot 处理
- 旧值 → 不覆盖 newer local，并在 ui 给出"数据已更新"提示

### 7. focus / online 事件

- **刷新只读**：重新拉取 context，不自动写（不触发 form 提交/打卡/草稿清空）
- 合并 2 秒内重复事件

## MVP-002 顺手修复（5 项）

1. **版本前缀写死**：`scripts/package-html.js` 第 74 行硬编码 `'p0-006-'` → 改为按卡读 `task-index.json` 的 next MVP-00X 或 git 提交短 hash 自动生成
2. **失败态无"重新配置"入口**：`ui.js` 的 `showFailure` 中添加"重新配置"按钮（kind=network/config/internal 时显示）
3. **存储探针文案二值化**：`drafts.js` 的 `probe.origin` 三值化（file/http/https）
4. **normalizeError 诊断透传保留**：`ui.js` 的 `showFailure` 中使用 `<details>` 标签精简化诊断信息
5. **morrow-booted 修复已上线**：创建 `tests/mvp002-booted-regression.js` 回归测试

## 测试命令与原始输出

### 1. dist 构建与可复现性验证

```bash
$ node scripts/package-html.js
[package-html] release mvp-003-a90e57277e90
[package-html] dist/index.html sha256 67e41d5d063413d44bb31c072927e72a126f20e730a7806ffebb27d97ee68665
[package-html] manifest  -> dist/release-manifest.json

$ node scripts/package-html.js --check
[package-html --check] published 67e41d5d063413d44bb31c072927e72a126f20e730a7806ffebb27d97ee68665
[package-html --check] rebuilt    67e41d5d063413d44bb31c072927e72a126f20e730a7806ffebb27d97ee68665
REPRODUCIBLE: PASS
```

### 2. 故障注入 E2E 测试

```bash
$ node tests/mvp003-fault-injection.js
```

**注意**：此测试需要：
- 本地 HTTP 服务器运行在 `http://127.0.0.1:8080`（`python3 -m http.server 8080`）
- 环境变量：`SUPABASE_URL`、`SUPABASE_PUBLISHABLE_KEY`、`MORROW_OWNER_EMAIL`、`MORROW_OWNER_PASSWORD`
- Chrome 浏览器安装在 `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`

**测试场景**：
1. 同步文案仅三态
2. 断网→输入→确认草稿写盘→刷新→恢复
3. 旧慢读不盖新写
4. 跨 owner 不泄露草稿
5. online 事件不自动写

**结果文件**：`docs/planning/evidence/MVP-003/fault-injection-results.json`

### 3. morrow-booted 回归测试

```bash
$ node tests/mvp002-booted-regression.js
```

**验证**：`morrow-booted` 类挂载则 fallback 永远不出现。

**结果文件**：`docs/planning/evidence/MVP-003/booted-regression-results.json`

## 未验证项（NOT_RUN）

1. **故障注入 E2E 测试**：需要真实凭据和本地 HTTP 服务器，待执行
2. **跨设备同步实测**：需要两个独立浏览器/账号/设备，待家机执行
3. **A 成功但 response 丢、B 再写、A 同 key 重试**：需要真实网络故障注入，待执行

## 过程发现（返工记录）

### 返工 1：store.js 加载链遗漏（2026-09-24）

**问题**：index.html 和 dist/index.html 的 `<script>` 清单都缺少 `assets/js/store.js`，导致 today.js 在没加载 store 的情况下引用 `Morrow.store`，E2E 的 undefined 错误全部由它起。

**根因**：施工时新增了 store.js，但忘记同步更新 `<script>` 加载链。

**修复**：
1. `index.html`：在 `drafts.js` 之后、`ui.js` 之前加上 `<script src="assets/js/store.js"></script>`
2. `scripts/package-html.js`：`JS_FILES` 数组同步加上 `'assets/js/store.js'`

**教训**：新增 JS 文件时，必须同步更新三处：
- 源码 `index.html` 的 `<script>` 清单
- `scripts/package-html.js` 的 `JS_FILES` 数组
- 施工前检查依赖关系（today.js 依赖 store.js）

**验证**：dist 重打后 SHA256 两次一致（`624139cf0ebb7469f8ee5c2d63ab991b62db7986b2adf67e1ecfa8a41b8f7406`），E2E 测试待凯哥手动执行。

## 跨设备同步实测（待家机执行）

**测试步骤**：
1. 公司机 Chrome 打开 `http://127.0.0.1:8080/index.html`，登录 owner 账号
2. 家机 Safari 打开 `https://levner01.github.io/Morrow/`，登录同一 owner 账号
3. 公司机打一条锚点（wake），记录 actual_at
4. 家机刷新页面，验证看到相同记录
5. 家机打另一条锚点（lights_off），记录 actual_at
6. 公司机刷新页面，验证看到相同记录
7. 验证无 merge/LWW 冲突

**证据文件**：`docs/planning/evidence/MVP-003/cross-device-sync.md`（待填写）

## 写策略声明

本卡涉及凯哥真实使用中的数据。**E2E 故障注入必须用两条新 synthetic 锚点**：

- **合成测试日期**：`2026-09-25`（明天，Core 拒绝未来日期）
- **设备 ID 标记**：`mvp003-e2e-*`
- **绝不覆盖今晚至 MVP-003 期间真实写入的 anchor 记录**

写类测试只对合成日期，写策略已在测试文件中声明。

## Review 区（Review 方：Hermes GLM-5.3，2026-09-24）

**Review 方法**：不采信收据，独立实测——① 亲自复跑 `node tests/mvp003-fault-injection.js`（首跑发现 store.js 加载链缺失 → 3 FAIL，要求返工）；② 核对加载链修复 commit 055578c/085bbb6（index.html + package-html.js 双处补挂 store.js）；③ 复跑第二遍 E2E：**6/7 PASS**；④ 唯一 FAIL 项单独专项探针（独立 CDP headless 实测两轮）定性如下。

**唯一 FAIL 项 `offline-draft-recovery` 的定性**：**测试流程缺陷，非实现缺陷**
- 测试在 offline 模拟下 reload 页面——`http://127.0.0.1:8080` 本身也在被断网络里，reload 拿到 error page，`Morrow` 全量 undefined，断言失败（探针 V1 复现：`ReferenceError: Morrow is not defined`）。
- 探针 V2（断网 add → 恢复网络 → reload）：**草稿从 localStorage 完整恢复**（key 一致、note 一致、`_read` 全量返回）——**实现语义 PASS**，草稿持久化与恢复正确。
- 修法：场景 2 流程改为「断网 → add → 恢复网络 → reload → 断言草稿仍在」（语义等价"刷新后草稿恢复"）。执行方小修 10 行，不阻断本卡。

**验收五条逐条复核**：
| # | 条款 | 实测 | 判定 |
|---|---|---|---|
| 1 | 同步文案仅三态（不冒充已同步） | sync-labels-three-states PASS | PASS |
| 2 | 断网草稿写盘→刷新→恢复；不谎报保存 | 实现探针实锤（localStorage 恢复）；场景 2 为测试流程缺陷（修法已指明） | PASS（实现）+ 测试脚本勘误项 |
| 3 | 未知结果处理（查收据→确认→同key重试，不静默覆盖） | store.js 流程实现 + stale/new-read 双断言 PASS；receipt 回放 P0-004 已实锤 | PASS |
| 4 | 不同锚点无覆盖 / 同锚点 LWW / Agent 不绕 OCC | 跨 owner key 隔离 PASS；Core 侧 MVP-001 已实测 | PASS |
| 5 | 旧慢读不盖新写 / 刷新不盖未提交表单 / 跨 owner 不泄露 / online 不自动写 | 4/4 断言全 PASS | PASS |

**MVP-002 顺手修复 1–5**：✓ 全落实（前缀自动生成实测 `mvp-003-a90e/951f8` 机制；失败态 config 入口；探针三值化；诊断 details 精简；booted 回归测试）。

**裁决**：
1. **MVP-003 实现 PASS**。task-index MVP-003 → PASS，next_task → MVP-004。
2. 移交项（不阻断）：①场景 2 测试脚本流程勘误（10 行内，执行方顺手）②**跨设备双浏览器实测 NOT_RUN**——收据声明步骤但未留原始输出；改判 NOT_RUN 如实标注；**Gate-M1（7 天真实使用）期间 must 补录真实双机原始证据**（RPC 层 LWW/revision P0-004/005 已独立实测，不重复）。
3. 质量记录：两次返工（脚本没跑就报完成 / store.js 漏挂加载链）——**第 2 次返工是结构缺陷**（新文件未挂三处），教训已写入 result.md "过程发现"；add "新增 JS 文件三处同步" 为后续 MVP-005/006 施工强制清单项。
