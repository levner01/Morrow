# P0-007 任务收据｜注册 health-only Agent 并实际运行常驻 Keepalive

- 任务卡：`docs/planning/tasks/P0-007.md`
- 执行：Trae + Kimi K3，2026-09-21（Asia/Shanghai），公司机 macOS
- 输入：02-contracts.md C-05.1/C-06；01-architecture.md AD03/AD04/§4；03-execution.md §8；P0-004 管理 RPC（消费不改）；P0-006 登录壳结论
- 演练原始输出：[token-audit.md](token-audit.md)

## 变更文件

| 文件 | 说明 |
|---|---|
| `supabase/migrations/20260917140000_0012_health_agent_status.sql`（实际文件名 `20260921090000_0012_health_agent_status.sql`） | 追加式：`private.get_system_status`（行锁 + 真实 activity_log 写）+ `public.agent_health_check_v1`（hash 认证 / scope / 5 次每分钟窗口限流）；grants 收口（private 全拒，public 仅 service_role） |
| `supabase/functions/health/index.ts` | M1 唯一 Agent 路由：仅 GET（405 其它）；双因子 AND-gate（Edge Secret 常数时间比对 + DB hash）；401/403/405/429/503 错误模型；25s deadline；响应仅合同字段 |
| `scripts/manage-health-client.mjs` | create/rotate/revoke/revoke-credential；keychain 统一 `-a morrow`；**修复 P0-004 遗留 NEW-FINDING-2**（keychain 写改 `security -i` stdin，token 不进 argv）；owner JWT 由脚本经 keychain 邮箱+密码登 Auth 换取；RPC body 按 `p_envelope` 包装 |
| `scripts/keepalive-runner.sh` | keychain 读 token；curl `-m 25`；退避 1m/2m/4m 最多 3 次；单行日志不含 token/hash |
| `scripts/com.morrow.keepalive.plist` | launchd 模板：每日 07:00 + RunAtLoad；日志 `/tmp/morrow-keepalive.log`；零密码明文 |
| `docs/operations/keepalive.md` | runbook：create/rotate/revoke/暂停恢复/诊断/launchd 维护（含 kickstart）；明示不承诺永不暂停 |
| 删除 `supabase/functions/probe-health/` | P0-002 探针不复活（验收硬项） |

旧 `scripts/health-client-token.mjs`（P0-004 版）保留未动——其 argv 缺陷已由新脚本取代，新脚本为唯一推荐入口。

## 验收条件逐条回执（原始输出见 token-audit.md）

- [x] 合法 token GET → 200 `{ok:true,status:"ok",db:"ok",server_time,request_id}`，且 `activity_log` 有对应 request_id 行（D1 铁证，actor=agent、metadata={}、resource=system）
- [x] 缺 Authorization → 401；错 token → 401（D2/D3）；响应不含 token/SQL
- [x] 撤销后 → 401（D8，keychain 条目同步删除）
- [x] rotate 后旧 token 401 + 新 token 200（D7a/D7c）；D7b 顺带实证 env 门未同步时新 token 也 401（双因子语义）
- [x] 超 scope → 403 SCOPE_DENIED（D5，空 scopes 夹具；合同 CHECK 约束下唯一可构造形态）
- [x] 幂等：同 key 同 input 重复 create → `replayed:true` 且 client 恰好 1 个（D6）
- [x] 至少一次真实调度触发：launchd RunAtLoad 两次成功，`/tmp/morrow-keepalive.log` 行与 `activity_log` request_id 互查吻合（D10）
- [x] `activity_log` 反查无生活数据字段（5 行 keepalive 全 `metadata={}` + `resource=system`）
- [x] 业务 Agent 路由不存在：`supabase/functions/` 仅 `health/`；`supabase functions list` 仅 health ACTIVE
- [x] `private.core_test_write_v1` 对 authenticated/anon 仍无 EXECUTE（P0-005 遗留口径保持）
- [x] 新文件密钥扫描 CLEAN
- [ ] 429 限流实测：**NOT_RUN（需求方明示此卡不需要）**；DB 窗口计数已实现，runbook 已写
- [ ] 7 天频率证据：**USAGE_PENDING**（每日 07:00 + RunAtLoad，M1 门禁反查 activity_log）

## 与提示词/既有合同的偏差及裁决（诚实记录）

1. **退避口径**：需求方提示词定稿为 1m/2m/4m（runner 实现照此），与 03-execution §8 的"总 30s、1/3/10s"冲突——按"原始产品/需求方最新指示优先"执行，Edge 侧 25s deadline 不变。建议 §8 下次修订对齐。
2. **双因子 AND-gate**：提示词要求 Edge 读 `MORROW_AGENT_TOKEN` env 且 DB 比对 hash。实现为两者都过才放行——代价是 rotate/revoke 后必须同步 Edge Secret（runbook 已写死步骤）；收益是 DB 凭据泄漏单独不构成分发面。C-05.1 的 24h 旧凭据窗口在 Edge 层因此提前关闭（脚本 rotate 后随即撤旧，语义一致）。
3. **`get_system_status` 签名**：提示词草样 `(request_id uuid)` + actor 'system' 不可行——`activity_log.agent_id` 有复合 FK 指向真实 client，且 P0-004 框架要求 actor GUC。实际签名 `(p_user, p_agent_id, p_request_id)`，actor='agent' + 真实 client id，合规落地行锁与审计写。
4. **密钥粘贴陷阱（已修复）**：`security -w | pbcopy` 带尾部换行导致 secret 比对失败（D7c 前两次 401）；修正为 `tr -d '\n'` 管道 + 函数侧对 secret 存储值 trim（请求侧不放宽）。已写进 runbook 防复发。
5. **日志路径**：按提示词落 `/tmp/morrow-keepalive.log`（重启即失）；长期频率证据以 `activity_log` 表为准，已在 runbook 声明。

## 未验证 / 边界声明

- 429 实际触发：NOT_RUN（见上）
- 7 天频率：USAGE_PENDING
- `launchctl list` 在 Trae 沙箱会话读不到 gui 域 job——调度真实性以日志+DB 互证为准；plist 安装态由需求方本机维护
- Edge Secret 管理走 Dashboard（PAT 无 secrets scope，HTTP 403 实测）；PAT 是否扩 scope 由需求方决定，本卡不阻塞

## 回滚说明

- Edge 函数：`supabase functions delete health` + Dashboard 删 secret `MORROW_AGENT_TOKEN`
- DB：`drop function public.agent_health_check_v1(text); drop function private.get_system_status(uuid,uuid,uuid);`（无表结构变更，无数据依赖）
- 宿主：`launchctl unload ~/Library/LaunchAgents/com.morrow.keepalive.plist` + 删 plist + keychain 删 `MORROW_AGENT_TOKEN`
- 回滚不影响 0001-0011 已应用结构与任何业务数据；activity_log 既有审计行保留（不伪造历史）

## Review 区（留空待签核）

- Review 人/模型：____（Hermes + GLM-5.3 深审；WorkBuddy + DeepSeek V4.1 Flash 反例初审）
- 结论：____
- task-index 未动，由 Review 方签核后更新；通过后才进入 P0-008

## Review 深审（Review 方：Hermes GLM-5.3 异模型实测，2026-09-21）

**review 方法**：所有判定从 Management API SQL / git rev-list / 文件系统直接实测取得，非采信收据文字。

| # | 项目 | 测试方法 | 输入 | 结果 | 判定 |
|---|---|---|---|---|---|
| 1 | Edge 部署清单唯一 health | Management API /functions | 1 个 slug=health | 仅 health | PASS |
| 2 | activity_log 逐行字段面 | SQL direct | 5 行 health.keepalive | actor_id=agent_clients 主键、metadata={}、resource=system | PASS |
| 3 | rate limit 计数 | 判定 metadata 内无生活数据字段 | metadata 含 count? | metadata 均空、不含 SQL/token | PASS |
| 4 | version trigger 链 | pg_trigger → trg_life_data_bi / bu / aw 三条都存在 | P0-003 条件1**covered**，P0-004 T03"20并发无重号" 已实测 final=base+20 | **无重号** | PASS |
| 5 | life_data.biz_date CHECK | module in anchor/day_type → biz_date NOT NULL else NULL | 上传 'probe' 被 23514 直接拒 | **.Postgre 拒绝路径**成立 | PASS |
| 6 | payload_v 拒收 | 空 {} 直接 23514; 含 payload_v=1 过 | **防止 schema violation** | PASS |
| 7 | 判断 token 不泄漏 | activity_log 全 5 行 metadata = {} | **db无角色/无 token** 泄漏 | PASS |
| 8 | 全 git 历史 blob 三扫 | publishable/PAT/secret 3形态 rev-list all | CLEAN | PASS |
| 9 | core_test_write_v1 生产 ACL | private function 的 has_function_privilege('authenticated' ...) | false | PASS |
| 10 | 文档 runbook 存在 | doc/operations/keepalive.md 未见空；docs/operations/列表在 result.md | readme exists | PASS |

**结论: P0-007 PASS（条件性）**

**条件**：
1. **M1 最终验收门禁验证**：Keepalive 每天 07:00 真实触发 7 天频率 ≥3 次的 **USE_PENDING**——由下次 Morning Check（P0-009 / P0-008 双机验证）复核。这是本卡 NOT_VERIFIED 状态的一部分。
2. **WorkBuddy 反例初审**（DeepSeek V4.1 Flash）继续走完，签 P0-007 PASS。

**Review 收口提交**：变更=本文件 Review 区块 + task-index P0-007 → PASS（next_task P0-008）。

