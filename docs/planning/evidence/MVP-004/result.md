# MVP-004 result — 30 天热力图与不失真的记录统计

> 执行：Trae + Kimi-K3（施工）｜Review：Hermes + DeepSeek V4 Pro / WorkBuddy + Hy4（签核区留空）
> 任务卡：docs/planning/tasks/MVP-004.md｜施工提示词：Trae-MVP-004施工提示词.md
> 核心红线：统计数字永远不能说谎（记录率≠达标率、45 天连续不裁 30、interval unknown 不伪装达标、历史补记重算）

---

## 1. 交付范围与决策留档

### 1.1 决策：stats 不改 Context RPC 形状（红线 3）

- `get_today_context_v1` 顶部形状与 `result.stats` 既有字段**零改动**（0013 函数体未 REPLACE）。
- 扩展统计（met_rate / recorded_late_count / today_complete / today_provisional / tracking_started_on）与 30 天逐日投影**由新 RPC `get_anchor_history_v1` 承载**（C-05 合同面 P0 链已预置 schema+fixture，本卡零新增 contract、manifest 零改动）。
- 依据 MVP-001 result.md §决策留档：stats 扩 result 内部字段可以、不新增顶部字段。本卡连 result.stats 内部也未动——今日页顶部 streak 沿用 context.stats（0013 已验收算法），热力图区文本用 history 的 extend stats。两处数字**同一事实源**：0014 `mvp_stats_extend` 复用 0013 `mvp_stats` 基础窗口统计，仅叠加扩展字段与独立 streak walk（下界 tracking_started_on）。

### 1.2 决策：migration 0014 纯新增、零 REPLACE

- 新增 `private.mvp_heatmap_30` / `private.mvp_stats_extend` / `private.cmd_get_anchor_history_v1` / `public.get_anchor_history_v1` + grants（照 0013 纪律：authenticated 可 EXECUTE invoker，private 全 revoke）。
- 不碰 0001–0013 任何行。理由：REPLACE `cmd_get_today_context_v1` 有函数体漂移风险，且 MVP-003 刚以其为基线全绿。
- streak walk 独立重算、**下界 `p_settings.tracking_started_on` 而非 p_from**——30 天窗口不裁剪连续天数（F09），walk 上界 400 天保耗（施工提示词 2.1）。

### 1.3 语义对账（C-03）

| 规则 | 实现 | 测试 |
|---|---|---|
| F09 45 天连续不被 30 天窗口裁剪 | streak walk 至 tracking_started_on | T01：铺 45 天全记录 → streak=45 |
| F12 次日 12:00 结算；未结算未完成=provisional 不断链 | `settled = now >= (d+1) 12:00+08:00`；walk 遇未结算未完成跳过 | T02a：断链墙后 streak=8 + today_provisional=true；T02b：补全今日 → 9 |
| F14 迟到 actual 仍计 recorded 分子；记录率≠达标率 | recorded 计 planned∧actual≠null；met 另计 actual≤target；recorded_late_count 独立 | T03：全迟到 → recording_rate=1 / met_rate=0 / late=2 |
| F10 未访问日计分母 | 分母来自 resolve_day_plan 历史计划，不依赖 life_data 存在 | T04：planned=7 / recorded=2 |
| 非训练日分母 2 | workout_expected=false → denominator=2 | T05 |
| F06 interval unknown 不伪装达标 | 训练日 w/l 缺一 → unknown，不计 met | T06：interval_met=0 / unknown=1 |
| 历史补记重算（一处事实源） | Core 每次读实时计算，零缓存 | T07：补记昨日 → streak 2→3 |
| 未开始日无分母 | resolve_day_plan null → denominator=0 / not_started | T08b |

---

## 2. migration 0014 应用证据

- 文件：`supabase/migrations/20260928100000_0014_heatmap_stats.sql`
- 应用：Management API `POST /database/query`，HTTP 201（2026-09-28 应用成功）

## 3. Core 验收：tests/mvp004-stats-core.sql — 13/13 PROOF 全绿

运行方式：单 DO 块提交，末尾 RAISE EXCEPTION 携带 MVP004_PROOF JSON（HTTP 400 为预期成功信号），全部写入随事务回滚。原始输出存档：`stats-core-proof.json`。

```text
HTTP 400
ERROR: P0001: MVP004_PROOF [
  {"T00_setup":"pass","owner":"0c645909-…","today":"2026-09-28"},
  {"T01_F09_streak45":"pass","streak_days":45,"window":"30d","recording_rate":"1.0…"},
  {"T02a_F12_provisional":"pass","streak_days":8,"today_provisional":true},
  {"T02b_F12_complete_plus1":"pass","streak_days":9},
  {"T03_F14_late_counts_recorded":"pass","recording_rate":"1.0…","met_rate":"0.0…","recorded_late_count":2},
  {"T04_F10_unopened_in_denominator":"pass","planned_count":7,"recorded_count":2},
  {"T05_nonworkout_denominator2":"pass"},
  {"T06_interval_unknown":"pass","interval_met_count":0,"interval_unknown_count":1},
  {"T07_history_backfill_recompute":"pass","streak_before":2,"streak_after":3},
  {"T08_heatmap_shape":"pass","days":30,"first":"2026-08-30","last":"2026-09-28"},
  {"T08b_not_started":"pass"},
  {"T09_validation":"pass","reject_future":true,"reject_span":true,"reject_inverted":true,
   "reject_unknown_field":true,"cursor_accepted_null":true},
  {"T10_public_rpc_owner_denied_readonly":"pass"}]
```

**零残留核验**（回滚后真实库）：

```text
HTTP 201
[{"tracking_started_on":"2026-09-21","mvp004_rows":0,"orphan_audit":0}]
```

### 3.1 过程发现（三轮返工全记录，不删旧账）

1. **actor_context_missing**：T00 裸 UPDATE workspace_settings 触发 `trg_settings_before_update → current_actor()`。修法：DO 块内 `perform private.cmd_set_actor('human', v_owner)`（0008 GUC `morrow.actor`）；request_id 可空（trigger 内 nullif 处理）。附带事实：`trg_life_data_bi` 以 actor 覆写 source_type/source_id，synthetic 行仅靠 entity_key `mvp004test:%` 识别。
2. **life_data_payload_v_chk 23514**：synthetic payload 顶层键写成 `v`，约束要求 `payload_v`（0002）。批量修正。
3. **T08 时刻敏感断言**：原断言"昨日次日 12:00 未到不得 settled"只在 12:00 前成立；运行时 13:56 Asia/Shanghai 昨日已结算。修为动态对账（`settled == (now >= today 12:00)`）+ `provisional == not settled`，任意时刻可跑。
4. **T09 JSON null vs SQL NULL**：jsonb `'null'::jsonb is not null` 恒真导致误判。修为 `-> 'next_cursor' <> 'null'::jsonb` 且键存在。

## 4. UI 验收：tests/mvp004-heatmap-ui.js — 19/19 PASS（真实浏览器 CDP，只读纪律）

- 页面：`http://127.0.0.1:8094/dist/index.html`（发行 `mvp-004-edb0943523b8`）；真实 JWT 登录；**零写 RPC**（context/history 只读，真实数据红线遵守）。
- 原始结果：`ui-e2e-results.json`；截图：`heatmap-1280.png` / `heatmap-375.png` / `heatmap-320.png`（整页捕获）。

```text
PASS  core-rpc-ok / core-days-30 / core-revision-string / core-next-cursor-null
PASS  dom-cells-30 / dom-range-match(2026-08-30..2026-09-28) / dom-today-marked
PASS  dom-all-aria（每格文字补充）/ dom-legend-6 / dom-states-present{notstarted:22,empty:8}
PASS  dom-anchor-first（三锚点主轴在热力图之上）
PASS  reconcile-streak / reconcile-recording-rate / reconcile-met-rate（DOM 与 RPC 逐一对账一致）
PASS  rates-separated（记录率 0% · 达标率 0% 分离显示）
PASS  viewport-1280-no-hscroll / viewport-375-no-hscroll / viewport-320-no-hscroll
19/19 PASS，0 FAIL
```

**真实数据如实性**：窗口 2026-08-30..2026-09-28，tracking_started_on=2026-09-21 → 22 格 not_started（虚格无数字）+ 8 格 empty（灰，09-23 的 0/3 与 09-24 使用痕迹均属实——recorded=0 即灰格，未访问日照画不跳过）；streak=0、两率 0% 如实投影；今日格蓝框+虚线在途，附文案"完成今日全部记录后，连续天数 +1"。

### 4.1 过程发现（UI 轮）

- 首跑"今日页渲染"超时：`setCurrentUser` 只设变量不渲染 shell；E2E 需与 app.js 真实登录路径一致显式 `ui.showShellPanel(user)`（MVP-003 场景 1 只查 sync-badge 未暴露此差异）。
- Chrome headless 在沙盒内无法写 profile 目录，E2E 需非沙盒执行。

## 5. dist 与三处同步自查（红线 1/2）

```text
[package-html] release mvp-004-edb0943523b8
[package-html] dist/index.html sha256 fb2de2566fa6c36d88c91fa2c51ff05016f720f8642e30fa9b2fe487316e0a42
REPRODUCIBLE: PASS（第一次 --check）
REPRODUCIBLE: PASS（第二次 --check）
```

新增 `assets/js/heatmap.js` 三处同步：

| 位置 | 内容 |
|---|---|
| `index.html` script 链 | ui.js 之后、today.js 之前 `<script src="assets/js/heatmap.js">` |
| `scripts/package-html.js` JS_FILES | 同序插入 `'assets/js/heatmap.js'` |
| 文件本身 | `assets/js/heatmap.js`（本卡新增） |

today.js 挂载：`<div id="heatmap-host">` 位于日型切换入口**之后**（次要位置），`Morrow.heatmap.mount` fire-and-forget 不阻塞主区，组件内错误独立兜底+重试按钮；三锚点/下一步主区零改动。

## 6. 验收五条逐条对照

- [x] **45 天连续返回 45**（T01）；**当天未完成不归零**（T02a streak=8 含在途今日语义）；**次日 12:00 结算固定**（T08 动态对账 + T02）
- [x] **30 个工作区日期含今日**（T08 + dom-range-match）；**未开始/未计划/漏记录三态区分**（五态 cellState + T08b + dom-states）；**间隔 unknown 不伪装达标**（T06）
- [x] **记录迟到仍计分子；记录率≠达标率分离显示；没打开的日期照算分母**（T03/T04 + rates-separated）
- [x] **修改历史事实触发重算**（T07 streak 2→3）；**UI 只展示 Core 结果**（reconcile-* 三项 DOM=RPC）
- [x] **颜色有文字补充**（dom-all-aria + legend-6）；**手机无横向滚动**（375/320 截图 + scrollW 断言）

## 7. 凭据与红线自查

- PAT / publishable key / owner 凭据均 keychain `-a morrow` 注入，零落盘零明文；E2E 输出经 redact（email/password/key）。
- 真实数据零写入：SQL 测试全回滚（零残留核验通过）；UI E2E 只读 RPC。
- contracts/manifest 零改动（history schema+fixture P0 链已登记）；0001–0013 migration 零改动；task-index 未碰（PASS 归 Review 方）。

## 8. 待验证（Review 方）

- [ ] 复跑 `tests/mvp004-stats-core.sql`（Management API，proof 应与 §3 一致；T08 动态断言任意时刻可跑）
- [ ] 复跑 `tests/mvp004-heatmap-ui.js`（keychain 三凭据 + SUPABASE_URL 注入；需非沙盒/本机 Chrome）
- [ ] 视觉复核：heatmap-1280/375/320.png 五态与图例、色弱可读、热力图不抢三锚点注意力
- [ ] 真实使用观察：今日完成三锚点打卡后 streak/记录率跳动是否符合直觉（建议纳入 7 天真实使用）

## Review 签核区（留空，归 Review 方）

- 结论：
- 签核人 / 时间：
- task-index PASS 执行人：
