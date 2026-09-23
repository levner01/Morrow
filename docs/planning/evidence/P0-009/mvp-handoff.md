# Morrow MVP-001 开工包（P0-009 交付）

> **目的**：MVP-001 Builder 只需读**本文件**即可开工，**不必重读 P0-001..009 的任何卡**。所有事实已由 Gate 审计（`gate-report.md`）实测确认。

---

## 1. Schema 最终版（migration 0001..0012 应用后）

**private schema（4 表，RLS 全 ON，anon/authed 不可 EXECUTE 除 4 cmd_*)**：
| 表 | 用途 |
|---|---|
| `private.workspace_owner` | 唯一 owner 身份绑定 |
| `private.agent_credentials` | Agent token_hash（**明文永不入库**） |
| `private.request_receipts` | Agent 命令收据（幂等/回放防线） |
| `private.payload_schemas` | 17 schema 注册表 |

**public schema（7 表，RLS 全 ON）**：
| 表 | 说明 |
|---|---|
| `public.life_data` | 核心生活数据（**record-level LWW / Human 写**；version 由 `trg_life_data_bi/bu/aw` 原子触发器维护） |
| `public.workspace_state` | 单行，data_revision（**BIGINT，单行**，字符串化仅在 export 层） |
| `public.activity_log` | **同事务审计**（151 行已实存，keepalive 7 行） |
| `public.agent_advice` | Agent 建议箱 |
| `public.agent_clients` | Agent 注册表（**scopes 只允许 `{system:health}`**，3 行已实存） |
| `public.automation_rules` | Phase1 预留（**M1 空闲不使用**） |
| `public.workspace_settings` | 工作区配置 |

**触发器**（现网真实存在）：`trg_life_data_bi` (insert)、`trg_life_data_bu` (update)、`trg_life_data_aw` (avoid-revert) ——**version-1 / OCC / LWW 全链底层**。

## 2. Core RPC 签名清单（private schema，对 authenticated 开放的**两个**）

```sql
-- 对 authenticated 只有以下 4 个可 EXECUTE（其余 helper 全 false）：
private.cmd_initialize_workspace_v1(...)
private.cmd_get_command_result_v1(...)
private.cmd_get_workspace_revision_v1(...)
private.cmd_manage_health_client_v1(...)
private.is_workspace_owner(uuid) → bool
```
**合同红线**：所有调用走 **POST `POSTGRES_RPC` envelope（C-04）**；Agent 用 `MORROW_AGENT_TOKEN`（Bearer）+ `idempotency_key`；Human 用 JWT + 幂等键；**严禁 service_role**。

## 3. Contract 层（17 schema + 24 fixtures）

- 位置：`contracts/v1/`（`manifest` 为准，SHA256 全集固化在 P0-006 evidence `browser-evidence-real-cred.json`）
- **Dist 不可手改**（`dist/index.html` SHA `5e46b6d3…7200ac`）

## 4. 部署环境

| 环境 | 值 |
|---|---|
| **Pages URL（主）** | `https://levner01.github.io/Morrow/`（HTTP 200，无重定向） |
| **本地 http（fallback）** | `cd dist && python3 -m http.server 8080` → `http://127.0.0.1:8080/` |
| **本地 file:// （无网 fallback）** | `dist/index.html` 双击可开（localStorage 可用，network 0 条） |
| **Supabase project** | `umutubzcwwmmbxfjkyvj`（Singapore / Free） |
| **publishable key** | **keychain `-a morrow -s MORROW_PUBLISHABLE_KEY`**（不写值） |

## 5. keychain 约定（三条，均 `-a morrow`）

| secret 名 | 用途 |
|---|---|
| `MORROW_PUBLISHABLE_KEY` | 前端 boot（44/46 位） |
| `MORROW_AGENT_TOKEN` | Health Agent 调 health Edge（**明文不落盘**） |
| `MORROW_OWNER_PASSWORD` | owner 登录（**MVP 连续使用期必填**） |

## 6. 已知风险 / NOT_VERIFIED（写进 MVP-001 result 时如实带三条）

1. Keepalive 7 天滚动率 PENDING（M1 复验）
2. 隔离空库重建 NOT_VERIFIED
3. Edge health `verify_jwt=false` 设计冗余风险（有 handler 默认拒兜底，已实测）

## 7. 合同红线（5 行最简）

1. **禁 service_role**——任何链路都不允许出现
2. **HTTP 只 POST RPC**（Agent 走 `MORROW_AGENT_TOKEN`），**GET 禁用写**
3. **private helper 不暴露**（EXECUTE 仅 4 个 cmd_*；`is_workspace_owner` 例外）
4. **activity_log 与业务写同事务**，不后补
5. **dist 手改禁止**（release manifest + SHA 为准）；**Agent 占位版本不进 main**

---

**P0-009 交付清单**
- [x] `evidence/P0-009/gate-report.md`（Gate-P0 6/6 PASS）
- [x] 本文件（`mvp-handoff.md`）
- [ ] `git tag phase0-baseline` —— 需要**执行方 push tag**（**Stage 签核时一并完成**）
- [ ] `task-index` P0-009 → PASS、next_task → MVP-001
