# P0-007 token-audit｜演练原始输出记录

凭据纪律：全部输出不含 token 明文/hash（脚本打印 token 的行已用 `grep -v '^mrw_v1\.'` 过滤；curl 响应不回显 Authorization）。keychain 条目统一 `-a morrow`。

环境：公司机 macOS，Node v22，zsh；Supabase project `umutubzcwwmmbxfjkyvj`（Singapore/Free）。

## D0 注册（create）

```text
$ node scripts/manage-health-client.mjs create hermes-keepalive scheduled
=== 新 token（仅显示一次，已入 keychain MORROW_AGENT_TOKEN）===
=== 非敏感结果 ===
{
  "http": 200,
  "idempotency_key": "d2616a2f-5b50-4160-840c-de54a56ffd08",
  "ok": true,
  "result": {
    "scopes": ["system:health"],
    "enabled": true,
    "version": "1",
    "client_id": "2830885f-5303-46bc-9f53-eef09bf04d69",
    "expires_at": "2026-12-20T04:37:22.381+00:00",
    "credential_id": "cf9b252f-9c3c-4fd4-9618-9646b8711895"
  },
  "replayed": false,
  "request_id": "275ba6e9-b2c4-4c9b-8c66-339ed5bb5fb8",
  "server_time": "2026-09-21 04:37:25.023067+00"
}
```

## D1 合法 token GET → 200 + activity_log 铁证

```text
$ curl -H "Authorization: Bearer <keychain 读取>" …/functions/v1/health
{"ok":true,"status":"ok","db":"ok","server_time":"2026-09-21 04:52:00.810506+00","request_id":"cdb55fa0-3900-4e6a-a2ee-01db592547d2"}
HTTP 200

$ select … from public.activity_log where request_id='cdb55fa0-…';
[{"actor_type":"agent","action":"health.keepalive","resource":"system",
  "request_id":"cdb55fa0-3900-4e6a-a2ee-01db592547d2","metadata":"{}",
  "agent_id":"2830885f-5303-46bc-9f53-eef09bf04d69"}]
```

## D2 / D3 / D4 负路径

```text
缺 Authorization → HTTP 401 {"ok":false,"error":{"code":"UNAUTHENTICATED",…}}
错 token        → HTTP 401 {"ok":false,"error":{"code":"UNAUTHENTICATED",…}}
POST            → HTTP 405 {"ok":false,"error":{"code":"METHOD_NOT_ALLOWED",…}}（Allow: GET）
```

## D5 超 scope → 403（SQL 事务内置 scopes='{}' 夹具，actor GUC 合规）

```text
scopes='{}' 后 GET → HTTP 403 {"ok":false,"error":{"code":"SCOPE_DENIED","message":"scope 不足",…}}
恢复 ['system:health'] 后 GET → HTTP 200（request_id 189bf487-01ed-4b7d-bf2d-aed7e6123c5a）
```

注：合同管理面只发 `['system:health']` 且 CHECK 约束 `scopes <@ ['system:health']`；空数组是唯一可构造的"超/缺 scope"形态。

## D6 幂等：同 key 同 input 重复 create → replayed:true，不多插

```text
first:  ok=true  replayed=false client_id=0e1da44a-f004-4be7-97bf-ce92d1ec638d
second: ok=true  replayed=true  client_id=0e1da44a-f004-4be7-97bf-ce92d1ec638d
same_client: true

$ select count(*) from public.agent_clients where name='p0-007-idem-fixture';
[{"fixture_clients":1}]   ← 恰好 1 个，无重复插

fixture 已 revoke（target=client）：{"ok":true,"revoked_at":"2026-09-21T05:54:09…"}（清场）
```

## D7 轮换

```text
$ node scripts/manage-health-client.mjs rotate 2830885f-… cf9b252f-…
rotate 结果：ok=true, 新 credential_id=c691b13e-d53f-4e7c-9176-01f07bdba13f, version=3
revoke 旧凭据：ok=true, target=credential, no_change=false

D7a 旧 token GET（旧凭据已撤）        → HTTP 401 UNAUTHENTICATED
D7b 新 token GET（Edge secret 未同步）→ HTTP 401 UNAUTHENTICATED   ← 双因子 AND-gate 实证
D7c secret 同步后新 token GET         → HTTP 200, request_id=fc2af86a-94d1-407e-aa02-8fd39b1e9ad6
```

D7c 前两次失败根因（诚实记录）：`security -w` 输出尾部换行经 pbcopy 带入 secret → 常数时间比较失败；修正为 `… | tr -d '\n' | pbcopy` 且函数侧对 secret 存储值 trim（请求侧不放宽）后通过。另一次诊断假阳性：`shasum` 直接吃 `security -w` 输出会把 `\n` 算进摘要，一度误判 keychain/DB 不一致；`tr -d '\n'` 后确认 keychain token 与新凭据 c691b13e 精确匹配。

## D8 撤销

```text
$ node scripts/manage-health-client.mjs revoke 2830885f-…
{"ok":true,"result":{"target":"client","revoked_at":"2026-09-21T05:45:34.144499+00:00","no_change":false,"version":"4"}}

撤销后 GET 旧 token → HTTP 401 UNAUTHENTICATED
keychain MORROW_AGENT_TOKEN → DELETED（脚本自清）
```

## D9 最终生产 client（常驻用）

```text
$ node scripts/manage-health-client.mjs create hermes-keepalive scheduled
client_id=b2d22525-324f-419b-8488-9a5ef072a84d, credential_id=7db8b0df-8155-4cbd-8f92-d16094ddde23,
scopes=[system:health], enabled=true, expires_at=2026-12-20T05:47:11.824+00:00
Edge secret 已同步为新 token（凯哥 Dashboard 操作）
```

## D10 真实调度触发（launchd，非手工 shell）

```text
$ cat /tmp/morrow-keepalive.log
/bin/zsh: can't open input file: …/scripts/keepalive-runner.sh      ← 首次载入时脚本路径问题（凯哥已修）
2026-09-21T05:55:37Z ok attempt=1 http=200 request_id=b6b5cc39-8478-44b5-8caa-e972a75f8790 elapsed_s=2
2026-09-21T05:56:23Z ok attempt=1 http=200 request_id=aeeb0e70-4450-42c3-b13d-5536941c9c7a elapsed_s=1

$ select request_id, actor_type, action, agent_id, created_at from public.activity_log
  where request_id in ('b6b5cc39-…','aeeb0e70-…');
两条均在：actor_type=agent, action=health.keepalive, agent_id=b2d22525-…（最终 client），created_at 与日志秒级吻合
```

## 汇总核验

```text
$ ls supabase/functions/        → health        （probe-health 远端与目录均不复活）
$ supabase functions list       → 仅 health ACTIVE（version 10）

$ select count(*), count(*) filter (metadata<>'{}'), count(*) filter (resource<>'system')
  from public.activity_log where action='health.keepalive';
n=5, nonempty_metadata=0, non_system_resource=0   ← 无生活数据字段

$ has_function_privilege('authenticated', private.core_test_write_v1) → false（anon 同 false）
  P0-005 遗留口径保持：生产 ACL 未对 authenticated 放行

$ grep -rEn "mrw_v1\.[0-9a-f]{8}-|sbp_|sb_publishable_…|eyJ…" <全部新文件> → CLEAN
```

## NOT_RUN / 边界

- 429 RATE_LIMITED 未实际触发（需求方明示此卡不需要；DB 窗口计数 `≥5 次/60s/client` 已在 0012 实现，runbook 已写）
- 7 天频率证据：USAGE_PENDING（每日 07:00 + RunAtLoad；M1 门禁时从 activity_log 反查）
- `launchctl list | grep morrow` 在 Trae 沙箱会话读不到 gui 域 job；真实调度以 /tmp 日志 + activity_log request_id 互证为准
