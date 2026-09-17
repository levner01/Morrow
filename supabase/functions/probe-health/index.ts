// P0-002 探针函数（验证后删除）：自定义 opaque token 认证。
// 部署参数 --no-verify-jwt（verify_jwt=false）：平台 JWT 校验关闭，
// handler 必须默认拒绝并逐请求校验 PROBE_TOKEN，不把 false 当公开接口。
Deno.serve(async (req: Request) => {
  const probeToken = Deno.env.get('PROBE_TOKEN') ?? '';
  const auth = req.headers.get('authorization') ?? '';
  if (!probeToken || auth !== `Bearer ${probeToken}`) {
    return new Response(JSON.stringify({ error: 'unauthorized' }), {
      status: 401,
      headers: { 'content-type': 'application/json' },
    });
  }
  // 认证通过后做一次真实只读 DB 调用（探针常量视图 probe_int8）
  const url = Deno.env.get('SUPABASE_URL') ?? '';
  const key = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
  if (!url || !key) {
    return new Response(JSON.stringify({ error: 'missing_edge_env' }), {
      status: 502,
      headers: { 'content-type': 'application/json' },
    });
  }
  const r = await fetch(`${url}/rest/v1/probe_int8?select=v`, {
    headers: { apikey: key, authorization: `Bearer ${key}` },
  });
  const body: Array<{ v?: string }> = await r.json().catch(() => []);
  return new Response(
    JSON.stringify({ status: 'ok', db_status: r.status, v: body?.[0]?.v ?? null }),
    { status: r.ok ? 200 : 502, headers: { 'content-type': 'application/json' } },
  );
});
