/* Morrow transport 层（P0-006）：唯一允许触碰 supabase-js 的层。
 * 职责：client 装配（超时 fetch、自定义 session 存储）、登录/会话刷新/登出、
 * 把 SDK/网络错误映射为 UI 可消费的有限错误集。UI 与 drafts 不直接调 SDK。
 * 纪律：任何分支不得把 token、密码、session 原文写进 console / 返回值 / 存储（session 由 SDK 自管）。
 */
(function () {
  'use strict';
  const Morrow = (window.Morrow = window.Morrow || {});

  const CALL_TIMEOUT_MS = 12000; // 失败矩阵：超时 10s 级，这里给 12s 含 TLS 握手余量
  let client = null;
  let currentConfig = null;

  // 统一超时 fetch：所有 SDK 出站请求（Auth/PostgREST）都经此包装，AbortController 兜底。
  function timeoutFetch(input, init) {
    const controller = new AbortController();
    const timer = setTimeout(function () {
      controller.abort();
    }, CALL_TIMEOUT_MS);
    const merged = Object.assign({}, init || {}, { signal: controller.signal });
    return fetch(input, merged).finally(function () {
      clearTimeout(timer);
    });
  }

  // session 存储适配：包 try/catch，存储不可用时让 SDK 退回内存态（不假装持久化成功）。
  function storageAdapter() {
    const prefix = 'morrow.auth.';
    return {
      getItem: function (key) {
        try {
          return window.localStorage.getItem(prefix + key);
        } catch (_) {
          return null;
        }
      },
      setItem: function (key, value) {
        try {
          window.localStorage.setItem(prefix + key, value);
        } catch (_) { /* 配额/权限失败：SDK 保留内存态，由 storage probe 向用户报告 */ }
      },
      removeItem: function (key) {
        try {
          window.localStorage.removeItem(prefix + key);
        } catch (_) { /* 忽略 */ }
      },
    };
  }

  function configured() {
    return client !== null;
  }

  function init(cfg) {
    if (typeof window.supabase === 'undefined' || !window.supabase.createClient) {
      throw new Error('SDK_NOT_LOADED');
    }
    currentConfig = cfg;
    client = window.supabase.createClient(cfg.url, cfg.key, {
      auth: {
        storageKey: 'morrow.session.v1',
        storage: storageAdapter(),
        persistSession: true,
        autoRefreshToken: true,
        detectSessionInUrl: false, // M1 不依赖邮件回跳，杜绝 token 进地址栏
      },
      global: {
        fetch: timeoutFetch,
      },
    });
    return client;
  }

  // 将 SDK / PostgREST / fetch 错误收敛为有限错误集；message 面向用户，绝不拼 token/SQL。
  function normalizeError(err) {
    if (!err) {
      return { kind: 'internal', text: '发生未知错误，请重试', retryable: true };
    }
    const msg = String(err.message || '');
    const status = typeof err.status === 'number' ? err.status : null;
    if (err.name === 'AbortError' || /aborted|timed? ?out/i.test(msg) || err.name === 'TimeoutError') {
      return { kind: 'network', text: '连接服务器超时，请检查网络后重试', retryable: true };
    }
    if (err.name === 'AuthRetryableFetchError' || err.name === 'FetchError' || /fetch failed|networkerror|failed to fetch/i.test(msg)) {
      return { kind: 'network', text: '无法连接到服务器，请检查网络后重试', retryable: true };
    }
    if (/OWNER_DENIED/.test(msg)) {
      return { kind: 'owner_denied', text: '当前登录账号不是该工作区的 owner，请检查配置或更换账号', retryable: false };
    }
    if (/UNAUTHENTICATED|invalid jwt|jwt expired|session/i.test(msg) && status === 401) {
      return { kind: 'auth_expired', text: '登录已过期，请重新登录', retryable: false };
    }
    if (status === 400 && /invalid_credentials|invalid login/i.test(msg)) {
      return { kind: 'invalid_credentials', text: '邮箱或密码不正确', retryable: false };
    }
    if (status === 400 && /validation|invalid/i.test(msg)) {
      return { kind: 'invalid_request', text: '请求格式不正确，请检查输入', retryable: false };
    }
    if (status === 429 || /too many requests|rate limit/i.test(msg)) {
      return { kind: 'rate_limited', text: '请求过于频繁，请稍后再试', retryable: true };
    }
    if (status !== null && status >= 500) {
      return { kind: 'server', text: '服务暂不可用，请稍后再试', retryable: true };
    }
    return { kind: 'internal', text: '操作失败，请重试', retryable: true };
  }

  async function login(email, password) {
    if (!client) throw new Error('transport not initialized');
    const trimmed = String(email || '').trim();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(trimmed)) {
      return { ok: false, error: { kind: 'invalid_request', text: '邮箱格式不正确', retryable: false } };
    }
    if (typeof password !== 'string' || password.length < 6) {
      return { ok: false, error: { kind: 'invalid_request', text: '密码至少 6 位', retryable: false } };
    }
    try {
      const res = await client.auth.signInWithPassword({ email: trimmed, password: password });
      if (res.error) {
        return { ok: false, error: normalizeError(res.error) };
      }
      return { ok: true, user: sanitizeUser(res.data.user) };
    } catch (err) {
      return { ok: false, error: normalizeError(err) };
    }
  }

  // 本地会话 + 过期自动刷新（getSession 内部会在过期时走 refresh）。
  async function currentSession() {
    if (!client) return { session: null, error: null };
    try {
      const res = await client.auth.getSession();
      if (res.error) {
        return { session: null, error: normalizeError(res.error) };
      }
      const s = res.data.session;
      if (!s || !s.user) return { session: null, error: null };
      return { session: sanitizeUser(s.user), error: null };
    } catch (err) {
      return { session: null, error: normalizeError(err) };
    }
  }

  async function refresh() {
    if (!client) return { ok: false, error: { kind: 'internal', text: '客户端未初始化', retryable: false } };
    try {
      const res = await client.auth.refreshSession();
      if (res.error) return { ok: false, error: normalizeError(res.error) };
      return { ok: true, user: res.data.user ? sanitizeUser(res.data.user) : null };
    } catch (err) {
      return { ok: false, error: normalizeError(err) };
    }
  }

  // 轻量权威验证：经 Core 只读 RPC 证明 JWT + owner allowlist + 网络全通。
  // 合同（C-04）：public RPC 统一收单参数 p_envelope jsonb = {api_version, idempotency_key, input}。
  async function verifyOwner() {
    if (!client) return { ok: false, error: { kind: 'internal', text: '客户端未初始化', retryable: false } };
    try {
      const envelope = {
        api_version: '1',
        idempotency_key: window.crypto.randomUUID(),
        input: {},
      };
      const res = await client.rpc('get_workspace_revision_v1', { p_envelope: envelope });
      if (res.error) {
        return { ok: false, error: normalizeError(res.error) };
      }
      return { ok: true, revision: res.data };
    } catch (err) {
      return { ok: false, error: normalizeError(err) };
    }
  }

  // 通用业务 RPC 通道（MVP-002 起）：与 verifyOwner 同一 C-04 信封协议，input 由调用方给。
  // 业务拒绝统一 HTTP 200 + ok:false（api-mapping 错误码表）；网络/Auth 异常走 normalizeError。
  // fn 为服务端 RPC 名（白名单由 Core 控制），input 必须符合对应 commands/*.schema.json。
  async function rpc(fn, input) {
    if (!client) return { ok: false, error: { kind: 'internal', text: '客户端未初始化', retryable: false } };
    try {
      const envelope = {
        api_version: '1',
        idempotency_key: window.crypto.randomUUID(),
        input: input || {},
      };
      const res = await client.rpc(fn, { p_envelope: envelope });
      if (res.error) {
        return { ok: false, error: normalizeError(res.error) };
      }
      // Core 统一信封：{ok:true, result:{...}, request_id, server_time}
      const body = res.data;
      if (body && typeof body === 'object' && 'ok' in body) {
        if (body.ok) return { ok: true, result: body.result, request_id: body.request_id };
        const e = (body.error && typeof body.error === 'object' && body.error) || {};
        return {
          ok: false,
          error: { kind: 'internal', text: e.message || '请求被拒绝', retryable: !!e.retryable, code: e.code, details: e.details },
        };
      }
      return { ok: true, result: body };
    } catch (err) {
      return { ok: false, error: normalizeError(err) };
    }
  }

  async function logout() {
    if (!client) return;
    try {
      await client.auth.signOut();
    } catch (_) {
      /* 离线登出：本地清理照做 */
    }
    // 本地 session 键全清（含 SDK 内存引用置空），不重试网络。
    try {
      const keys = [];
      for (let i = 0; i < window.localStorage.length; i += 1) {
        const k = window.localStorage.key(i);
        if (k && k.indexOf('morrow.auth.') === 0) keys.push(k);
      }
      keys.forEach(function (k) {
        window.localStorage.removeItem(k);
      });
    } catch (_) { /* 忽略 */ }
    client = null;
  }

  // 只暴露脱敏用户视图给 UI；绝不返回 access/refresh token。
  function sanitizeUser(user) {
    if (!user) return null;
    return {
      id: user.id,
      email: user.email || '',
      lastSignIn: user.last_sign_in_at || null,
    };
  }

  Morrow.transport = {
    CALL_TIMEOUT_MS: CALL_TIMEOUT_MS,
    init: init,
    configured: configured,
    login: login,
    currentSession: currentSession,
    refresh: refresh,
    verifyOwner: verifyOwner,
    rpc: rpc,
    logout: logout,
    normalizeError: normalizeError,
  };
})();
