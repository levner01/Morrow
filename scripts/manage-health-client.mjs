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
// - 生产 token 固定写 keychain：-a morrow -s MORROW_AGENT_TOKEN（keepalive-runner.sh 读取处）
// - 凭据全部由脚本自行从 keychain 读取（account 统一 morrow）：
//     MORROW_PUBLISHABLE_KEY / MORROW_OWNER_EMAIL / MORROW_OWNER_PASSWORD
//   owner JWT 由脚本登 Auth 换取（内存中，不落盘）；可用 env MORROW_OWNER_JWT 覆盖
// - MORROW_IDEM_KEY（可选，仅演练用）：强制幂等键以复现同 key 重放
//
// 用法：
//   node manage-health-client.mjs create [name] [local|remote|scheduled]   # 默认 hermes-keepalive scheduled
//   node manage-health-client.mjs rotate <client_id> <old_credential_id>   # 新凭据试通后撤旧
//   node manage-health-client.mjs revoke <client_id>                       # target=client
//   node manage-health-client.mjs revoke-credential <client_id> <credential_id>

import { createHash, randomUUID, randomBytes } from 'node:crypto';
import { execFileSync } from 'node:child_process';

const SUPABASE_URL = process.env.MORROW_SUPABASE_URL ?? 'https://umutubzcwwmmbxfjkyvj.supabase.co';
const KC_ACCOUNT = 'morrow';
const TOKEN_SERVICE = 'MORROW_AGENT_TOKEN';

const [, , action, ...args] = process.argv;

// ---------- keychain（stdin 模式，秘密不进 argv） ----------
function kcRead(service) {
  try {
    return execFileSync('security', ['find-generic-password', '-a', KC_ACCOUNT, '-s', service, '-w'],
      { stdio: ['pipe', 'pipe', 'pipe'] }).toString('utf8').trim();
  } catch {
    return null;
  }
}
function kcWriteStdin(service, value) {
  for (const v of [service, value]) {
    if (/['\\\n]/.test(v)) throw new Error('keychain 值含非法字符');
  }
  execFileSync('security', ['-i'], {
    input: `add-generic-password -U -a '${KC_ACCOUNT}' -s '${service}' -w '${value}'\n`,
    stdio: ['pipe', 'pipe', 'pipe'],
  });
}
function kcDelete(service) {
  try {
    execFileSync('security', ['-i'], {
      input: `delete-generic-password -a '${KC_ACCOUNT}' -s '${service}'\n`,
      stdio: ['pipe', 'pipe', 'pipe'],
    });
  } catch { /* 不存在可忽略 */ }
}

// ---------- 身份 ----------
let cachedJwt = null;
async function ownerJwt() {
  if (process.env.MORROW_OWNER_JWT) return process.env.MORROW_OWNER_JWT;
  if (cachedJwt) return cachedJwt;
  const publishable = kcRead('MORROW_PUBLISHABLE_KEY');
  const email = kcRead('MORROW_OWNER_EMAIL');
  const password = kcRead('MORROW_OWNER_PASSWORD');
  if (!publishable || !email || !password) {
    throw new Error('keychain 缺 MORROW_PUBLISHABLE_KEY / MORROW_OWNER_EMAIL / MORROW_OWNER_PASSWORD（account=morrow）');
  }
  const res = await fetch(`${SUPABASE_URL}/auth/v1/token?grant_type=password`, {
    method: 'POST',
    headers: { apikey: publishable, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password }),
  });
  const body = await res.json().catch(() => null);
  if (!res.ok || !body?.access_token) throw new Error(`owner 登录失败: HTTP ${res.status}`);
  cachedJwt = body.access_token;
  return cachedJwt;
}

async function rpc(input, idempotencyKey) {
  const [jwt, publishable] = [await ownerJwt(), kcRead('MORROW_PUBLISHABLE_KEY')];
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/manage_health_client_v1`, {
    method: 'POST',
    headers: {
      apikey: publishable,
      Authorization: `Bearer ${jwt}`,
      'Content-Type': 'application/json',
    },
    // PostgREST RPC：body 键必须是参数名（P0-006 fix2 同源教训）
    body: JSON.stringify({ p_envelope: { api_version: '1', idempotency_key: idempotencyKey, input } }),
  });
  const body = await res.json().catch(() => null);
  return { http: res.status, body };
}

function newToken() {
  const credentialId = randomUUID();
  const secret = randomBytes(32);
  const token = `mrw_v1.${credentialId}.${secret.toString('base64url')}`;
  const tokenHash = createHash('sha256').update(token, 'utf8').digest('hex');
  return { credentialId, token, tokenHash };
}

function defaultExpiresAt() {
  // 合同：显式值，不超过 90 天；默认 90 天
  return new Date(Date.now() + 90 * 24 * 3600 * 1000).toISOString();
}

function idemKey() {
  return process.env.MORROW_IDEM_KEY ?? randomUUID();
}

function printResult(out, extra = {}) {
  console.log(JSON.stringify({ http: out.http, ...extra, ...out.body }, null, 2));
}

async function main() {
  if (action === 'create') {
    const name = args[0] ?? 'hermes-keepalive';
    const type = args[1] ?? 'scheduled';
    if (name.length < 1 || name.length > 80 || !['local', 'remote', 'scheduled'].includes(type)) {
      console.error('用法: create [name 1..80] [local|remote|scheduled]');
      process.exit(2);
    }
    const { credentialId, token, tokenHash } = newToken();
    const pendingService = `MORROW_HEALTH_PENDING_${credentialId}`;
    // 先安全暂存，再调 RPC（响应丢失可按同 key+hash 恢复，不换 secret 重试）
    kcWriteStdin(pendingService, token);
    const key = idemKey();
    let out;
    try {
      out = await rpc({
        action: 'create', name, type,
        credential_id: credentialId, token_hash: tokenHash,
        expires_at: defaultExpiresAt(),
      }, key);
    } catch (e) {
      kcDelete(pendingService);
      throw e;
    }
    if (!out.body?.ok) {
      kcDelete(pendingService);
      printResult(out, { idempotency_key: key });
      process.exit(1);
    }
    kcDelete(pendingService);
    if (out.body.replayed) {
      // 同 key 重放：不覆盖已保存的正式 token，只展示非敏感结果
      printResult(out, { idempotency_key: key });
      return;
    }
    // 成功：转存固定生产键
    kcWriteStdin(TOKEN_SERVICE, token);
    console.log('=== 新 token（仅显示一次，已入 keychain MORROW_AGENT_TOKEN）===');
    console.log(token);
    console.log('=== 非敏感结果 ===');
    printResult(out, { idempotency_key: key });
  } else if (action === 'rotate') {
    const [clientId, oldCredentialId] = args;
    if (!clientId || !oldCredentialId) {
      console.error('用法: rotate <client_id> <old_credential_id>（新凭据试通后脚本自动撤旧）');
      process.exit(2);
    }
    const { credentialId, token, tokenHash } = newToken();
    const pendingService = `MORROW_HEALTH_PENDING_${credentialId}`;
    kcWriteStdin(pendingService, token);
    let out;
    try {
      out = await rpc({
        action: 'rotate', client_id: clientId,
        credential_id: credentialId, token_hash: tokenHash,
        expires_at: defaultExpiresAt(),
      }, idemKey());
    } catch (e) {
      kcDelete(pendingService);
      throw e;
    }
    if (!out.body?.ok) {
      kcDelete(pendingService);
      printResult(out);
      process.exit(1);
    }
    kcWriteStdin(TOKEN_SERVICE, token);
    kcDelete(pendingService);
    console.log('=== 新 token（仅显示一次，已入 keychain MORROW_AGENT_TOKEN）===');
    console.log(token);
    console.log('=== rotate 非敏感结果 ===');
    printResult(out);
    // 新 token 已落 keychain；按流程撤旧凭据（旧凭据已被 RPC 收紧至 24h 内）
    const revokeOut = await rpc(
      { action: 'revoke', client_id: clientId, target: 'credential', credential_id: oldCredentialId },
      randomUUID());
    console.log('=== revoke 旧凭据结果 ===');
    printResult(revokeOut);
    if (!revokeOut.body?.ok) process.exit(1);
  } else if (action === 'revoke') {
    const [clientId] = args;
    if (!clientId) { console.error('用法: revoke <client_id>'); process.exit(2); }
    const out = await rpc({ action: 'revoke', client_id: clientId, target: 'client' }, idemKey());
    if (out.body?.ok) kcDelete(TOKEN_SERVICE);
    printResult(out);
    if (!out.body?.ok) process.exit(1);
  } else if (action === 'revoke-credential') {
    const [clientId, credentialId] = args;
    if (!clientId || !credentialId) { console.error('用法: revoke-credential <client_id> <credential_id>'); process.exit(2); }
    const out = await rpc({ action: 'revoke', client_id: clientId, target: 'credential', credential_id: credentialId }, idemKey());
    printResult(out);
    if (!out.body?.ok) process.exit(1);
  } else {
    console.error('未知 action。支持 create / rotate / revoke / revoke-credential');
    process.exit(2);
  }
}

main().catch((e) => { console.error(`失败: ${e.message}`); process.exit(1); });
