# MVP-002 执行回执：三锚点今日行动页

日期：2026-09-23 · 执行：Trae + Kimi K2.8 · 状态：**待 Review（WorkBuddy+Hy4 视觉 / Hermes GLM-5.3 业务）**

## 交付概要

今日页（产品首个真实 UI）落地：日期/日型 → 三锚点（起床 06:50 / 健身结束 19:15 / 关灯 22:15）→ 唯一下一步 → 日型入口，纵向单主轴。全部交互走真实 RPC（transport 通用 rpc 通道，C-04 信封），前端零业务计算，达标/连续/下一步全部渲染 Core 投影。非训练日第三行 n/a 弱化保留不伪造。

## Commit

| commit | 说明 |
|---|---|
| `0ec78d6` | MVP-002: 三锚点今日行动页——transport 通用 RPC 通道 + today 模块 + 响应式与可访问性实测 |

push：`94eda28..0ec78d6 main -> main`（先 `git pull --rebase`，up to date；push 单次注入本地代理，未改全局）

## 变更文件

- `assets/js/transport.js`：+`rpc(fn, input)` 通用业务 RPC 通道（与 verifyOwner 同信封协议；业务拒绝收敛 `ok:false + code/message`）
- `assets/js/today.js`（新）：今日页全部逻辑（渲染/打卡/修正/清空/日型/向导/对话框/有限 optimistic）
- `assets/js/ui.js`：登录壳 → 业务壳（`#today-host` aria-live，渲染后启动 today）
- `assets/js/app.js`：boot() 补挂 `morrow-booted`（修复兜底横幅常驻的 P0 存量缺陷）
- `assets/css/app.css`：今日页样式（五列对齐、≤560px 两行降级、44px 触控、对话框/向导）
- `index.html`、`scripts/package-html.js`：挂 today.js（源码 + dist 双通道）
- `dist/index.html` + `dist/release-manifest.json`：重打，sha256 `5e354ff8673931a158c2220bd8a07cf40103da7e1bb9d6ac0ba4b54a437e8d88`，两次构建一致
- `tests/mvp002-{smoke,visual,file,pages-probe}.js`（新）
- 本目录全部证据文件

**未动**：migration / DB 函数 / contracts / transport 协议层（仅新增）/ task-index。

## 测试命令与原始输出

### 1) 源码模式烟测（真实凭据 env 注入，keychain → env → 内存，零落盘）

```bash
SUPABASE_PUBLISHABLE_KEY=$(security find-generic-password -s MORROW_PUBLISHABLE_KEY -a morrow -w) \
MORROW_OWNER_EMAIL=$(security find-generic-password -s MORROW_OWNER_EMAIL -a morrow -w) \
MORROW_OWNER_PASSWORD=$(security find-generic-password -s MORROW_OWNER_PASSWORD -a morrow -w) \
node tests/mvp002-smoke.js
```

全量 10/10 通过，终端原始输出留档 [smoke-full-run-terminal.txt](smoke-full-run-terminal.txt)。关键行：

```
PASS  S1_anchor_order_and_targets  — order=wake,workout_end,lights_off; targets=06:50,19:15,22:15
PASS  S4_check_anchor_persisted  — wake actual=18:57; status=已记录
PASS  S5_edit_anchor_lww  — wake=06:50; Core 投影 met=达标
PASS  S6_reload_persistence  — refresh 后 wake actual=06:50
PASS  S7_clear_anchor  — 确认文案="只清除实际记录，今日计划与记录分母保持不变。"
PASS  S8_day_plan_locked_shown  — error="更改日型失败：当日计划已锁定：只允许追加训练，不能减少或改型"
PASS  S10_network_remote_clean  — 远程 0；supabase 调用 23 条
```

S9 硬化复验（`SMOKE_SKIP_WRITES=1`，快照旧文本→等待文本变化再断言）：`error="打卡失败：实际时间不可为未来"`，见 [smoke-s9only-output.json](smoke-s9only-output.json)。Core 直接拒绝报文（curl 探测、校验拒绝零持久化）：`VALIDATION_FAILED "实际时间不可为未来"`。

### 2) 响应式 / 200% 缩放 / 键盘（headless Chrome CDP 实测）

`node tests/mvp002-visual.js` → [responsive-matrix.json](responsive-matrix.json)：320/375/390/768/1280 五档 `scrollWidth <= innerWidth` 全 true；`375 @200% text` 无横向溢出；键盘行 `tab_reaches_wake_check / focus_visible_ring / target_ge_44px` 全 true。截图：shot-1280-today.png、shot-1280-dialog.png、shot-375-today.png、shot-375-dialog.png、shot-textzoom200.png、shot-keyboard-focus.png。

### 3) file:// 断网行为

`node tests/mvp002-file.js` → 4/4，见 [file-mode-output.json](file-mode-output.json)：file origin 探针如实显示；断网刷新出 `failure-panel kind=network` 显式错误；断网期间 supabase 出站仅 1 条，无自动重放风暴。

### 4) Pages 模式等价

- served hash = local dist hash（`5e354ff8…e8d88`），HTTP 200 redirects=0
- `node tests/mvp002-pages-probe.js` → `PASS PAGES_equiv — order=wake,workout_end,lights_off; targets=06:50,19:15,22:15; next="记录起床"; boot-fallback hidden=true`
  （探针末尾 profile 目录清理 rmdir 竞态报错为 runner 收尾瑕疵，不影响断言，已实判 PASS）

### 5) dist 可复现

`node scripts/package-html.js --check` → `REPRODUCIBLE: PASS`

## 五条验收逐条对应

| # | 验收 | 证据 |
|---|---|---|
| 1 | 2 秒注意力：先三锚点，其次唯一下一步；无卡片海/虚构 AI | shot-1280-today.png 单主轴；S1/S2 |
| 2 | 打卡/修正/清空/改日型真实持久化，错误如实显示 | S4–S8 + S6 刷新回显；S8/S9 错误文本=Core message |
| 3 | 320/375/390/768/1280 无横向溢出；200%/键盘/focus/触控 | responsive-matrix.json + 6 张截图 + accessibility-notes.md |
| 4 | 训练 19:15 目标；实际与目标状态分离（前端零计算）；非训练日不伪造 | S1 目标列；S5 met 取自 Core 投影；n/a 行 `.anchor-row-na` 弱化保留（代码路径 today.js anchorRowHtml） |
| 5 | 初始训练日显式两步向导；导航无未来空页面 | today.js renderWizard（tracking_started_on + 周训练日 → initialize_workspace_v1）；今日页无日期导航（页面只有「今天」） |

## 真实数据写策略声明（按卡六执行）

- 写类 RPC 只对 2026-09-23 做了一组显式验证：打卡 wake(18:57) → 修正 06:50 → 清空，**最终复原未记录原状**。
- 日型切换走真实路径但被 Core 拒绝（DAY_PLAN_LOCKED），零数据变更；未来时间打卡被拒绝（VALIDATION_FAILED），零持久化。
- S9 硬化复跑使用 `SMOKE_SKIP_WRITES=1` 跳过写序列；其余复跑均为只读。
- record_open 每次页面加载即发（标准行为），device_id 为 localStorage 生成的去重标识。

## 问题与修复（本次施工发现）

1. **boot-fallback 横幅常驻**：`html.morrow-booted` 类无任何代码挂载（P0 存量缺陷），导致每个正常页面顶部显示「资源加载失败」。已在 app.js boot() 首行挂类，语义自洽（JS 已运行即 CSS/JS 均生效）。属 MVP-002 范围内的 shell 缺陷修复，未超范围。
2. **S9 断言偏弱**：首跑把 S8 残留错误当 S9 结果。已硬化（快照+文本变化断言）并复验，结果一致。
3. 直接 RPC 探测发现 input 必填 `biz_date`、idempotency_key 必须 UUID 形态——today.js 实现已符合（从 context 取 biz_date、crypto.randomUUID）。

## NOT_RUN / 边界

- 向导（WORKSPACE_NOT_INITIALIZED 路径）：真实 workspace 已初始化，该路径仅有代码审查证据，**未做端到端实测**（新建工作区会污染真实库）。标 NOT_RUN。
- VoiceOver 全量播报走查 NOT_RUN（headless 环境），键盘可达性已实测替代。
- 暗色模式逐张截图未做（token 级对比度已列 accessibility-notes.md）。
- 家机（leo）Pages 复核：沿用 P0-008 交接命令，本卡未新增家机证据（P0-008 遗留 PENDING 不变）。

## 待验证 / 下一步

- Review 方核对五条验收与证据；task-index MVP-002 → PASS 由 Review 方翻转。
- P0-008 遗留：家机 leo Pages curl 复核输出贴回 P0-008 deployment-evidence.md §7。

## Review 签核区（执行方不填）

（留空）
