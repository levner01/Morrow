#!/usr/bin/env node
// P0-004｜health 客户端 token 签发/轮换/撤销最小受限脚本（C-05.1）
//
// 纪律：
// - token 本机生成（32B 高熵），形态 mrw_v1.<credential_uuid>.<base64url_secret>
// - 先安全暂存 keychain 再调 RPC；RPC 只提交整个 token 的 SHA-256 摘要（hex64）
// - RPC 失败即删除暂存；原始 token 只展示一次，不进日志/git/receipt
// - 身份凭据全部走环境变量：MORROW_SUPABASE_URL / MORROW_PUBLISHABLE_KEY / MORROW_OWNER_JWT
//   （owner JWT 由操作者现取现注，不落地）
//
// 用法：
//   node health-client-token.mjs create <name> <local|remote|scheduled>
//   node health-client-token.mjs rotate <client_id>
//   node health-client-token.mjs revoke-client <client_id>
//   node health-client-token.mjs revoke-credential <client_id> <credential_id>

import { createHash, randomUUID, randomBytes } from 'node:crypto';
import { execFileSync } from 'node:child_process';

const { MORROW_SUPABASE_URL, MORROW_PUBLISHABLE_KEY, MORROW_OWNER_JWT } = process.env;
if (!MORROW_SUPABASE_URL || !MORROW_PUBLISHABLE_KEY || !MORROW_OWNER_JWT) {
  console.error('缺少环境变量 MORROW_SUPABASE_URL / MORROW_PUBLISHABLE_KEY / MORROW_OWNER_JWT');
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

function keychainSave(service, account, value) {
  execFileSync('security', ['add-generic-password', '-U', '-s', service, '-a', account, '-w', value], { stdio: 'pipe' });
}
function keychainDelete(service) {
  try { execFileSync('security', ['delete-generic-password', '-s', service], { stdio: 'pipe' }); } catch { /* 不存在可忽略 */ }
}

async function rpc(input, idempotencyKey) {
  const res = await fetch(`${MORROW_SUPABASE_URL}/rest/v1/rpc/manage_health_client_v1`, {
    method: 'POST',
    headers: {
      apikey: MORROW_PUBLISHABLE_KEY,
      Authorization: `Bearer ${MORROW_OWNER_JWT}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ api_version: '1', idempotency_key: idempotencyKey, input }),
  });
  const body = await res.json().catch(() => null);
  if (!res.ok || !body?.ok) {
    const code = body?.error?.code ?? `HTTP_${res.status}`;
    const msg = body?.error?.message ?? 'unknown';
    throw new Error(`manage_health_client_v1 失败: ${code} ${msg}`);
  }
  return body.result;
}

function defaultExpiresAt() {
  // 合同：显式值，不超过 90 天；默认 90 天
  return new Date(Date.now() + 90 * 24 * 3600 * 1000).toISOString();
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
    const idemKey = randomUUID();
    try {
      const result = await rpc({
        action: 'create', name, type,
        credential_id: credentialId, token_hash: tokenHash,
        expires_at: defaultExpiresAt(),
      }, idemKey);
      // 成功：转存到 client 键，删除暂存
      keychainSave(`MORROW_HEALTH_TOKEN_${result.client_id}`, credentialId, token);
      keychainDelete(pendingService);
      console.log('=== 新 token（仅显示一次，已入 keychain）===');
      console.log(token);
      console.log('=== 非敏感结果 ===');
      console.log(JSON.stringify(result, null, 2));
    } catch (e) {
      keychainDelete(pendingService);
      throw e;
    }
  } else if (action === 'rotate') {
    const [clientId] = args;
    if (!clientId) { console.error('用法: rotate <client_id>'); process.exit(2); }
    const { credentialId, token, tokenHash } = newToken();
    const pendingService = `MORROW_HEALTH_PENDING_${credentialId}`;
    keychainSave(pendingService, credentialId, token);
    try {
      const result = await rpc({
        action: 'rotate', client_id: clientId,
        credential_id: credentialId, token_hash: tokenHash,
        expires_at: defaultExpiresAt(),
      }, randomUUID());
      keychainSave(`MORROW_HEALTH_TOKEN_${clientId}`, credentialId, token);
      keychainDelete(pendingService);
      console.log('=== 新 token（仅显示一次，已入 keychain；旧凭据已收紧至 24h 内，试通后请 revoke-credential 撤旧）===');
      console.log(token);
      console.log(JSON.stringify(result, null, 2));
    } catch (e) {
      keychainDelete(pendingService);
      throw e;
    }
  } else if (action === 'revoke-client') {
    const [clientId] = args;
    if (!clientId) { console.error('用法: revoke-client <client_id>'); process.exit(2); }
    const result = await rpc({ action: 'revoke', client_id: clientId, target: 'client' }, randomUUID());
    keychainDelete(`MORROW_HEALTH_TOKEN_${clientId}`);
    console.log(JSON.stringify(result, null, 2));
  } else if (action === 'revoke-credential') {
    const [clientId, credentialId] = args;
    if (!clientId || !credentialId) { console.error('用法: revoke-credential <client_id> <credential_id>'); process.exit(2); }
    const result = await rpc({ action: 'revoke', client_id: clientId, target: 'credential', credential_id: credentialId }, randomUUID());
    console.log(JSON.stringify(result, null, 2));
  } else {
    console.error('未知 action。支持 create / rotate / revoke-client / revoke-credential');
    process.exit(2);
  }
}

main().catch((e) => { console.error(`失败: ${e.message}`); process.exit(1); });
