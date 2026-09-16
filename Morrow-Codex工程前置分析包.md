# Morrow（原：个人生活工作台）· Codex 工程前置分析包

> 角色：Engineering Analyst（前置分析，非架构拍板）
> 读者：Codex（接手架构设计 + 施工规划 + Coding）
> 配套文档：《个人生活工作台 · 产品深度规划 V2》（已合并 V2.1 修订，含版本触发器/防休眠/数据导出/Phase 门禁/今日页视觉验收）
> 项目路径约定：`/Users/wangxinkai/Documents/Morrow`
> 网络实测数据来源：2026-09-14 公司机（M4 Max）curl 实测，非估算。

---

# 1. Executive Engineering Digest

**这个系统是什么**：Morrow 是单用户、多端同步的个人生活数据工作台。核心是 Postgres 里一份属于个人的长期生活事实库（锚点打卡、日型、习惯、健身、Inbox……），Web 是人的第一入口，MCP/HTTP 是 Agent 的入口。终局形态是 Personal Context Server：任何被授权的 Agent（Codex/Hermes/Claude Code 等）都能把 Morrow 当 Tool 用。

**第一阶段真正要解决的**：只有一件事——**让需求方每天真实打卡三个作息锚点**（06:50 起床 / 健身距睡眠 ≥3h / 22:15 关灯），在公司机与家机之间数据一致，失败可感知、可重试、不丢数据。MVP 的全部价值是验证"锚点记录率 ≥80%"能否持续。

**后期会长成什么**：按已冻结的 Phase 路线——MVP 之后长出 Context（复盘/习惯/健身/时间线）、然后长出 Agent Native（MCP/HTTP/Scope/OCC）、然后通知与原生 App、最终成为可导出可迁移的 Personal Context Server。

**不能破坏的约束**（详见 §2 Matrix，此处只列最高优先级）：
- Supabase 免费层 + 无构建链静态 Web，不换栈
- version 由 Postgres 触发器原子递增，客户端禁止 RMW
- 传统端记录级 LWW，Agent 端 OCC（expected_version + idempotency_key）
- 数据必须可全量 JSON 导出，凭据绝不入包
- Agent 不接触 service_role / 用户 Session；语义 Tool，不是 SQL 直通
- Phase 门禁：14 天真实使用 + 锚点记录率 ≥80%，需求方本人判定

---

# 2. Confirmed Decisions Matrix

| 领域 | 已确认决策 | 原因 | 对工程的影响 |
|---|---|---|---|
| 后端 | Supabase（Postgres + Auth + RLS + JSONB），免费层 | 实测：api.supabase.com / supabase.co 双端裸连可用；LeanCloud/Vercel/Workers 实测排除 | 一切服务端能力围绕 Supabase 能力边界设计 |
| 静态托管 | GitHub Pages 优先，fallback 本地双开 HTML | gh 已认证（levner01，代理 10808）可推 | 家机可达性未验证（见 §8.1），页面不得依赖托管端能力 |
| 构建链 | 无构建链，单文件 HTML，SDK CDN | 保证任何 Agent 可直改直部署 | 限制框架选择；PWA/Mobile 属未来压力点（§9） |
| 数据模型 | 通用单表 `life_data` + 基础设施专表 | 单用户规模小、新模块快、免 migration 轰炸 | module 枚举 + JSONB payload 演进规则需 Codex 定（§11） |
| 唯一业务键 | `(user_id, module, entity_key)` | 幂等 upsert 的锚 | entity_key 生成规则是 Codex 决策 |
| 版本原子性 | Postgres BEFORE UPDATE 触发器 `version=version+1`，禁止客户端 RMW | 多端并发竞态已论证 | 触发器 + 并发测试进 Phase 0 DoD |
| 人类同步 | 记录级 LWW（每锚点一条独立记录） | 单人可接受；两机改不同锚点互不覆盖 | 记录粒度＝数据结构设计约束 |
| Agent 写入 | OCC：expected_version + idempotency_key，冲突 409 | AI 用过期 Context 覆盖真实记录不可接受 | 影响所有 Agent 写接口与测试 |
| Auth | Supabase Auth（人类）；Agent 独立 credential | 单人构建，拒绝暴露 service_role | 具体方案是 Codex 决策（§11） |
| RLS | 开启；按用户 + actor 隔离 | 多身份（人/Agent）写同一表 | RLS 策略与 RLS 绕行（service_role）边界进安全审计 |
| Agent Native | MCP + HTTP 双协议，共用业务语义层，禁止 query_database 式 Tool | 多 Agent 复用，schema 变化不破坏 Agent | Tool 命名清单见 §6 |
| 数据主权 | MVP 全量 JSON 导出（schema_version/exported_at/data），无凭据 | Context 可迁移可恢复 | schema_version 机制需 Codex 定 |
| 防休眠 | 常驻 Agent ≥3 次/周（建议每日）真实查询 + 人工 Resume 文档 | Supabase 免费层闲置 7 天暂停 | Keepalive 依赖 §8 中 HEALTH 端点 |
| Phase 路线与门禁 | 0→MVP→1→2→3→4 顺序冻结；14 天 + 80% 记录率 | 需求方锁定，不可协商 | 施工计划不得含"提前开工下一期"方案 |
| 视觉 | 今日页纵向单主轴，"2 秒视线落点"验收 | 已写入 V2.1 | MVP 前端验收标准直接引用 |

---

# 3. Requirement → Engineering Mapping

| 产品需求 | 工程能力 | 关联决策 |
|---|---|---|
| 双机同步 | Supabase 单一事实源 + 记录级 LWW | Matrix：LWW |
| 双机可达 | GitHub Pages vs 本地双开的部署矩阵 + 家机连通验证 | Unknowns §8.1 |
| 每日打卡 | anchor 落库（actual_at/status）+ 连续天数计算 | 连续天数算前端算后端→Codex 决策 |
| 今天该怎么过 | Day Type 数据域 + 默认锚点/任务模板 | §4 Day Type |
| 复盘 | Weekly Review = 对 life_data 的聚合查询 | 高频聚合 → 索引需求（§5） |
| 谁改了数据 | source_type/source_id + activity_log | 所有写路径必须带 actor |
| Agent 提建议 | agent_advice (status/evidence/expires_at) | 建议不混入事实数据 |
| Agent 受控写 | scope + OCC + activity_log，Phase 2 才开 | Phase 0 必须先埋 actor/source 字段 |
| Context 可迁移 | 全量导出 JSON + schema_version | §9 压力点：Restore 语义未定义 |
| 手机 App | Web Core 与 Native Shell 分离（V2 §6 第三阶段） | 无构建链 vs Native 的边界是最大结构压力点（§9.1） |
| 产品不变成收藏夹 | Phase 门禁（14 天 + 80%） | 排期依据，凌驾一切计划 |

---

# 4. Data Domain Inventory

| Domain | 数据性质 | 写入频率 | 主要查询 | 可改 | 需历史 | 删除 | 谁能写 | 关系 |
|---|---|---|---|---|---|---|---|---|
| Anchor | 日级事件 | 低（≤3/天） | 按 biz_date + module 取当日/30 天窗口 | 行级修正（打错时间） | 有（连续计算） | 极少 | Human（+Phase2 Agent） | 驱动热力图/连续天数/复盘 |
| Day Type | 日级配置 | 极低，多为默认 | 查当日 | 可改 | 需（改型影响历史锚点解读） | 否 | Human | 决定锚点目标差异 |
| Inbox | 短生命周期自由文本 | 碎片化 | 未处理列表 | 分类即改 module（形态上是"归档+新记录"） | 处理后转存档 | 是（处理后） | Human；Phase2+ Agent capture | 是待办/待买/锚点备注等的多产出来源 |
| Habit Def | 低频配置 | 极低 | 列表 | 是 | 是（改顺序/形态有历史价值） | 否（软删） | Human | 引用其日志 |
| Habit Log | 日级/计数/数值 | 中 | 按 habit+日期窗口 | 数值可更新 | 是 | 否 | Human（+Agent） | 引用 habit_def |
| Workout | 日级事件 | 低（4/周） | 近 7 天/周统计 | 是 | 是 | 极少 | Human（+Agent） | 影响锚点 2/日型 |
| Shopping | 列表项 | 低 | 未购列表 | 勾/=软删 | 否（或轻历史） | 是 | Human（+Agent add） | Inbox 常见产出 |
| Goal | 长周期 | 极低 | 列表 | 是 | 是 | 否 | Human | Phase 2+，P2 |
| Advice | Agent 生成，人裁决 | Agent 触发 | unread 优先队列 | status 流转 | 是（审计） | 否（expire 即封存） | Agent 写 / Human 裁 | 禁入 life_data |
| Activity Log | 追加型审计流 | 每关键写操作一条 | 时间倒序分页 | 否 | 永久 | 否 | 全 actor | Timeline 数据源之一 |
| Automation | 配置规则 | 极低 | 列表 | 是 | 需（改规则要留痕） | 软删 | Human | 触达 Advice/通知 |
| Agent Client | 凭据/身份 | 极低 | by id | enabled/revoke | 是 | revoke 而非删 | 管理 UI（Human） | 所有 Agent 写的前置 |

---

# 5. Expected Access Patterns

| # | 模式 | 条件 | 结果规模 | 频率 | 实时要求 |
|---|---|---|---|---|---|
| 1 | 取今日全部锚点 | module=anchor, biz_date=today, alive | ≤3 行 | 极高（人+Agent） | 高 |
| 2 | 取某锚点近 30 天 | module=anchor, entity_key 前缀, biz_date 范围 | ≤30 行 | 中（热力图） | 中 |
| 3 | 连续天数计算 | 由 30 天序列前端算 | — | 高（但可离线算） | 中 |
| 4 | 今日 Day Type | module=day_type, biz_date=today | 0~1 行 | 高 | 高 |
| 5 | 近 7 天 Workout | biz_date ≥ today-7 | ≤4 行 | 中 | 中 |
| 6 | 未处理 Inbox | module=inbox, status=unread | ≤20 行 | 中（含 Agent） | 中 |
| 7 | Timeline 最近页 | activity_log 反序分页 | 每页 20 | 中 | 低 |
| 8 | today_context（Agent） | 模式 1+4+未处理数聚合 | 小聚合 | Agent 会话时 | 中 |
| 9 | 锚点 upsert（幂等） | (user_id,anchor,date+时间段) 唯一 | 1 行 | 人类入口最高频写 | 高 |
| 10 | Weekly Review 聚合 | 两模块 7-14 天聚合 | 小 | 周 1 次 | 低 |
| 11 | 全量导出 | 5 表全扫走流式 | MB 级 | 周/月级 | 低 |
| 12 | 防休眠 ping | count 或 /health | 1 | ≥1/日 | 无 |

> 索引提示（非结论）：模式 2 走 (module, entity_key, biz_date)；模式 6/7 需要 status/追增索引。onConflict 目标锁定唯一业务键。

---

# 6. External Interface Inventory

| Read | 人 | Agent | 输入 | 输出 | 权险 | 涉版本 |
|---|---|---|---|---|---|---|
| get_today_context | ✓ | ✓（Phase2） | 无 | 今日锚点/日型/未处理计数 | 低 | 否 |
| get_anchor_status | ✓ | ✓ | date 范围 | 锚点列表+状态 | 低 | 否 |
| get_habit_progress | ✓ | ✓ | habit_id,窗口 | 进度+连续 | 低 | 否 |
| get_weekly_summary | ✓ | ✓ | week 偏移 | 聚合报告 | 低 | 否 |
| get_inbox | ✓ | ✓ | status | 列表 | 低 | 否 |
| get_shopping_list | ✓ | ✓ | — | 列表 | 低 | 否 |

| Write | 人 | Agent | 输入 | 输出 | 权险 | 版本 |
|---|---|---|---|---|---|---|
| check_anchor(upsert) | ✓ | ✓ P2 | anchor_type actual_at | 记录 | 篡改历史（Agent）| ✓ |
| record_workout | ✓ | ✓ P2 | type duration note | 记录 | 低 | ✓ |
| capture_inbox | ✓ | ✓ | 文本 | inbox 记录 | 低 | 词面 |
| add_shopping_item | ✓ | ✓ P2 | item | 记录 | 低 | 词面 |
| update_advice_status | ✓ | 否 | advice_id,新状态 | 状态 | Agent 不可自我裁决 | ✓ |

| Advice | | |
|---|---|---|
| submit_advice | 否 | ✓ P2 | topic/title/reason/evidence/priority | advice 记录 | Agent 只能提交，不能 accepted | ✓ |

| System | | |
|---|---|---|
| export_full_data | ✓ | — | — | JSON 流 | 不能含凭据 | — |
| health/keepalive | — | ✓ | — | 200 + db_count | 只读 | — |
| client_manage(register/revoke) | ✓ | 否 | name/scopes | — | 特权管理，仅限人类 | — |

---

# 7. Security Boundary Map

**身份**：Human (Supabase Auth Session) / Browser / Mobile (future) / Agent (独立 token) / Supabase / Application Core / MCP (future local) / HTTP API (future remote)。

**信任流**（Codex 需强化的方向）：

```text
Human → (Auth session + anon key) → Supabase
Agent → (独立 token + scope) → Application Core → Supabase   ← 不直连 DB
Application Core → (service_role，仅服务内) → Supabase
```

**禁止项（红线复述）**：
- Agent 永不接触 service_role、Human Session、邮箱密码；Token 必须 scoped + 可 revoke
- 页面 / 导出 / 日志任何一处的 payload 不得包含 token/secret；导出逻辑与 agent_clients 表严禁组合出敏感字段
- service_role 仅存在于受信服务端（当前候选：Supabase Edge Functions 或受信本机进程），绝不进静态页面、绝不进 git 仓库

**升权/绕行风险**：
- anon key 是浏览器可用的事实前提 → RLS 必须默认拒绝匿名读写；验收：未登录请求全部 4xx
- activity_log 必须防 agent 伪造 actor：actor_type 与凭据绑定，不由请求参数自报
- activity_log 只允许 INSERT（append-only），RLS 需显式禁止 UPDATE/DELETE
- Supabase Functions 若持有 service_role（Keepalive 目标），必须限只读白名单 + 调用审计
- 未来 Remote MCP host 上线后即成为公网触点，白名单 + rate limit 不可缺

---

# 8. Engineering Unknowns

## BLOCKER

### U1｜GitHub Pages 家机可达性
- **为什么**：双机互通的唯一部署方案依赖它；没验证前是一切托管的假设
- **后果**：不验证 → 家机可能根本打不开 Web，双机同步沦为伪命题，MVP DoD 无意义
- **验证**：`curl -so /dev/null -w "%{http_code} %{time_total}s" --connect-timeout 5 --max-time 8 https://<user>.github.io/<repo>`，家机执行一次即可
- **成功**：Pages 可用，MVP 使用完全体
- **失败**：fallback 本地双开 HTML 为主通道（MVP 允许），或在需求方家机布代理作为后置修正

## HIGH

### U2｜无构建链的 PWA/Service Worker 上限
- **背景**：PWA Phase 3（通知/离线壳）与无构建链存在摩擦，重要性中等，Phase 0 需预留
- **验证**：写个没有 build step 的 manifest + 简单 sw.js，在 macOS Safari / iOS Safari 实测 install + 通知权限
- **成功**：无构建链继续可行；失败 → PWA 阶段引入 Vite (结构变为“轻构建链”), 架构决策前移到 Phase 0（影响选型）

### U3｜Application Core 的放置边界（Local First or 服务端）
- **背景**：Agent Native 需要一个业务规则实体与 RLS 相互支撑。当前最可能最概：Phase 2 起该模块用 Supabase Edge Functions（ig Web 直接调用其转接）
- **验证**：写最小 Edge Function（一个只读查询），在公司网络与家网下实测连通、冷启动、配额（500K invocations 内的阶段需求评估）
- **失败**：Core 移至受信本机 + Tunnel（复杂度升级），需早期预警说明

## MEDIUM

### U4｜entity_key 生成规则冲突未拍
- **例如**：anchor 的 entity_key=`anchor:wake:2026-09-15`，or `2026-09-15:wake`？关系到 upsert 语义/未来复用度
- **后果**：Phase 0 用两套 key 会造成数据对不上，历史历史遗留字段
- **最低验证**：Codex 决策前拉一张表列所有 9 种 module 的 key 模板，人工复核（无代码依赖）

### U5｜导出数据量的前端上限
- 单人 2-3 年数据量是否有浏览器内的性能风险未知
- **验证**：等积累到 Phase 1 后实测一次全流+json验证 count；MVP 内用全量并行 fetch 而非文件式手动然后页面压测电量

## LOW

### U6｜家机代理可用性（Pages 不可达时的网络层兜底）
- **为什么**：U1 验证失败时的降级路径是"家机走代理访问 Pages"，家机代理配置现状未知
- **验证**：家机执行 `curl -x http://127.0.0.1:10808 ... https://<user>.github.io/` 一次
- **成功**：代理兜底成立；**失败**：本地双开 HTML 为主通道，Pages 仅公司机使用
### U7｜Activity log 的 UI 存档通道
- Timeline 的 UI 化属于 Phase 1；Phase 0 只保证表结构 + append-only，不建页面
---

# 9. Architecture Pressure Points

| # | 压力点 | 为什么 | 忽略后果 | Phase 0 至少要预留 |
|---|---|---|---|---|
| 1 | **无构建链 vs PWA/Mobile** | PWA 要求打包边界，Native 要求模块化 Web Core | 进入 Phase 3 时被迫引入构建链 → 重写前端 | 现在就把 Web 分层为"核心逻辑模块（无依赖）/ 页面壳"，写死“单文件入口 + 纯 JS module 化"纪律 |
| 2 | **JSONB vs Queryability** | 复盘需要 query（日期/状态），JSONB 里随意长出结构会失控 | 每次 Review 全表扫一遍 → 免费层变慢 | payload 内字段命名纪律写进 PRD；biz_date/version 等高频字段必须真正入库列（如 V2 schema 前 10 字段） |
| 3 | **payload 内没有 payload_version** | Schema 演进后旧 payload 歧义 | 导入/迁移失败，Business Break | payload JSONB 顶部加 `payload_v:1`，导出顶层 schema_version 同步 |
| 4 | **Web 直连 Supabase vs Agent API 分层** | 人类走 RLS+anon，Agent 走 Application Core+OCC | 两个通道各自为政 → 语义分裂 | Phase 0 就在业务规则 Core 中抽函数（一个 Core，两套皮），明确"Web 不做业务规则复算" |
| 5 | **Local MCP → Remote MCP** | Hermes 本机能跑 local MCP，Remote MCP 进 real Deployment 需多点 | Phase 2 to Remote 时 MCP 全部重写 | Local MCP 设计阶段就禁所有 "localhost only" 语义；备份方案：Phase 2 初步骤记"Local first, Remote 白名单" |
| 6 | **Human LWW 与 Agent OCC 并存** | 两套写策略导致写路径气质分裂 | 后期分叉/测试成本爆炸 | 写路径统一为 upsert_with_conflict（策略分支由 actor/token 类型决定） |
| 7 | **Agent Token 生命周期** | revoke 后 token 如何失效需要真实实现方案 | 泄露不可回字典 | agent_clients 表的 revocation 必须落地为"Phase 2 前至少手 revoke 一次的演练" |
| 8 | **RLS 测试覆盖** | RLS 策略很容易为"先跑起来"绕过 | 安全性形同虚设 | Phase 0 DoD 增加"匿名读/写均 4xx 拒绝"验收 |
| 9 | **schema_version 全局** | 导出仅能目测不声明 schema；无表内/payload 两级 | 导出不可 Restore | 表级 schema_version + payload_v + 导出文件的三级版本登记 |
| 10 | **Timeline 增长无上限** | activity_log 永久追加 | Partitions 必要但早期不必做 | 只需预留：Timeline 读取 always-limit+cursor（无 limit 全量拉）；表不直升 |
| 11 | **Export↔Restore 不对称** | 全项目只设计了 Export | Context 沦为"可备份不可重生" | Phase 0 必须声明 Restore = never in-sprint（明确不做），但文件格式必须为将来 Restore 可解析（无凭据 + schema_version） |
| 12 | **Keepalive"真查询"** | 仅 ping 静态页面不会护住 Supabase | 免费项目仍会暂停 | /health 必须真实 sample select 1 或 count(*) 验证 |

---

# 10. Phase Dependency Map

```text
Phase 0（基础设施）
  ├→ MVP（锚点+今日+同步）
  │     ├→ Phase 1（Context）
  │     │     └→ Phase 2（Agent Native）
  │     │           └→ Phase 3（Rule/Notification/PWA/Mobile）
  │     │                 └→ Phase 4（Calendar/Health/扩展 Context）
  ...
Phase 2 依赖 Phase 0：
  actor/source 字段（已有 schema 就位）
  version 触发器（Phase 0 DoD 已保证）
  activity_log 表结构
  Application Core 抽象层（Web 直连也要走它）
Phase 1 依赖 MVP：在锚点真实记录存在后才能算复盘/习惯相关组件的正确性

必须现在(Phase 0)就预留：
- actor/type/source 字段（Agent Native 需要，没它 Phase 2 重写 DB）
- activity_log 表结构（哪怕只有 Human 也会写）
- version 触发器（OCC 靠它）
- payload_v（JSONB 演进需要）
- /健康接口（防休眠依赖）
- 导出函数骨架（MVP DoD 必须）

可以以后再做：
- Habit/Workout 具体表结构扩展（Phase 1 前）
- Advice/Client 表的任何写权限（Phase 2 前）
- PWA manifest（Phase 3 前）
- Mobile Native Shell 全链路（Phase 3 后）
- Automation Rules Engine（Phase 3 前）
```

---

# 11. Codex Decision List

以下为"必须由 Codex（架构师角色）拍板”的问题，产品侧不介入：

| # | 问题 | 背景与已知约束 | 可选方向 | 影响面 |
|---|---|---|---|---|
| D1 | Application Core 部署边界 | Phase 2 之前即存在（Agent 接属需它）；不引入重型 backend | A) Supabase Edge Functions; B) 受信本机 + Web 直读；C) 两者混合 | 所有 API/MCP/R_S 设计 |
| D2 | Agent Credential 实现形态 | need scope/revoke/log | A) Supabase Auth 自建 JWT; B) 自建 API Token 表；C) MCP 内嵌 OAuth flow | 全部 Agent 接口 |
| D3 | Local MCP Server 技术结构与打包方式 | Hermes/Trae 可以跑 Python MCP，Morrow 需 SDK 分发 | Python `mcp` SDK / Node / 无 SDK 纯 HTTP | Codex 接入体验 |
| D4 | HTTP Agent API Host | Remote 入口尚未存在 | Supabase Functions / GitHub Pages 站点 / Future Mobile(WKWebView 受信) | 所有远端 Agent |
| D5 | JSONB payload 内每 module 的最小合同 | 决定数据库可维护性 | A) 严格 per-module JSON Schema; B) 只定公共头（payload_v 等），body 自由 | 导出/复盘/Agent Tool 的稳定度 |
| D6 | 连续天数计算责任层 | 前端算 vs 服务端算 vs 聚合表 | A) 前端（简单，不共享）；B) PG function（可导出） | 复盘/热力图/Agent summary 一致性 |
| D7 | 导出文件的 Restore 语义 | Phase 0 只规定导出格式 | Restore 视为后置，还是导出即全项目迁移承诺 | Phase 4 边界 |
| D8 | PWA 离线数据一致性策略 | MVP 不做离线 sync；Phase 3 通知+离线壳 | A) 只读离线缓存；B) 写暂存队列 | Phase 3 节奏 |
| D9 | Application Core 的语言/Runtime 选型 | Local-first 场景下 Edge Functions 是 JS/TS；若 Core 未来移到受信本机，语言需与 Local MCP 一致 | A) 全 JS/TS（Web 与 Edge 同语言）；B) 本机部分 Python（与 Local MCP 统一） | 全模块接口一致性、与 D3 联动 |

---

# 12. Codex Handoff

## Codex Handoff

**项目**：Morrow —— 单用户、多端同步、Agent Native 的个人生活数据工作台。终局形态 Personal Context Server：Web/PWA/Native 是人入口，MCP/HTTP 是 Agent 入口，Supabase 是唯一事实底座，锚点打卡是当前阶段唯一留存验证目标。

**当前阶段**：Phase 0（基础设施）。Phase 路线（0→MVP→1→2→3→4）与推进门禁（连续真实使用 ≥14 天 + 锚点记录率 ≥80% + DoD 全过）冻结，非协商项。

**已确认不可违反的约束**：
- Supabase 免费层 + PostgreSQL + Auth + RLS + JSONB；不更换
- 静态 Web 无构建链，单文件 + CDN SDK
- `life_data` 通用表 + 基础设施专表，唯一键 `(user_id, module, entity_key)`
- `version` 由 Postgres 触发器原子递增，禁止客户端 RMW
- 人类端记录级 LWW；Agent 端 OCC（expected_version + idempotency_key）
- MVP 必须包含全量 JSON 导出，不含任何凭据
- Agent 不接触 service_role / 人的 Session / 邮箱密码；Tool 全部业务语义化，禁止 SQL 直通
- Phase 0 至少一个常驻 Agent keepalive：≥3 次/周（建议每日），必须真实查库
- 书影音、泛减脂、记账、Locations/Health —— 当前全部不做

**关键风险**：
1. GitHub Pages 家机可达性未验证（BLOCKER §8.U1）
2. 无构建链不妨碍 Phase 3 PWA（§9.1）
3. JSONB 演进 vs Queryability（§9.2）
4. RLS 匿名/越权测试缺失会直接瓦解安全设计（§9.8）
5. Export 只设计了单向、Restore 语义未决（§9.11）

**未决问题**：见 §8（Unknowns）与 §11（Codex Decision List）。重点：Application Core 部署边界（D1）、Agent Credential 实现（D2）、Local MCP 结构（D3）、payload 合同（D5）、连续天数计算层（D6）。

**接下来的输出，请按此顺序**：
1. 系统技术架构（Web/Core/MCP/HTTP 的部署边界）
2. Repository 结构（`/Users/wangxinkai/Documents/Morrow`）
3. Database 终版 Schema（含触发器、RLS、索引）
4. Application Core 模块与接口契约
5. Auth/RLS/Agent Auth 实现方案
6. MCP Tool Schema + HTTP Endpoint 设计
7. 同步策略+ 测试设计（含 U1 验证）
8. Phase 0 + MVP 施工计划（任务列表 + DoD + Agent 分工）
9. Definition of Done 逐条可执行测试清单

**可直接使用的材料**：
- 表结构可直接起手：`life_data.sql` 骨架见本会话下划线产物
- Keepalive 防休眠 cron 设计（Hermes）需要 /health 接口——完全按 §6 System 清单设计
- 视觉验收：今日页"2 秒视线落点"标准（V2.1 §1.2）、Phase 门禁（V2.1 §8）、防休眠方案（V2.1 §6.4）

**建议 Phase 0 DoD 复核清单**（供 Codex 直接转化为 Test Case）：
- [ ] 未授权(anon/未登录)请求 → 全部 4xx，RLS 零 bypass
- [ ] 公司机 + 家机两条访问路径均可用（fallback 已验证）
- [ ] 任何写入 actor 可追溯（activity_log 有 actor_type/source_type）
- [ ] Supabase 失败（断网/限流）→ 前端降级 + 明确报错+ 重试按钮（白屏 = 失败）
- [ ] Agent 协议 v1 冻结（Tool 命名/expected_version/幂等元语）
- [ ] Keepalive cron 实际上跑一周不 pause
- [ ] 触发器并发双写测试：同 id 同 epoch 两次 UPDATE → version 无重复
- [ ] 全量导出 JSON 且 schema_version 全交给外部强 verify 工具
- [ ] 视觉验收：进入今日页 2 秒内，视线首先落在锚点区

---

一旦你确认这 9 条 Phase 0 DoD，在 `/Users/wangxinkai/Documents/Morrow` 初始化 repo，可以直接进入产出。
