// P0-007｜health-only Agent Edge adapter（M1 唯一开放的 Agent 路由）
// 合同：02-contracts.md C-06（health 独立函数、仅 GET、错误模型、5 req/min/client）
//
// 认证模型（双因子，需求方 P0-007 提示词口径）：
//   1. 明文 token 与 Edge Secret `MORROW_AGENT_TOKEN` 做常数时间比较（Deno.env.get）
//   2. SHA-256(token) 经 PostgREST RPC 匹配 private.agent_credentials.token_hash
//      （DB 侧同时判 revoked_at / expires_at / client.enabled / scopes 与限流）
//   两者都过才放行；任一失败统一 401 UNAUTHENTICATED（不区分原因，防探针）。
//   注：这使 C-05.1 rotate 的 24h 旧凭据窗口在 Edge 层提前关闭——轮换流程必须
//   同步更新 Edge secret（runbook 已写）；DB 撤销在任何情况下都即时生效。
//
// 纪律：
// - 仅 GET；其余 method → 405
// - token/hash 明文与摘要都不进日志、不进响应；错误 message 不含 SQL
// - 响应体纯 JSON；成功只含合同字段 ok/status/db/server_time/request_id
// - 内部 deadline 25s（躲宿主 Keepalive 30s buffer）

const SUPABASE_URL = Deno.env.get('SUPABASE_URL');
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
// trim：Dashboard 粘贴/剪贴板常带入尾部换行；只容忍 secret 存储侧空白，不放松请求侧校验
const EXPECTED_TOKEN = Deno.env.get('MORROW_AGENT_TOKEN')?.trim();
const DEADLINE_MS = 25_000;

function jsonResponse(status: number, body: unknown, extraHeaders: Record<string, string> = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8', ...extraHeaders },
  });
}

function errBody(code: string, message: string, requestId: string) {
  return {
    ok: false,
    error: {
      code,
      message,
      retryable: code === 'RATE_LIMITED' || code === 'STORAGE_UNAVAILABLE',
      request_id: requestId,
    },
  };
}

async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, '0')).join('');
}

// 常数时间比较，防时序侧信道
function safeEqual(a: string, b: string): boolean {
  const ea = new TextEncoder().encode(a);
  const eb = new TextEncoder().encode(b);
  if (ea.length !== eb.length) return false;
  let diff = 0;
  for (let i = 0; i < ea.length; i++) diff |= ea[i] ^ eb[i];
  return diff === 0;
}

Deno.serve(async (req: Request) => {
  const requestId = crypto.randomUUID();

  if (req.method !== 'GET') {
    return jsonResponse(405, errBody('METHOD_NOT_ALLOWED', '仅支持 GET', requestId), { allow: 'GET' });
  }
  if (!SUPABASE_URL || !SERVICE_ROLE_KEY || !EXPECTED_TOKEN) {
    return jsonResponse(503, errBody('STORAGE_UNAVAILABLE', '上游暂不可用', requestId));
  }

  const auth = req.headers.get('authorization') ?? '';
  const match = /^Bearer\s+(\S+)\s*$/.exec(auth);
  if (!match || !safeEqual(match[1], EXPECTED_TOKEN)) {
    return jsonResponse(401, errBody('UNAUTHENTICATED', '无效凭据', requestId));
  }

  const tokenHash = await sha256Hex(match[1]);

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), DEADLINE_MS);
  try {
    const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/agent_health_check_v1`, {
      method: 'POST',
      headers: {
        apikey: SERVICE_ROLE_KEY,
        authorization: `Bearer ${SERVICE_ROLE_KEY}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({ p_token_hash: tokenHash }),
      signal: controller.signal,
    });
    const body = await res.json().catch(() => null);
    if (!res.ok || body === null) {
      return jsonResponse(503, errBody('STORAGE_UNAVAILABLE', '上游暂不可用', requestId));
    }
    if (body.ok === true) {
      // 只透传合同字段；绝不扩散任何额外键
      return jsonResponse(200, {
        ok: true,
        status: body.status,
        db: body.db,
        server_time: body.server_time,
        request_id: body.request_id ?? requestId,
      });
    }
    const code = body?.error?.code;
    if (code === 'SCOPE_DENIED') {
      return jsonResponse(403, errBody('SCOPE_DENIED', 'scope 不足', body?.error?.request_id ?? requestId));
    }
    if (code === 'RATE_LIMITED') {
      return jsonResponse(429, errBody('RATE_LIMITED', '超出限流上限', body?.error?.request_id ?? requestId), { 'retry-after': '60' });
    }
    // UNAUTHENTICATED 及其它一律按 401 处理（不区分缺失/错配/过期/撤销）
    return jsonResponse(401, errBody('UNAUTHENTICATED', '无效凭据', requestId));
  } catch {
    return jsonResponse(503, errBody('STORAGE_UNAVAILABLE', '上游暂不可用', requestId));
  } finally {
    clearTimeout(timer);
  }
});
