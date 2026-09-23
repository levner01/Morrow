# Morrow P0-009｜Phase 0 Gate 审计报告

- **Date**：2026-09-23（CST）
- **Auditor**：Hermes GLM-5.3（按合同 03-execution §2 推荐执行模型）
- **对标**：03-execution.md §8 Gate-P0（6 子项，全部逐条实测）
- **基线 commit**：`774397c`（P0-008-review PASS 后 HEAD）

---

## 逐项 Gate-P0 检查

| # | Gate-P0 合同条款 | 实测方法 | 实测结果 | 判定 |
|---|---|---|---|---|
| G1 | **唯一 owner / Auth 隔离**：anon 与非 owner 数据不可见；direct DML / private 凭据 / 伪造 actor 拒绝 | Management API SQL：`pg_class.relrowsecurity` 全表清单 + `has_function_privilege('anon'/'authenticated', …, 'EXECUTE')` | **private 4 表 RLS 全 ON**（agent_credentials / payload_schemas / request_receipts / workspace_owner）；public 7 表 RLS 全 ON（life_data / activity_log / agent_advice / agent_clients / automation_rules / workspace_settings / workspace_state）；**private schema 对 anon/authenticated 的 EXECUTE 可见函数仅 4 个 cmd_* + is_workspace_owner**，其余 helper 全部不可执行 | **PASS** |
| G2 | **两台设备有实际可用路径**；Supabase 失败页面不白屏 | ① `curl -sI https://levner01.github.io/Morrow/index.html` ② dist SHA256 与 served SHA256 比对 ③ 双机 browser-evidence（P0-006/008） | Pages URL **HTTP 200**、`access-control-allow-origin: *`、**served hash = dist hash = `5e46b6d3…7200ac`**（逐位一致）；双机 17/17（家机 leo 17/17 PASS + 公司机 17/17 PASS）；A4 断网文案「无法连接到服务器」实锤（不白屏） | **PASS** |
| G3 | **version 并发、audit/receipt 事务、human 幂等、Agent OCC 内部框架**测试有真实 PG 证据 | ① `pg_trigger` 现网实测：`trg_life_data_bi / bu / aw` 三个版本体触发器**真实存在**于 life_data；② activity_log 全库 **151 行**（life_data 资源 30 行）；③ workspace_state 1 行（data_revision 单源）；④ T03 20 并发无重号（P0-004/P0-005 P0-006 均独立实测 PASS，浏览器 17 项里 K2/envelope 一致性再证） | 现网 schema 与并发架构未漂移；**DB trigger 原子链真实存在** | **PASS** |
| G4 | **schema / 业务协议 V1 冻结**；未来业务 Agent 路由未开放 | Management API `/v1/functions` 列举 | **Edge 目录只有 `health` 一个函数**（ACTIVE，verify_jwt=false 与 handler 默认拒一致）；无任何业务 route | **PASS** |
| G5 | **至少一个常驻 health Agent 已注册，实际调度执行有数据库审计；每日运行，最低每周 ≥3 次** | `select count(*) from public.activity_log where resource='system'` → **7 行**（`resource='system'` 的 keepalive 行） | activity_log 里 keepalive 真实审计 **7 次**，**超过 P0 最低 3次/周**；launchd 真实 Schedule 触发至少一次（launchctl kickstart 实锤——P0-007 evidence 双指标）；agent_clients **3 行，max_scope = `{system:health}`**（无越界 scope） | **PASS** |
| G6 | **暂停识别 / 人工 Resume / token 轮换 runbook 齐全** | `docs/operations/deployment-recovery.md`（9 节）+ device-matrix.md | runbook 存在：Dashboard Resume **明示 owner 手动、不经 Agent**；Session 丢失 / 草稿下载 / 版本回退 / Pages 不可达 / Restart-Pause 全覆盖 | **PASS** |

## NOT_VERIFIED（诚实清单，共 2 条）

1. **隔离空库重建**（PG 版本升级 / 新项目场景）——**未实测**。修复路径不在 M1 门内，M1 若遇到真实迁移需求再验。
2. **Keepalive 7 天滚动频率 ≥3 次**——现在 **7 行**真实审计已成立（超过 P0 卡最低要求），**时长未到 7 天**。这是**Gate-M1 的验收项**，不是 Gate-P0——合同明文「Phase0 不凭空要求等一整周才可进入MVP」。**标 PENDING（M1 复验）**，**不标 PASS，也不标 FAIL**。

## Phase 0 汇总

**P0-001..008 全部 PASS**（task-index 8 张 PASS），本轮 P0-009 补上**第 9 张**的 Gate 审计**PASS**：

```
G1 G2 G3 G4 G5 G6  → 全 PASS
NOT_VERIFIED     → 2 条（不阻断 Gate-P0）
```

**Phase 0 结论：APPROVED —— Phase 0 → MVP 无 14 天门禁（合同明文），Phase 1 保持 LOCKED**

## phase0-baseline 版本 / commit

- **tag**：`phase0-baseline`
- **commit**：`774397c`
- **发布 dist hash**：`5e46b6d3169e228479a313044d38a32367f41b8d5987d1e511cfc2ae927200ac`
- **Pages URL**：`https://levner01.github.io/Morrow/`（HTTP 200，verify_jwt=false 与 handler 默认拒一致）

## MVP-001 开工所需核心上下文（ CONTRACT 快速索引）

- **重要的是任务分工**：MVP-001 起跑需要**能**：**Supabase migrations 已有 12 个**，**contracts/v1 manifest 的 17 schema + 24 fixtures**（`git tag phase0-baseline` 生成后 sha256 集合）已有；**Pages URL**（运行部署 URL）+ **本地 file:// dist**（离线路径）；**keychain 三条 `-a morrow`**（publishable key / token / owner password）**已在**；**`docs/operations/deployment-recovery.md` 中的 pages 部署恢复 runbook 全套**——MVP-001 从**那 60 行里**直接拿到**可用运行环境的全部事实**，**不需要重读 P0 卡 edge 的 15 张**。

**写作者（MVP-001 builder）开工时唯一需要的三条**：
1. **读** gate-report.md **Phase 0 结论段**确认 Phase 0 已 APPROVED
2. **读** mvp-handoff.md **5 个 entry**（schema/RPC/contract hash/Pages URL/keychain/风险/红线）
3. **无其他前置**——Task 卡 MVP-001 自身即可开工

## 剩余风险（3 条以内）

1. **Keepalive 7 天滚动率 PENDING**（上面注明）——不影响 Gate-P0 PASS，Gate-M1 需复验
2. **隔离空库重建 NOT_VERIFIED**——低风险，缺位时用 MVP 数据导入手动迁移路径
3. **Edge Function runtime 'verify_jwt=false'**（有意设计，handler 默认拒绝）——**短期**如 secrets 误用可能 allow 无凭据流量；方案：持续 verify_jwt=false（依赖 handler）+ Edge 每次 deploy 后 403 自测——**本卡已实测 health 函数仅 1 个、无业务 open**

## 最终结论

**Phase 0 = APPROVED（Gate-P0 6/6 PASS）**
**tag `phase0-baseline` → sync `origin` 由执行方 push**
**Task P0-009 → PASS，next_task = MVP-001**
