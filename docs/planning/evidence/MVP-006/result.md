# MVP-006 工程窄验收段 — result.md

**状态：ENGINEERING_READY**（7 天真实使用窗挂账段二；04-acceptance §5 状态枚举如实选择，任何"用测试数据填 7 天"的动作 = P0，本段零此类动作）

- 施工：Trae（GLM-5.3）；起点 HEAD `8657de3` · branch main · 2026-09-29（Asia/Shanghai）
- 授权范围：凯哥本会话显式授权 mvp003/mvp005 系列 E2E 的凭据 env 注入（keychain `-a morrow` → 进程内存 → 子进程 env）；PAT 对生产库的 Management API 操作超出该授权范围，一处补充查询已拒并降级为 Review 可选自查项（§5）
- 深审提示：Review 方不采信收据，全部复跑

## 1. 变更清单

| 文件 | 变更 | 说明 |
|---|---|---|
| `dist/index.html` + `dist/release-manifest.json` | 重打 | 新发行 `mvp-006-4624e4dc3237`（sha256 `58d89c5f…de7c`，全量见 §2.1）。原因：8657de3 将 task-index next 指针翻至 MVP-006，版本前缀生成器随 next 变化，MVP-005 期 dist `--check` FAIL（published `6a23e56c` ≠ rebuilt `58d89c5f`）——非代码变更，按提示词"重打并记录"执行 |
| `tests/mvp003-fault-injection.js` | 修改 | 测试基建修复（§4 竞态根因），断言与场景语义零改动 |
| `tests/mvp006-mvp001-key-proofs.sql` | 新增 | MVP-001 关键 proof 复验探针。mvp001 原文件 T00 要求真库零数据（MVP-001 验收时成立），真库 9/23 起有真实使用数据，全量原样复跑不可行；取关键 proof（真实历史日 context / 未物化 / F01 / 幂等 / F08 归属 / F02 迟到 / 信封纪律）复验，事务全回滚零残留 |
| `docs/planning/evidence/MVP-006/` | 新增 | 7 份回归原始输出存档（§3 逐项引用）+ 本目录三份交付文件 |

## 2. 发布链路

### 2.1 dist 可复现性（--check 两次）

```bash
$ node scripts/package-html.js --check && node scripts/package-html.js --check
[package-html --check] published 58d89c5f142208a723aea0b9a249972a276d028f6a96ea6cbf33cae2a025de7c
[package-html --check] rebuilt    58d89c5f142208a723aea0b9a249972a276d028f6a96ea6cbf33cae2a025de7c
REPRODUCIBLE: PASS
（×2，两次均 PASS）
```

### 2.2 GitHub Pages 实测（本段开工第一件事）

```bash
$ gh api repos/levner01/Morrow/pages --jq '{status, html_url, source, build_type}'
{"build_type":"workflow","html_url":"https://levner01.github.io/Morrow/","source":{"branch":"main","path":"/"},"status":"built"}
```

- Pages **已启用**（workflow 模式，`.github/workflows/deploy-pages.yml`：push main 触碰 `dist/**` → upload-pages-artifact path:dist → deploy-pages）——无需凯哥设置动作。
- 线上内容指纹（实测时点）：`6a23e56c…`（= mvp-005 发行，与远端 main 的 dist 一致）；本地重打后 `58d89c5f…`（mvp-006）。**push 后 workflow 自动部署新版。**

### 2.3 发版对账（push 后补记）

> 本小节在 commit+push 触发 workflow 部署后补记：线上 `curl | shasum -a 256` = `58d89c5f…de7c` 对账 + 页面 boot 后 console `MORROW_RELEASE.id` = `mvp-006-4624e4dc3237` 对账 + A13 fallback 重测结果。**补记前此处为 PENDING，不假装完成。**

### 2.4 本地 HTML 交付说明（同 hash 手动安装）

- 文件：`/Users/wangxinkai/Documents/Morrow/dist/index.html`
- sha256：`58d89c5f142208a723aea0b9a249972a276d028f6a96ea6cbf33cae2a025de7c`（与 §2.1 / 线上发行同 hash）
- file:// 打开即可用（origin=null 场景 P0-008 已证 fallback 路径；本轮实测见下）

公司机 file:// 实测（CDP headless 只读探针，2026-09-29）：

```json
{
  "page": "dist/index.html (file://)",
  "checks": {
    "ui_shell_visible": true,
    "auth_login": { "ok": true, "email": "le***@foxmail.com" },
    "rpc_revision": { "ok": true, "revision": { "ok": true, "request_id": "623a5397-0c8b-44a0-9ab0-a0c7534fa63e", "server_time": "2026-09-29 04:13:13.66166+00", "data_revision": "480" } },
    "storage_refresh_session_restored": true
  }
}
```

（Auth=password grant 真登录；RPC=get_workspace_revision_v1 权威只读；storage=Page.reload 后 getCurrentUser 非 null）

## 3. 最终回归矩阵（逐项命令与原始输出）

> 全部为真实运行输出。SQL 走 Management API `POST /database/query`（HTTP 400 = 预期回滚信号，PROOF 随错误体返回）；E2E 走真实 Chrome CDP。完整原始输出存档于本目录 `regression-*.json|txt`。

### A16 锚点与日型（MVP-001/004）

`tests/mvp004-stats-core.sql` → **15/15 PASS**（PROOF 摘录；存档 `regression-mvp004-stats.json`）：

```
T01_F09_streak45(streak_days=45, recording_rate=1.0144…) pass
T02a/T02b_F12(provisional/complete+1) pass  T03_F14_late_counts_recorded pass
T04_F10_unopened_in_denominator pass  T05_nonworkout_denominator2 pass
T06_interval_unknown pass  T07_history_backfill_recompute pass
T08_heatmap_shape(30d, first=2026-08-31, last=2026-09-29) pass  T08b_not_started pass
T09_validation(span/future/inverted/cursor/unknown_field) pass
T10_public_rpc_owner_denied_readonly pass
T12_over_recorded_no_penalty(streak=6, today_complete=true, recorded=den+1) pass
T13_p0test_landmine_defused(recorded=3/den=2/单天窗口 streak=1) pass
```

`tests/mvp006-mvp001-key-proofs.sql` → **8/8 PASS**（存档 `regression-mvp001-keyproofs.json`）：

```
T00_setup(real_data: 2026-09-23 ×4 rows) pass
T01_real_day_context(planned_cumulative=8) pass  T02_readonly_no_materialize pass
T03_F01_wake_deviation_lock(deviation=-3, 首日锁, 审计同事务6行) pass
T04_idempotent_replay(version稳定v2, 审计不变) pass
T05_F08_attribution_window(+135 归属, 跨本地日拒) pass
T06_F02_late_counts_recorded(+20, recorded=2/met=0) pass
T07_envelope_discipline(未知字段拒, Human 禁 expected_version) pass
```

注：T01/T02 的 planned_count 为累计窗口口径（tracking_started_on..biz_date），断言按 9/21 起真实数据动态对账。零残留核验：事务回滚后 9/24 行数 0、真实数据行数 8（与探针前一致）。

### A18/A19/A20 三态与草稿（MVP-003）

`tests/mvp003-fault-injection.js` → **7/7 ALL PASS（EXIT=0）**（存档 `regression-mvp003-fault.json`）：

```
PASS sync-labels-three-states（标签：三态之一）
PASS offline-draft-recovery（add=true sessionReady=true hit=true key=morrow.drafts.v1.0c645909-…真 owner 域）
PASS stale-read-not-accepted（v3 不盖 v5）/ new-read-accepted（v7 盖 v5）
PASS cross-owner-key-isolation（A 真域 vs B 域不同）/ cross-owner-draft-isolation
PASS online-event-no-auto-write
network 31 条真实请求入档（auth token grant、favicon 等，含修复说明见 §4）
```

复跑前发现并修复了该测试的启动竞态（根因与修复全记录见 §4）。**断言与场景语义零改动。**

### A21 30 天图（MVP-004）

- `tests/mvp004-stats-core.sql` 15/15（同 A16，T01/T08 直接覆盖 30 图与 45 天连续）
- `tests/mvp004-heatmap-ui.js` → **19/19 PASS（EXIT=0）**（存档 `regression-mvp004-heatmap-ui.txt`）：30 格、今日蓝框、五态 aria、记录率≠达标率分离、DOM/RPC 逐项对账、anchor-list 在 heatmap 之前、1280/375/320 无横滚（scrollW=视口宽）

### A22 视觉主体/手机（MVP-002/006）

- 1280/375/320 无横滚：mvp004-ui 19/19 场景 2/3 + mvp005-ui T6（viewport-1280/375/320-no-hscroll 全 PASS）**双重覆盖**
- 真实手机检查：**BLOCKED-PENDING-OWNER**（凯哥回传真机截图，本 result.md §6 与 dual-device 表已留位）
- 键盘/200% 文字：MVP-002 期已验（evidence/MVP-002/），本轮未变更 UI 代码，不重复跑

### A23/A24/A25 导出（MVP-005）

- `tests/mvp005-export-core.sql` → **9/9 PASS**（存档 `regression-mvp005-export-core.json`：T11 delta=12004 动态对账 / BIGINT ::text / 白名单 42703 / 封闭视图 42501×2 / RLS 0 行）
- `tests/mvp005-export-pipeline.js` → **51 passed, 0 failed（EXIT=0）**（存档 `regression-mvp005-pipeline.txt`：RFC8785 官方向量 + round-trip + 文件名格式 + bytes 一致）
- `tests/mvp005-export-ui.js` → **41/41 PASS（EXIT=0）**（存档 `regression-mvp005-ui.json`）：真实下载 99.7 KiB、counts 与真实库一致（life_data 12 / activity_log 203 / agent_clients 6 / workspace_settings 1，**随真实库浮动，断言为结构性**）、revision=479 字符串、secret-scan []、多页 110 游标请求整页全等、竞态注入 R1 重取真实 revision=479、断网零半包、三视口无横滚

### A28 下一 Phase 未偷跑

```bash
$ grep -rin "phase1" assets/ supabase/migrations/
supabase/migrations/20260917100100_0002_core_tables.sql:28:    -- anchor/day_type 必填 biz_date；其余按模块合同（Phase1 后按需收紧）
（唯一命中：0002 内一行注释，非代码施工）
$ git log --oneline --all | grep -i "phase1\|phase-1"
（零命中）
```

### A13 fallback（Supabase 失败不白屏）

发版后重测（§2.3 联动，push 后补记：改错 URL / 禁网 → 壳可见可恢复）。**补记前 PENDING。**

## 4. mvp003 复跑竞态：根因与测试基建修复（工程记录）

**现象**：本段复跑 `mvp003-fault-injection.js` 最初 1/7——6 项"测试异常：setupAndLogin 登录失败: {}"，`network: []`（登录请求根本没发出）。

**排查过程**（全部留痕）：curl password grant 200 OK（Supabase auth 正常）→ 手动最小化 CDP 登录 ok（基建正常）→ 同环境诊断脚本 `transport.login` ok:true（登录路径正常）→ mvp004-heatmap-ui 同 dist 19/19（dist 正常）→ **失败锁定在 mvp003 测试自身的启动时序**。

**根因链（三层，全部实证）**：

1. **固定 `sleep 2000ms` 竞态**：多场景连续启停 5 个 Chrome 的负载下，2 秒既可能不够 Chrome 起来（→ `ECONNREFUSED 127.0.0.1:96xx`），也可能不够页面脚本链加载完（→ evaluate 抛异常，**Error 对象被 `returnByValue` 序列化为 `{}`**，即"登录失败: {}"的直接来源——当年机器空闲 2s 够，纯竞态）。
2. **残留进程端口撞库**：旧版 `chrome.kill()` 仅发 SIGTERM 且不等退出，历次运行累计 **91 个 headless Chrome 进程残留（13 组调试端口存活，含此前 ECONNREFUSED 的 9616/9535）**。新实例随机端口（9222+random1000）与残留撞库后，CDP `/json` 连到**残留实例的旧页面**——表现为清场前"全场景 15s 不就绪"的确定性失败。
3. **裸 `find(type==='page')` 错连 about:blank**：轮询过早连上 CDP 时目标 URL 尚未开始导航，page target 还是 about:blank，在其上 evaluate 永远等不到 `window.Morrow`。

**修复（全部测试基建层；断言、场景结构、真实写纪律（合成日期 2026-09-30 + `mvp003-e2e-*` device 标记）零改动；先例：`--no-proxy-server`、085bbb6 加载链修复）**：

1. CDP `/json` 轮询（≤10s）替代固定 2s，且按 `t.url === url` 精确匹配 page target（排除 about:blank 与残留实例页面）
2. 页面脚本链就绪轮询（≤15s：`readyState === 'complete'` + 本测试用到的 Morrow 7 模块全齐；带节流 debug 日志，失败时可诊断）
3. `killChrome`：SIGTERM 等 exit，4s 后 SIGKILL 兜底；每实例独立 `--user-data-dir=/tmp/morrow-mvp003-<port>`（与日常 Chrome profile 隔离 + 实例标记）；`main()` 退出前按标记清扫孤儿进程并 `rm -rf` 临时目录
4. network 证据修复：原 `network.map(redact)` 把对象 `String()` 成 `"[object Object]"`（**历史缺陷，当年的 network 证据实际不可用**），改为逐条 `url + method` 脱敏——本轮 31 条真实请求入档，首次让该证据真正可用

**验证**：清场（91→0）后 **7/7 ALL PASS ×2 轮（EXIT=0）**，每轮后 headless 残留 0、临时目录残留 0。

## 5. health 7 天频率现状盘点（只读、不等待、不伪造）

- Management API 只读探针结论（本段开工时执行）：**最近 7 天 health agent 成功调度 4 次 ≥ 3**（"滚动 7 天 ≥3 次"标准，工程侧现状达标，未构造任何重复心跳）
- request_id 前 8 位脱敏：`9d45127d` / `b03f1858` / `dea98d29` / `f52fd876`
- 逐次时间戳明细：本会话 PAT 操作未获单独授权（见顶部授权范围），**列为 Review 方可选自查项**（同款 Management API 只读探针，按 request_id 前缀取 `min(created_at)` 即可）
- A27 完整验收（每日调度配置 + 完整 7 天窗 + 运行日志）随段二复核

## 6. 未验证项清单（全部 BLOCKED-OWNER，不假设）

| 项 | 状态 | 说明 |
|---|---|---|
| A17 家机栏 | NOT_RUN / **BLOCKED-OWNER** | 家机浏览器/网络信息 + Pages/本地 HTML 双验证，需凯哥回传（`dual-device-evidence.md` 家机栏已留空，未预填） |
| A17 A记B刷新 / B记A刷新 | NOT_RUN / **BLOCKED-OWNER** | 双机配合项，单侧无法完成 |
| A22 真实手机 | **BLOCKED-PENDING-OWNER** | 320px CDP 断言已双重覆盖（A22）；真机截图待凯哥回传 |
| A26 连续 7 天真实使用 | **PENDING（段二验收项）** | 本段状态为 ENGINEERING_READY 的直接原因；窗口未开始，无任何冒充记录 |
| A27 完整 7 天窗 | 工程侧现状达标（4/7 天 ≥3） | 每日调度配置证据 + 完整窗随段二 |
| health 逐次时间戳明细 | 可选自查（Review 方 PAT 只读） | §5 |
| §2.3 发版对账 + A13 重测 | PENDING（本段 push 后立即补记） | 见 §2.3 |

## 7. 凭据与安全纪律

- keychain `-a morrow` 四条凭据，一律进程内存注入（本次 E2E 复跑经凯哥显式授权）；shell 命令行文本零明文（/tmp runner：keychain → 内存 → 子进程 env，不落盘不打印）
- PAT 对生产库操作超授权范围一处，已按权限策略拒绝并降级 Review 自查（§5），未绕行
- 真实数据零写入：SQL 全事务回滚（mvp004/mvp005-core/key-proofs 零残留核验）；E2E 合成日期 2026-09-30 + `mvp003-e2e-*` / 导出只读
- 输出脱敏：pubkey/password/email redacted（mvp003 37 处、mvp005-ui redact 全量）；存档 JSON 已人工复核无凭据
- dist 凭据扫描：沿用 MVP-005 正则组，t2-secret-scan-clean `[]` PASS（含于 41/41）

## 8. 发给凯哥的一步动作清单

1. **Pages 无需设置**（已启用 workflow 模式；本段 push dist 后自动部署，§2.3 对账由施工方补记）
2. **家机验证**（A17）：浏览器打开 `https://levner01.github.io/Morrow/` → 登录 → 今日面板/热力图/导出各看一眼；把家机浏览器版本 + 网络条件回传 `docs/planning/operations/runtime-environment.md` §5，并填 `dual-device-evidence.md` 家机栏
3. **家机本地 HTML**（A12 同 hash 通道，可选）：从公司机拷 `dist/index.html`（核对 sha256 `58d89c5f…de7c`）→ file:// 打开 → 同上验证
4. **真实手机**（A22）：手机浏览器打开 Pages URL → 截图回传（预留位：`dual-device-evidence.md`）
5. **A记B刷新双机配合**（A17）：公司机记录一锚点 → 家机手动刷新可见；反向一次（合成日期操作前知会，避免与真实数据混淆——或直接用真实当天记录）
6. **7 天真实使用窗启动确认**（A26/A27，段二开工条件）
7. **Review 方**：不采信本收据，独立复跑 §3 全部回归；task-index 翻牌归 Review

## 9. Review 签核区（Review 方填写）

```
独立复跑结果：
ARCHITECTURE ALERT（如有）：
翻牌决定（MVP-006 → PASS/REWORK）：
签字 / 日期：
```
