// P0-007｜health-only Agent Edge adapter（M1 唯一开放的 Agent 路由）
// 合同：02-contracts.md C-06（health 独立函数、仅 GET、错误模型、5 req/min/client）
//
// 纪律：
// - 仅接受 GET；其余 method → 405
// - Bearer token 只做 SHA-256 摘要后经 PostgREST RPC 送库比对；token 明文不进日志/响应
// - 缺失/错配/过期/撤销一律 401 UNAUTHENTICATED（不区分原因，防探针）
// - 错误 message 不含 token、不含 SQL、不含内部对象细节
// - 25s 显式 deadline（躲 Keepalive 宿主 30s 总 deadline）

const SUPABASE_URL = Deno.env.get('SUPABASE_URL');
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
const DEADLINE_MS = 25_000;

function jsonResponse(status: number, body: unknown, extraHeaders: Record<string, string> = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8', ...extraHeaders },
  });
}

function errBody(code: string, message: string, requestId: string) {
  return { ok: false, error: { code, message, retryable: code === 'RATE_LIMITED' || code === 'STORAGE_UNAVAILABLE', request_id: requestId } };
}

async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, '0')).join('');
}

Deno.serve(async (req: Request) => {
  const requestId = crypto.randomUUID();

  if (req.method !== 'GET') {
    return jsonResponse(405, errBody('METHOD_NOT_ALLOWED', '仅支持 GET', requestId), { allow: 'GET' });
  }
  if (!SUPABASE_URL || !SERVICE_ROLE_KEY) {
    return jsonResponse(503, errBody('STORAGE_UNAVAILABLE', '上游暂不可用', requestId));
  }

  const auth = req.headers.get('authorization') ?? '';
  const match = /^Bearer\s+(\S+)\s*$/.exec(auth);
  if (!match) {
    return jsonResponse(401, errBody('UNAUTHENTICATED', '无效凭据', requestId));
  }

  let tokenHash: string;
  try {
    tokenHash = await sha256Hex(match[1]);
  } catch {
    return jsonResponse(401, errBody('UNAUTHENTICATED', '无效凭据', requestId));
  }

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
