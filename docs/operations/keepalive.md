# Morrow Keepalive Runbook（P0-007）

**这是什么**：Supabase 免费层防休眠的宿主侧 Keepalive——launchd 每日 07:00（Asia/Shanghai，宿主机本地时区）触发 `scripts/keepalive-runner.sh`，带 `MORROW_AGENT_TOKEN` 调 `GET /functions/v1/health`，DB 落一行 `health.keepalive` 审计。

**这不是什么**：不承诺"永不暂停"。免费层暂停后的恢复是人工 Dashboard Resume；自动保活只是降低频率，不比人工更稳——无理由的自动重启可能掩盖真问题。

## 组件

| 组件 | 位置 | 说明 |
|---|---|---|
| Edge Function | `supabase/functions/health/index.ts` | 仅 GET；双因子认证（Edge Secret 明文比对 + DB hash）；25s 内部 deadline |
| DB RPC | `public.agent_health_check_v1(text)`（migration 0012） | 仅 service_role 可 EXECUTE；hash 匹配 + scope 检查 + 5 次/分钟窗口限流 |
| 审计写 | `private.get_system_status(uuid,uuid,uuid)` | 行锁 + 真实 `activity_log` 写（`health.keepalive`），不授予任何客户端角色 |
| 管理脚本 | `scripts/manage-health-client.mjs` | create / rotate / revoke / revoke-credential；token 只进 keychain（`-a morrow`） |
| 执行器 | `scripts/keepalive-runner.sh` | 从 keychain 读 token；curl `-m 25`；失败退避 1m/2m/4m，最多 3 次；日志只写 `/tmp/morrow-keepalive.log` 单行 |
| 调度 | `scripts/com.morrow.keepalive.plist` → `~/Library/LaunchAgents/` | 每日 07:00 + RunAtLoad；进程零密码明文 |
| 凭据 | keychain `-a morrow -s MORROW_AGENT_TOKEN` + Supabase Edge Secret `MORROW_AGENT_TOKEN` | **两处必须同步**（双因子 AND-gate） |

## 认证模型（双因子 AND-gate）

请求 token 须同时满足：① 与 Edge Secret `MORROW_AGENT_TOKEN` 常数时间相等（secret 存储侧允许尾部空白，请求侧不放宽）；② `SHA-256(token)` 命中 `private.agent_credentials.token_hash` 且凭据未撤销/未过期、client `enabled=true` 且 `scopes=['system:health']`。

推论：**rotate/revoke 后必须同步更新 Edge Secret**，否则新 token 被 env 门挡 401（D7b 实测）。DB 撤销即时生效，不依赖 secret 同步（D7a/D8 实测）。

## 常见操作

### create（首次或重建）

```zsh
cd /Users/wangxinkai/Documents/Morrow
node scripts/manage-health-client.mjs create hermes-keepalive scheduled
# token 只打印一次并已写入 keychain（-a morrow -s MORROW_AGENT_TOKEN）
```

然后同步 Edge Secret（**注意去尾部换行**，剪贴板直带 `\n` 会导致 401）：

```zsh
security find-generic-password -a morrow -s MORROW_AGENT_TOKEN -w | tr -d '\n' | pbcopy
# Dashboard → Edge Functions → Secrets → 编辑 MORROW_AGENT_TOKEN → 粘贴保存
```

验证：`curl -H "Authorization: Bearer $(security find-generic-password -a morrow -s MORROW_AGENT_TOKEN -w)" https://umutubzcwwmmbxfjkyvj.supabase.co/functions/v1/health` → 200。

### rotate（90 天到期前必须轮换）

```zsh
node scripts/manage-health-client.mjs rotate <client_id> <old_credential_id>
# 新 token 已入 keychain；旧凭据 RPC 侧收紧 24h 且脚本随即撤销
```

**然后必须重复上面的 secret 同步步骤**，否则新 token 401。

### revoke

```zsh
node scripts/manage-health-client.mjs revoke <client_id>
# client 停用+撤销、全部凭据失效、keychain 条目删除；之后 GET → 401
```

撤销后如需恢复保活：**重新 create**（新身份，不复活旧 client）+ 同步 secret。

### 暂停恢复（Supabase 免费层 Pause）

1. Dashboard → project → **Resume**（人工操作，无 API 承诺）。
2. 恢复后手动验证一次 health 200；失败按下方诊断。
3. 不追求"自动 Resume"——暂停本身低频，人工路径足够。

## 诊断

| 现象 | 含义 | 处置 |
|---|---|---|
| 401 | token 缺失/错/撤销/过期/secret 未同步 | 先查 keychain 与 secret 是否一致；再查 client `enabled/revoked_at` |
| 403 SCOPE_DENIED | client scopes 被改动 | 恢复为 `['system:health']`（管理面只发这个 scope） |
| 429 RATE_LIMITED | 该 client 60s 内已 5 次成功调用 | 等窗口；Retry-After: 60。正常调度每日 1 次不会触达 |
| 405 | 非 GET | 调用方改 GET |
| 503 | Edge→DB 链路故障或函数缺 env | 查 Supabase 状态页；查 Edge Secrets 是否齐全 |
| runner exit=78 | keychain 无 MORROW_AGENT_TOKEN | 重新 create |
| runner exit=76 | 3 次尝试全失败 | 看 `/tmp/morrow-keepalive.log` 每行 http/curl_rc |

日志：`/tmp/morrow-keepalive.log`（重启即失；**长期频率证据以 `activity_log` 表为准**：`action='health.keepalive'`，`request_id` 可与日志行互查）。

## launchd 维护

```zsh
# 安装/重载（改 plist 后）
cp scripts/com.morrow.keepalive.plist ~/Library/LaunchAgents/
launchctl unload ~/Library/LaunchAgents/com.morrow.keepalive.plist 2>/dev/null
launchctl load ~/Library/LaunchAgents/com.morrow.keepalive.plist   # RunAtLoad 立即触发一次

# 手动立即触发一次（调试）
launchctl kickstart gui/$(id -u)/com.morrow.keepalive

# 查看退出状态
launchctl list | grep morrow

# 卸载
launchctl unload ~/Library/LaunchAgents/com.morrow.keepalive.plist
```

已知坑：plist 的 `ProgramArguments` 指向的脚本路径必须真实存在且有执行位，否则日志出现 `can't open input file`；runner 本身写 `/tmp/morrow-keepalive.log`，plist 的 stdout/stderr 也指到同一文件。

## 频率目标

每日 07:00 + 开机补跑（RunAtLoad）≥ 3 次/周的 M1 要求由本配置自然满足；7 天频率证据在 M1 门禁时从 `activity_log` 反查，不从本文件承诺。
