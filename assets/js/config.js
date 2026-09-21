/* Morrow 运行时配置（P0-006）。
 * 公共项目配置（Project URL + publishable key）只允许来自两处：
 *   1) 本机浏览器存储（localStorage `morrow.config.v1`，由 owner 在配置面板粘贴保存）；
 *   2) 一次性 URL 查询参数 `?sb_url=&sb_key=`（用于本机自动化注入测试，应用后立即从地址栏抹除）。
 * 任何密钥/publishable key 都不得写进源码、dist、manifest 或日志。
 */
(function () {
  'use strict';
  const Morrow = (window.Morrow = window.Morrow || {});

  const STORAGE_KEY = 'morrow.config.v1';
  // publishable key 形如 sb_publishable_xxx（≥16 位载荷）；兼容旧 anon JWT（eyJ...三段）。
  const KEY_PATTERN = /^(sb_publishable_[A-Za-z0-9_-]{16,}|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)$/;
  const URL_PATTERN = /^https:\/\/[a-z0-9][a-z0-9-]*\.supabase\.co$/i;

  function validate(url, key) {
    const problems = [];
    if (!URL_PATTERN.test(url || '')) {
      problems.push('项目地址必须是 https://<project-ref>.supabase.co 形式');
    }
    if (!KEY_PATTERN.test(key || '')) {
      problems.push('Publishable key 格式不正确（应以 sb_publishable_ 开头）');
    }
    return problems; // 空数组 = 通过
  }

  function readStorage() {
    try {
      const raw = window.localStorage.getItem(STORAGE_KEY);
      if (!raw) return null;
      const parsed = JSON.parse(raw);
      if (typeof parsed.url !== 'string' || typeof parsed.key !== 'string') return null;
      return { url: parsed.url, key: parsed.key, saved_at: parsed.saved_at || null };
    } catch (_) {
      return null; // 存储被禁/损坏时按未配置处理，由 storage probe 另行报告
    }
  }

  function writeStorage(cfg) {
    window.localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({ url: cfg.url, key: cfg.key, saved_at: new Date().toISOString() })
    );
  }

  function clearStorage() {
    try {
      window.localStorage.removeItem(STORAGE_KEY);
    } catch (_) { /* 忽略 */ }
  }

  // 一次性查询参数注入：应用 → 持久化 → 抹除地址栏参数，避免 key 长期留在浏览器历史/书签。
  function consumeQueryParams() {
    try {
      const q = new URLSearchParams(window.location.search);
      const url = q.get('sb_url');
      const key = q.get('sb_key');
      if (!url && !key) return false;
      const problems = validate(url || '', key || '');
      if (problems.length === 0) {
        writeStorage({ url: url, key: key });
      }
      const clean = window.location.pathname + window.location.hash;
      window.history.replaceState(null, '', clean);
      return problems.length === 0;
    } catch (_) {
      return false;
    }
  }

  Morrow.config = {
    STORAGE_KEY: STORAGE_KEY,
    validate: validate,
    load: readStorage,
    save: writeStorage,
    clear: clearStorage,
    consumeQueryParams: consumeQueryParams,
  };
})();
