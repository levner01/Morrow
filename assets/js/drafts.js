/* Morrow 存储探针 + 草稿存储（P0-006）。
 * 失败矩阵：本地 storage 不可用时「阻止假装保存」，向用户说明并可下载无凭据草稿 JSON。
 * 探针在每次 boot 运行：localStorage 写/删实测 + IndexedDB open 实测，结果渲染到界面，
 * 让 file://（尤其 Safari 对 file origin 的限制）的能力差异对用户可见。
 * 草稿条目结构（C-07）：{record_key, input, idempotency_key, last_known_version, created_at, sent_at, state}
 * —— 本壳暂无业务表单，仅存框架与示例语义，登出时做未同步草稿检查。
 */
(function () {
  'use strict';
  const Morrow = (window.Morrow = window.Morrow || {});

  const DRAFTS_KEY = 'morrow.drafts.v1';
  const PROBE_DB = 'morrow-probe';

  // 实测 localStorage：写→读→删，任一异常即不可用（不猜）。
  function probeLocalStorage() {
    const probeKey = 'morrow.storage_probe.';
    try {
      window.localStorage.setItem(probeKey, '1');
      const readBack = window.localStorage.getItem(probeKey);
      window.localStorage.removeItem(probeKey);
      return readBack === '1' ? 'ok' : 'unavailable';
    } catch (_) {
      return 'unavailable';
    }
  }

  // 实测 IndexedDB：open 成功/阻塞/失败三态，带 1.5s 超时（file origin 下可能永不回调）。
  function probeIndexedDB() {
    return new Promise(function (resolve) {
      if (typeof window.indexedDB === 'undefined') {
        resolve('unavailable');
        return;
      }
      let settled = false;
      const timer = setTimeout(function () {
        if (!settled) {
          settled = true;
          resolve('blocked');
        }
      }, 1500);
      let req;
      try {
        req = window.indexedDB.open(PROBE_DB, 1);
      } catch (_) {
        clearTimeout(timer);
        resolve('unavailable');
        return;
      }
      req.onsuccess = function () {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        try {
          req.result.close();
        } catch (_) { /* 忽略 */ }
        resolve('ok');
      };
      req.onerror = function () {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve('unavailable');
      };
      req.onblocked = function () {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve('blocked');
      };
    });
  }

  async function probe() {
    const ls = probeLocalStorage();
    const idb = await probeIndexedDB();
    return {
      origin: window.location.protocol === 'file:' ? 'file' : 'http',
      localStorage: ls,
      indexedDB: idb,
      usable: ls === 'ok', // 草稿承诺只建立在实测可用之上
    };
  }

  function readDrafts() {
    try {
      const raw = window.localStorage.getItem(DRAFTS_KEY);
      const parsed = raw ? JSON.parse(raw) : [];
      return Array.isArray(parsed) ? parsed : [];
    } catch (_) {
      return [];
    }
  }

  function writeDrafts(list) {
    window.localStorage.setItem(DRAFTS_KEY, JSON.stringify(list));
  }

  function addDraft(draft) {
    const list = readDrafts();
    const entry = {
      record_key: String(draft.record_key || ''),
      input: draft.input || {},
      idempotency_key: draft.idempotency_key || null,
      last_known_version: draft.last_known_version || null,
      created_at: new Date().toISOString(),
      sent_at: null,
      state: 'draft_saved',
    };
    list.push(entry);
    writeDrafts(list);
    return entry;
  }

  function unsyncedCount() {
    return readDrafts().filter(function (d) {
      return d && d.state !== 'synced';
    }).length;
  }

  function clearDrafts() {
    try {
      window.localStorage.removeItem(DRAFTS_KEY);
    } catch (_) { /* 忽略 */ }
  }

  // 无凭据草稿导出（C-07 降级路径）：不含 token/密码/会话，仅草稿业务字段。
  function exportJson() {
    return JSON.stringify(
      { kind: 'morrow-drafts', schema_version: 1, exported_at: new Date().toISOString(), drafts: readDrafts() },
      null,
      2
    );
  }

  Morrow.storage = { probe: probe, DRAFTS_KEY: DRAFTS_KEY };
  Morrow.drafts = {
    add: addDraft,
    count: unsyncedCount,
    clear: clearDrafts,
    exportJson: exportJson,
    _read: readDrafts,
  };
})();
