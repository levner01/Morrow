/* Morrow 存储探针 + 草稿存储（MVP-003 扩展）。
 * 失败矩阵：本地 storage 不可用时「阻止假装保存」，向用户说明并可下载无凭据草稿 JSON。
 * 探针在每次 boot 运行：localStorage 写/删实测 + IndexedDB open 实测，结果渲染到界面，
 * 让 file://（尤其 Safari 对 file origin 的限制）的能力差异对用户可见。
 *
 * MVP-003 扩展：
 * 1. 跨 owner 隔离：草稿 key 含 owner_uid + device_id 复合 namespace，不同账号登录各存各的。
 * 2. 标识列：草稿必须含 {browser_version, device_id, biz_date, created_at, type}。
 * 3. 存储失败处理：storage 拒绝时绝不谎报安全保存，显示"无法持久化"提示 + 下载草稿 JSON 按钮。
 * 4. 探针文案三值化：origin 区分 file / http / https（修复 MVP-002 顺手修复 3）。
 */
(function () {
  'use strict';
  const Morrow = (window.Morrow = window.Morrow || {});

  const PROBE_DB = 'morrow-probe';
  const DEVICE_KEY = 'morrow.device.v1';

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

  // MVP-002 顺手修复 3：探针文案三值化（file / http / https）
  function getOriginType() {
    const protocol = window.location.protocol;
    if (protocol === 'file:') return 'file';
    if (protocol === 'https:') return 'https';
    return 'http'; // 含 http:// 和 loopback (127.0.0.1)
  }

  async function probe() {
    const ls = probeLocalStorage();
    const idb = await probeIndexedDB();
    return {
      origin: getOriginType(),
      localStorage: ls,
      indexedDB: idb,
      usable: ls === 'ok', // 草稿承诺只建立在实测可用之上
    };
  }

  // ---------- 跨 owner 隔离的草稿存储 ----------

  // 获取当前 owner_uid（从 session 中派生，未登录时返回 null）
  function getCurrentOwnerUid() {
    // 从 Morrow.app 的当前用户中获取（如果已登录）
    // 注意：这个函数需要在 app.js 登录成功后设置当前用户
    if (Morrow.app && typeof Morrow.app.getCurrentUser === 'function') {
      const user = Morrow.app.getCurrentUser();
      return user && user.id ? user.id : null;
    }
    return null;
  }

  // 获取设备 ID（如果不存在则生成）
  function getDeviceId() {
    try {
      let id = window.localStorage.getItem(DEVICE_KEY);
      if (!id) {
        id = 'web-' + window.crypto.randomUUID();
        window.localStorage.setItem(DEVICE_KEY, id);
      }
      return id;
    } catch (_) {
      return 'web-anon-' + Math.random().toString(36).slice(2);
    }
  }

  // 草稿 key：owner_uid + device_id 复合 namespace（跨 owner 不泄露）
  function getDraftsKey() {
    const ownerUid = getCurrentOwnerUid();
    const deviceId = getDeviceId();
    if (!ownerUid) {
      // 未登录时使用临时 key（登录后会迁移到正式 key）
      return 'morrow.drafts.v1.anonymous.' + deviceId;
    }
    return 'morrow.drafts.v1.' + ownerUid + '.' + deviceId;
  }

  // 迁移匿名草稿到正式 owner namespace（登录成功后调用）
  function migrateAnonymousDrafts() {
    const ownerUid = getCurrentOwnerUid();
    if (!ownerUid) return;

    const deviceId = getDeviceId();
    const anonymousKey = 'morrow.drafts.v1.anonymous.' + deviceId;
    const ownerKey = 'morrow.drafts.v1.' + ownerUid + '.' + deviceId;

    try {
      const anonymousDrafts = window.localStorage.getItem(anonymousKey);
      if (anonymousDrafts) {
        // 合并到 owner key（如果 owner key 已有数据，保留两者）
        const existingDrafts = window.localStorage.getItem(ownerKey);
        if (!existingDrafts) {
          window.localStorage.setItem(ownerKey, anonymousDrafts);
        } else {
          // 合并：anonymous 草稿追加到 owner 草稿
          const anonymous = JSON.parse(anonymousDrafts);
          const existing = JSON.parse(existingDrafts);
          const merged = Array.isArray(existing) ? existing.concat(anonymous) : anonymous;
          window.localStorage.setItem(ownerKey, JSON.stringify(merged));
        }
        // 清除匿名草稿
        window.localStorage.removeItem(anonymousKey);
      }
    } catch (_) {
      // 迁移失败不阻断登录流程
    }
  }

  function readDrafts() {
    try {
      const raw = window.localStorage.getItem(getDraftsKey());
      const parsed = raw ? JSON.parse(raw) : [];
      return Array.isArray(parsed) ? parsed : [];
    } catch (_) {
      return [];
    }
  }

  function writeDrafts(list) {
    try {
      window.localStorage.setItem(getDraftsKey(), JSON.stringify(list));
      return { ok: true };
    } catch (err) {
      // 存储失败：配额/权限/隐私模式
      return { ok: false, error: err };
    }
  }

  // 添加草稿（含标识列：browser_version, device_id, biz_date, created_at, type）
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
      // MVP-003 标识列
      browser_version: navigator.userAgent || 'unknown',
      device_id: getDeviceId(),
      biz_date: draft.biz_date || '',
      type: draft.type || 'unknown',
    };
    list.push(entry);
    const result = writeDrafts(list);
    if (!result.ok) {
      // 存储失败：绝不谎报安全保存
      return { ok: false, error: result.error, entry: entry };
    }
    return { ok: true, entry: entry };
  }

  function updateDraft(recordKey, updates) {
    const list = readDrafts();
    const index = list.findIndex(function (d) {
      return d && d.record_key === recordKey;
    });
    if (index === -1) return { ok: false, error: 'draft not found' };

    list[index] = Object.assign({}, list[index], updates);
    const result = writeDrafts(list);
    if (!result.ok) {
      return { ok: false, error: result.error };
    }
    return { ok: true, entry: list[index] };
  }

  function removeDraft(recordKey) {
    const list = readDrafts();
    const filtered = list.filter(function (d) {
      return d && d.record_key !== recordKey;
    });
    const result = writeDrafts(filtered);
    if (!result.ok) {
      return { ok: false, error: result.error };
    }
    return { ok: true };
  }

  function unsyncedCount() {
    return readDrafts().filter(function (d) {
      return d && d.state !== 'synced';
    }).length;
  }

  function clearDrafts() {
    try {
      window.localStorage.removeItem(getDraftsKey());
      return { ok: true };
    } catch (err) {
      return { ok: false, error: err };
    }
  }

  // 无凭据草稿导出（C-07 降级路径）：不含 token/密码/会话，仅草稿业务字段。
  function exportJson() {
    return JSON.stringify(
      {
        kind: 'morrow-drafts',
        schema_version: 1,
        exported_at: new Date().toISOString(),
        owner_uid: getCurrentOwnerUid(),
        device_id: getDeviceId(),
        drafts: readDrafts(),
      },
      null,
      2
    );
  }

  // 下载草稿 JSON 到文件
  function downloadDrafts() {
    try {
      const blob = new Blob([exportJson()], { type: 'application/json' });
      const a = document.createElement('a');
      a.href = URL.createObjectURL(blob);
      a.download = 'morrow-drafts-' + new Date().toISOString().slice(0, 10) + '.json';
      document.body.appendChild(a);
      a.click();
      a.remove();
      setTimeout(function () {
        URL.revokeObjectURL(a.href);
      }, 1000);
      return { ok: true };
    } catch (err) {
      return { ok: false, error: err };
    }
  }

  Morrow.storage = { probe: probe };
  Morrow.drafts = {
    add: addDraft,
    update: updateDraft,
    remove: removeDraft,
    count: unsyncedCount,
    clear: clearDrafts,
    exportJson: exportJson,
    download: downloadDrafts,
    migrateAnonymousDrafts: migrateAnonymousDrafts,
    getDeviceId: getDeviceId,
    _read: readDrafts,
    _getKey: getDraftsKey,
  };
})();
