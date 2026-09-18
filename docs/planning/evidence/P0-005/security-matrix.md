# P0-005 安全矩阵（S01–S09 逐格对照）

Review 方请对照 `security-matrix-db.output.txt` 原始输出复核。方法：Management API SQL（keychain PAT），`SET LOCAL ROLE` + `request.jwt.claims` 模拟真实 JWT 会话身份；事务回滚探针零生产副作用。

| 向量 | 测试输入 | 期望合同语义 | 实测输出摘录 | 判定 |
|---|---|---|---|---|
| S01 anon 全盲 | `set local role anon` 读 life_data / activity_log / private.agent_credentials / 调 RPC | 无数据无 GRANT，读写 4xx | 42501 permission denied（四处全拒） | PASS |
| S02 非 owner 隔离 | probe 用户 claims 读 4 表 + 调 initialize RPC | 零行 + OWNER_DENIED | life/activity/settings 全 0 行；`OWNER_DENIED` | PASS |
| S03 owner 直 DML 拒 + 语义 RPC 成 | owner claims UPDATE/DELETE 业务表 + get_workspace_revision RPC | 直 DML 42501，语义 RPC ok | 42501 ×2；`ok:true data_revision:"169"` | PASS |
| S04 伪造 actor/owner | 伪造 p_uid / 无 actor GUC 插入 / 自报 source | 全部拒绝或覆盖 | OWNER_DENIED；actor_context_missing；source_type 强制=actor | PASS |
| S05 credentials/receipts 不可读 | owner claims 读 private 两表 | 42501 | 42501 ×2；agent_clients RLS 开 | PASS |
| S06 函数白名单 | 全 scan public/private 函数 EXECUTE 权限 | private 仅 4 cmd_* + is_workspace_owner 对 auth 开放 | 精确匹配，无越权 | PASS |
| S07 health 凭据状态 | 查过期凭据 | 无过期残留 | `c=0` | PASS（Edge 实测归 P0-007） |
| S08 撤销并发 | revoke ‖ rotate 同 client | 撤销提交后无新授权写 | rotate 先完成 02:47:38.02 → revoke 02:47:38.17 提交 → 新凭据被连带撤销 live_creds=0 | PASS |
| S09 receipt 无 token | 扫 receipt.response 64hex | 无 token_hash | `c=0` | PASS |

## 白名单审计补充

- private SECURITY DEFINER 函数 22 个：`search_path=''` 全部合规
- `public.rls_auto_enable`：Supabase 平台事件触发器（owner postgres，`search_path=pg_catalog`），非本仓产物，无 P1
- 角色继承：authenticator（不继承）∈{anon,authenticated,service_role}，标准 Supabase 模型
- `core_test_write_v1`：ACL `{postgres=X/postgres}`，从未进生产权限