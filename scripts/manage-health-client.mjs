#!/usr/bin/env node
// P0-007｜health 客户端注册/轮换/撤销脚本（C-05.1，manage_health_client_v1 RPC 宿主侧）
// 前身为 P0-004 scripts/health-client-token.mjs；本版按 P0-006 Review 移交项硬化：
//   * keychain 写入改走 `security -i` stdin（printf 内置命令），token 明文不进任何进程 argv
//     （修复 P0-004 WorkBuddy NEW-FINDING-2：原 `security -w <token>` argv 暴露）
//
// 纪律：
// - token 本机生成（32B 高熵），形态 mrw_v1.<credential_uuid>.<base64url_secret>
// - 先安全暂存 keychain 再调 RPC；RPC 只提交整个 token 的 SHA-256 摘要（hex64）
// - RPC 失败即删除暂存；原始 token 只展示一次，不进日志/git/receipt
// - 生产 token 固定存 keychain service `MORROW_AGENT_TOKEN`（keepalive-runner.sh 读取处）
// - 身份注入（全部环境变量，不落盘）：
//     MORROW_SUPABASE_URL / MORROW_PUBLISHABLE_KEY 必须
//     MORROW_OWNER_JWT 直接注入，或 MORROW_OWNER_EMAIL + MORROW_OWNER_PASSWORD 由脚本登录换 JWT
// - MORROW_IDEM_KEY（可选，仅演练用）：强制幂等键以复现同 key 重放
//
// 用法：
//   node manage-health-client.mjs create <name> <local|remote|scheduled>
//   node manage-health-client.mjs rotate <client_id>
//   node manage-health-client.mjs revoke-client <client_id>
//   node manage-health-client.mjs revoke-credential <client_id> <credential_id>

import { createHash, randomUUID, randomBytes } from 'node:crypto';
import { execFileSync } from 'node:child_process';

const {
  MORROW_SUPABASE_URL, MORROW_PUBLISHABLE_KEY,
  MORROW_OWNER_JWT, MORROW_OWNER_EMAIL, MORROW_OWNER_PASSWORD,
  MORROW_IDEM_KEY,
} = process.env;
if (!MORROW_SUPABASE_URL || !MORROW_PUBLISHABLE_KEY) {
  console.error('缺少环境变量 MORROW_SUPABASE_URL / MORROW_PUBLISHABLE_KEY');
  process.exit(2);
}

const [, , action, ...args] = process.argv;

function newToken() {
  const credentialId = randomUUID();
  const secret = randomBytes(32);
  const token = `mrw_v1.${credentialId}.${secret.toString('base64url')}`;
  const tokenHash = createHash('sha256').update(token, 'utf8').digest('hex');
  return { credentialId, token, tokenHash };
}

// token/service/account 仅含安全字符（base64url/UUID/下划线），单引号包裹后
// 经 stdin 送入 `security -i` 交互解释器；明文不出现在任何进程 argv。
function keychainSave(service, account, value) {
  for (const v of [service, account, value]) {
    if (/['\\\n]/.test(v)) throw new Error('keychain 值含非法字符');
  }
  execFileSync('security', ['-i'], {
    input: `add-generic-password -U -s '${service}' -a '${account}' -w '${value}'\n`,
    stdio: ['pipe', 'pipe', 'pipe'],
  });
}
function keychainDelete(service) {
  try {
    execFileSync('security', ['-i'], {
      input: `delete-generic-password -s '${service}'\n`,
      stdio: ['pipe', 'pipe', 'pipe'],
    });
  } catch { /* 不存在可忽略 */ }
}

async function ownerJwt() {
  if (MORROW_OWNER_JWT) return MORROW_OWNER_JWT;
  if (!MORROW_OWNER_EMAIL || !MORROW_OWNER_PASSWORD) {
    throw new Error('缺少 owner 身份：注入 MORROW_OWNER_JWT 或 MORROW_OWNER_EMAIL+MORROW_OWNER_PASSWORD');
  }
  const res = await fetch(`${MORROW_SUPABASE_URL}/auth/v1/token?grant_type=password`, {
    method: 'POST',
    headers: { apikey: MORROW_PUBLISHABLE_KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email: MORROW_OWNER_EMAIL, password: MORROW_OWNER_PASSWORD }),
  });
  const body = await res.json().catch(() => null);
  if (!res.ok || !body?.access_token) throw new Error(`owner 登录失败: HTTP ${res.status}`);
  return body.access_token;
}

async function rpc(input, idempotencyKey) {
  const jwt = await ownerJwt();
  const res = await fetch(`${MORROW_SUPABASE_URL}/rest/v1/rpc/manage_health_client_v1`, {
    method: 'POST',
    headers: {
      apikey: MORROW_PUBLISHABLE_KEY,
      Authorization: `Bearer ${jwt}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ api_version: '1', idempotency_key: idempotencyKey, input }),
  });
  const body = await res.json().catch(() => null);
  return { http: res.status, body };
}

function defaultExpiresAt() {
  // 合同：显式值，不超过 90 天；默认 90 天
  return new Date(Date.now() + 90 * 24 * 3600 * 1000).toISOString();
}

function idemKey() {
  return MORROW_IDEM_KEY ?? randomUUID();
}

async function main() {
  if (action === 'create') {
    const [name, type] = args;
    if (!name || !['local', 'remote', 'scheduled'].includes(type ?? '')) {
      console.error('用法: create <name 1..80> <local|remote|scheduled>');
      process.exit(2);
    }
    const { credentialId, token, tokenHash } = newToken();
    const pendingService = `MORROW_HEALTH_PENDING_${credentialId}`;
    // 先安全暂存，再调 RPC（响应丢失可按同 key+hash 恢复，不换 secret 重试）
    keychainSave(pendingService, credentialId, token);
    const key = idemKey();
    let out;
    try {
      out = await rpc({
        action: 'create', name, type,
        credential_id: credentialId, token_hash: tokenHash,
        expires_at: defaultExpiresAt(),
      }, key);
    } catch (e) {
      keychainDelete(pendingService);
      throw e;
    }
    if (!out.body?.ok) {
      keychainDelete(pendingService);
      console.log(JSON.stringify({ http: out.http, idempotency_key: key, ...out.body }, null, 2));
      process.exit(1);
    }
    if (out.body.replayed) {
      // 同 key 重放：不覆盖已保存的正式 token，只清暂存并展示非敏感结果
      keychainDelete(pendingService);
      console.log(JSON.stringify({ http: out.http, idempotency_key: key, ...out.body }, null, 2));
      return;
    }
    // 成功：转存到固定生产键，删除暂存
    keychainSave('MORROW_AGENT_TOKEN', out.body.result.client_id, token);
    keychainDelete(pendingService);
    console.log('=== 新 token（仅显示一次，已入 keychain MORROW_AGENT_TOKEN）===');
    console.log(token);
    console.log('=== 非敏感结果 ===');
    console.log(JSON.stringify({ http: out.http, idempotency_key: key, ...out.body }, null, 2));
  } else if (action === 'rotate') {
    const [clientId] = args;
    if (!clientId) { console.error('用法: rotate <client_id>'); process.exit(2); }
    const { credentialId, token, tokenHash } = newToken();
    const pendingService = `MORROW_HEALTH_PENDING_${credentialId}`;
    keychainSave(pendingService, credentialId, token);
    const key = idemKey();
    let out;
    try {
      out = await rpc({
        action: 'rotate', client_id: clientId,
        credential_id: credentialId, token_hash: tokenHash,
        expires_at: defaultExpiresAt(),
      }, key);
    } catch (e) {
      keychainDelete(pendingService);
      throw e;
    }
    if (!out.body?.ok) {
      keychainDelete(pendingService);
      console.log(JSON.stringify({ http: out.http, idempotency_key: key, ...out.body }, null, 2));
      process.exit(1);
    }
    keychainSave('MORROW_AGENT_TOKEN', clientId, token);
    keychainDelete(pendingService);
    console.log('=== 新 token（仅显示一次，已入 keychain MORROW_AGENT_TOKEN；旧凭据已收紧至 24h 内，试通后请 revoke-credential 撤旧）===');
    console.log(token);
    console.log(JSON.stringify({ http: out.http, idempotency_key: key, ...out.body }, null, 2));
  } else if (action === 'revoke-client') {
    const [clientId] = args;
    if (!clientId) { console.error('用法: revoke-client <client_id>'); process.exit(2); }
    const out = await rpc({ action: 'revoke', client_id: clientId, target: 'client' }, idemKey());
    if (out.body?.ok) keychainDelete('MORROW_AGENT_TOKEN');
    console.log(JSON.stringify({ http: out.http, ...out.body }, null, 2));
    if (!out.body?.ok) process.exit(1);
  } else if (action === 'revoke-credential') {
    const [clientId, credentialId] = args;
    if (!clientId || !credentialId) { console.error('用法: revoke-credential <client_id> <credential_id>'); process.exit(2); }
    const out = await rpc({ action: 'revoke', client_id: clientId, target: 'credential', credential_id: credentialId }, idemKey());
    console.log(JSON.stringify({ http: out.http, ...out.body }, null, 2));
    if (!out.body?.ok) process.exit(1);
  } else {
    console.error('未知 action。支持 create / rotate / revoke-client / revoke-credential');
    process.exit(2);
  }
}

main().catch((e) => { console.error(`失败: ${e.message}`); process.exit(1); });
