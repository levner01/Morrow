/* Morrow 导出服务（MVP-005）：一致、全量、无凭据的 JSON 导出。
 * 依据：02-contracts.md C-08/C-09、T11/T12；01-architecture.md AD-08/§3.9。
 *
 * 三条硬约束的实现位置：
 * 1) BIGINT 保真：transport.restText 返回原始响应文本（不经 supabase-js 的 JSON.parse），
 *    本模块用 parseLossless 解析——超出 Number.MAX_SAFE_INTEGER 的整数字面量与超精度
 *    浮点保留原始字符串，绝不经 double 往返（服务端视图已 BIGINT::text，双保险）。
 * 2) 一致性快照（T11/T12）：R0（revision）→ 全量 keyset 分页 → R1；R0≠R1 整包丢弃、
 *    从 R0 重新开始，最多重试 2 次（共 3 次尝试），绝不产出混合快照。
 * 3) 无凭据红线：列白名单与 0004 视图逐列对齐（agent_clients 不含 credentials/locator）；
 *    导出前 scanValue 防线扫敏感键名/值形态，命中即拒绝并取消下载。
 *
 * hash 只盖 data 段；canonicalization = RFC8785（JCS），官方向量见 tests/mvp005-export-pipeline.js。
 * round-trip：下载前对最终文件文本重新解析 + 重新 canonical hash，与记录值不一致即取消。
 */
(function () {
  'use strict';
  const Morrow = (window.Morrow = window.Morrow || {});

  const SCHEMA_VERSION = 1;
  const DEFAULT_PAGE_SIZE = 500; // C-08：keyset 分页 500/页
  const MAX_PAGES_PER_TABLE = 20000; // 守卫：500×20000=千万行级，防失控循环
  const MAX_ATTEMPTS = 3; // T12：1 次原始 + 最多 2 次整包重试
  const MAX_EXPORT_BYTES = 25 * 1024 * 1024; // C-08：25MiB 上限

  let pageSizeOverride = null; // 测试钩子：缩小页强制多页路径
  function currentPageSize() {
    return pageSizeOverride || DEFAULT_PAGE_SIZE;
  }

  // —— 导出表配置：显式列白名单，与 0004 视图层白名单逐列对齐（双保险）——
  const FETCHED_TABLES = [
    {
      key: 'life_data',
      view: 'export_life_data_v1',
      columns: [
        'id', 'user_id', 'module', 'entity_key', 'biz_date', 'payload', 'version',
        'source_type', 'source_id', 'created_at', 'updated_at', 'deleted_at',
      ],
    },
    {
      key: 'agent_clients',
      view: 'export_agent_clients_v1',
      columns: [
        'id', 'user_id', 'name', 'type', 'scopes', 'enabled', 'created_at',
        'updated_at', 'last_seen_at', 'revoked_at', 'version',
      ],
    },
    {
      key: 'activity_log',
      view: 'export_activity_log_v1',
      columns: [
        'id', 'user_id', 'actor_type', 'actor_id', 'agent_id', 'action', 'resource',
        'resource_id', 'request_id', 'metadata', 'created_at',
      ],
    },
  ];
  const SETTINGS_VIEW = 'export_workspace_settings_v1';
  const SETTINGS_COLUMNS = [
    'user_id', 'timezone', 'tracking_started_on', 'schedule_history',
    'version', 'created_at', 'updated_at',
  ];
  const STATE_VIEW = 'export_workspace_state_v1';
  // M1 封闭集合：export_agent_advice_v1 / export_automation_rules_v1 未授予
  // authenticated（0004 决策：Phase 激活时再授）。容器中固定为空数组，不发起请求。

  // ========== 保真 JSON 解析（递归下降；绝不 JSON.parse） ==========
  // 返回 { value, warnings }。warnings 记录被保真为字符串的数字字面量（bigint_as_string /
  // float_precision_as_string），供测试断言；运行时仅作诊断，不阻塞（保真已达成）。
  function parseLossless(text) {
    const src = String(text);
    let pos = 0;
    const warnings = [];

    function fail(msg) {
      throw new Error('LOSSLESS_PARSE_FAILED: ' + msg + ' (offset ' + pos + ')');
    }
    function skipWs() {
      while (pos < src.length && ' \t\n\r'.indexOf(src.charAt(pos)) >= 0) pos += 1;
    }
    function expect(word) {
      if (src.substr(pos, word.length) !== word) fail('expected ' + word);
      pos += word.length;
    }
    function parseValue() {
      skipWs();
      if (pos >= src.length) fail('unexpected end of input');
      const c = src.charAt(pos);
      if (c === '{') return parseObject();
      if (c === '[') return parseArray();
      if (c === '"') return parseString();
      if (c === 't') { expect('true'); return true; }
      if (c === 'f') { expect('false'); return false; }
      if (c === 'n') { expect('null'); return null; }
      return parseNumber();
    }
    function parseObject() {
      pos += 1; // '{'
      const obj = {};
      skipWs();
      if (src.charAt(pos) === '}') { pos += 1; return obj; }
      for (;;) {
        skipWs();
        if (src.charAt(pos) !== '"') fail('object key must be string');
        const key = parseString();
        skipWs();
        if (src.charAt(pos) !== ':') fail('expected :');
        pos += 1;
        obj[key] = parseValue();
        skipWs();
        const c = src.charAt(pos);
        if (c === ',') { pos += 1; continue; }
        if (c === '}') { pos += 1; return obj; }
        fail('expected , or }');
      }
    }
    function parseArray() {
      pos += 1; // '['
      const arr = [];
      skipWs();
      if (src.charAt(pos) === ']') { pos += 1; return arr; }
      for (;;) {
        arr.push(parseValue());
        skipWs();
        const c = src.charAt(pos);
        if (c === ',') { pos += 1; continue; }
        if (c === ']') { pos += 1; return arr; }
        fail('expected , or ]');
      }
    }
    function parseString() {
      pos += 1; // '"'
      let out = '';
      for (;;) {
        if (pos >= src.length) fail('unterminated string');
        const c = src.charAt(pos);
        if (c === '"') { pos += 1; return out; }
        if (c === '\\') {
          pos += 1;
          if (pos >= src.length) fail('bad escape');
          const e = src.charAt(pos);
          if (e === '"') out += '"';
          else if (e === '\\') out += '\\';
          else if (e === '/') out += '/';
          else if (e === 'b') out += '\b';
          else if (e === 'f') out += '\f';
          else if (e === 'n') out += '\n';
          else if (e === 'r') out += '\r';
          else if (e === 't') out += '\t';
          else if (e === 'u') {
            if (pos + 4 >= src.length) fail('bad \\u escape');
            const hex = src.substr(pos + 1, 4);
            if (!/^[0-9a-fA-F]{4}$/.test(hex)) fail('bad \\u escape');
            out += String.fromCharCode(parseInt(hex, 16));
            pos += 4;
          } else fail('bad escape char');
          pos += 1;
        } else {
          out += c;
          pos += 1;
        }
      }
    }
    function parseNumber() {
      const start = pos;
      if (src.charAt(pos) === '-') pos += 1;
      if (src.charAt(pos) === '0') {
        pos += 1;
      } else if (src.charAt(pos) >= '1' && src.charAt(pos) <= '9') {
        while (pos < src.length && src.charAt(pos) >= '0' && src.charAt(pos) <= '9') pos += 1;
      } else {
        fail('invalid number');
      }
      let isFloat = false;
      if (src.charAt(pos) === '.') {
        isFloat = true;
        pos += 1;
        if (!(src.charAt(pos) >= '0' && src.charAt(pos) <= '9')) fail('bad fraction');
        while (pos < src.length && src.charAt(pos) >= '0' && src.charAt(pos) <= '9') pos += 1;
      }
      if (src.charAt(pos) === 'e' || src.charAt(pos) === 'E') {
        isFloat = true;
        pos += 1;
        if (src.charAt(pos) === '+' || src.charAt(pos) === '-') pos += 1;
        if (!(src.charAt(pos) >= '0' && src.charAt(pos) <= '9')) fail('bad exponent');
        while (pos < src.length && src.charAt(pos) >= '0' && src.charAt(pos) <= '9') pos += 1;
      }
      const raw = src.slice(start, pos);
      if (!isFloat) {
        const n = Number(raw);
        if (Number.isSafeInteger(n)) return n;
        // 保真核心：超安全整数（|n| > 2^53-1）保留原始字符串，绝不经 double 往返
        warnings.push({ type: 'bigint_as_string', raw: raw });
        return raw;
      }
      const n = Number(raw);
      if (!Number.isFinite(n)) fail('non-finite number');
      // 浮点：有效数字 > 17 位时 double 表示可能丢真，保留原始字符串
      const mantissa = raw.replace(/^[+-]/, '').split(/[eE]/)[0].replace('.', '').replace(/^0+/, '');
      if (mantissa.length > 17) {
        warnings.push({ type: 'float_precision_as_string', raw: raw });
        return raw;
      }
      return n;
    }

    const value = parseValue();
    skipWs();
    if (pos !== src.length) fail('trailing content');
    return { value: value, warnings: warnings };
  }

  // ========== RFC8785 (JCS) canonicalization ==========
  // string → JSON.stringify（ES2019 well-formed，控制字符短转义与 JCS 一致）；
  // number → String(n)（ES6 Number::toString 即 JCS 序列化；-0 → "0"；非 finite 非法）；
  // object 键 → 默认 sort（UTF-16 code unit 升序，RFC8785 §3.2.3）。
  function canonicalize(v) {
    if (v === null) return 'null';
    const t = typeof v;
    if (t === 'boolean') return v ? 'true' : 'false';
    if (t === 'number') {
      if (!Number.isFinite(v)) throw new Error('JCS_NON_FINITE_NUMBER');
      if (v === 0) return '0';
      return String(v);
    }
    if (t === 'string') return JSON.stringify(v);
    if (t === 'object') {
      if (Array.isArray(v)) {
        let out = '[';
        for (let i = 0; i < v.length; i += 1) {
          if (i > 0) out += ',';
          out += canonicalize(v[i]);
        }
        return out + ']';
      }
      const keys = Object.keys(v).sort();
      let out = '{';
      for (let i = 0; i < keys.length; i += 1) {
        if (i > 0) out += ',';
        out += JSON.stringify(keys[i]) + ':' + canonicalize(v[keys[i]]);
      }
      return out + '}';
    }
    throw new Error('JCS_UNSUPPORTED_TYPE: ' + t);
  }

  async function sha256Hex(text) {
    const bytes = new TextEncoder().encode(text);
    const digest = await window.crypto.subtle.digest('SHA-256', bytes);
    const arr = new Uint8Array(digest);
    let hex = '';
    for (let i = 0; i < arr.length; i += 1) hex += ('0' + arr[i].toString(16)).slice(-2);
    return hex;
  }

  // ========== 无凭据防线（T-E5 的运行时侧；主验证在测试） ==========
  const SENSITIVE_KEY_RE = /(token|credential|secret|password|session|receipt|api[_-]?key)/i;
  const JWT_LIKE_RE = /^eyJ[A-Za-z0-9_-]{20,}\./;
  const SUPABASE_KEY_RE = /^(sb_(secret|publishable)_|sk-)/;

  function scanValue(v, path, hits) {
    if (v === null) return;
    if (typeof v === 'string') {
      if (JWT_LIKE_RE.test(v) || SUPABASE_KEY_RE.test(v)) hits.push(path + '（敏感值形态）');
      return;
    }
    if (typeof v === 'number' || typeof v === 'boolean') return;
    if (Array.isArray(v)) {
      for (let i = 0; i < v.length; i += 1) scanValue(v[i], path + '[' + i + ']', hits);
      return;
    }
    const keys = Object.keys(v);
    for (let i = 0; i < keys.length; i += 1) {
      if (SENSITIVE_KEY_RE.test(keys[i])) hits.push(path + '.' + keys[i] + '（敏感键名）');
      scanValue(v[keys[i]], path + '.' + keys[i], hits);
    }
  }

  // ========== 取数（全部经 transport.restText 原始文本通道） ==========

  async function readStateRow() {
    const res = await Morrow.transport.restText(STATE_VIEW + '?select=user_id,data_revision');
    if (!res.ok) throw res.error;
    const parsed = parseLossless(res.text);
    const arr = parsed.value;
    if (!Array.isArray(arr) || arr.length !== 1) {
      throw { kind: 'internal', text: '工作区状态读取异常（行数 ' + (Array.isArray(arr) ? arr.length : '?') + '）', retryable: false };
    }
    const row = arr[0];
    if (typeof row.user_id !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(row.user_id)) {
      throw { kind: 'internal', text: '工作区状态字段异常（user_id）', retryable: false };
    }
    let rev = row.data_revision;
    if (typeof rev === 'number' && Number.isSafeInteger(rev) && rev >= 0) rev = String(rev);
    if (typeof rev !== 'string' || !/^[0-9]+$/.test(rev)) {
      throw { kind: 'internal', text: '工作区状态字段异常（data_revision）', retryable: false };
    }
    return { user_id: row.user_id, data_revision: rev };
  }

  async function fetchSettings() {
    const res = await Morrow.transport.restText(SETTINGS_VIEW + '?select=' + SETTINGS_COLUMNS.join(','));
    if (!res.ok) throw res.error;
    const rows = parseLossless(res.text).value;
    if (!Array.isArray(rows) || rows.length !== 1) {
      throw { kind: 'internal', text: '工作区设置读取异常（应为且仅应为 1 行）', retryable: false };
    }
    const tz = rows[0].timezone;
    if (typeof tz !== 'string' || !tz) {
      throw { kind: 'internal', text: '工作区设置缺少 timezone', retryable: false };
    }
    return { rows: rows, timezone: tz };
  }

  // keyset 分页：order=id.asc&limit=N&id=gt.<lastId>；页未满即止。
  // 注意：PostgREST 只认 in-column 语法 id=gt.<value>（dotted 形式 id.gt= 返回 400，实测）。
  async function fetchKeyset(table) {
    const size = currentPageSize();
    const rows = [];
    let lastId = null;
    let pages = 0;
    for (;;) {
      let q = table.view + '?select=' + table.columns.join(',') + '&order=id.asc&limit=' + size;
      if (lastId !== null) q += '&id=gt.' + encodeURIComponent(lastId);
      const res = await Morrow.transport.restText(q);
      if (!res.ok) throw res.error;
      const page = parseLossless(res.text).value;
      if (!Array.isArray(page)) {
        throw { kind: 'internal', text: table.view + ' 返回非数组', retryable: false };
      }
      for (let i = 0; i < page.length; i += 1) rows.push(page[i]);
      pages += 1;
      if (page.length < size) break;
      const last = page[page.length - 1];
      if (!last || typeof last.id !== 'string') {
        throw { kind: 'internal', text: table.view + ' 行缺少 id，无法继续分页', retryable: false };
      }
      lastId = last.id;
      if (pages > MAX_PAGES_PER_TABLE) {
        throw { kind: 'export_too_large', text: table.view + ' 分页数超过守卫上限', retryable: false };
      }
    }
    return rows;
  }

  // 一致性快照：R0 → 全量读取 → R1；不等则抛 export_conflict（由调用方整包重试）。
  async function fetchConsistentSnapshot() {
    const r0 = await readStateRow();
    const settings = await fetchSettings();
    // 容器 data 段键序按 C-08 固定；封闭集合为常量空数组
    const data = {
      life_data: [],
      agent_advice: [],
      activity_log: [],
      automation_rules: [],
      agent_clients: [],
      workspace_settings: settings.rows,
    };
    for (let i = 0; i < FETCHED_TABLES.length; i += 1) {
      data[FETCHED_TABLES[i].key] = await fetchKeyset(FETCHED_TABLES[i]);
    }
    const r1 = await readStateRow();
    if (r0.data_revision !== r1.data_revision || r0.user_id !== r1.user_id) {
      throw { kind: 'export_conflict', text: '数据在导出期间发生变化', retryable: true };
    }
    return {
      owner_id: r0.user_id,
      timezone: settings.timezone,
      data_revision: r0.data_revision,
      data: data,
    };
  }

  // ========== 容器组装（C-08） ==========
  function releaseId() {
    if (window.MORROW_RELEASE && window.MORROW_RELEASE.id) return window.MORROW_RELEASE.id;
    return 'dev-source';
  }

  function buildContainer(snapshot, dataSha) {
    const data = snapshot.data;
    return {
      schema_version: SCHEMA_VERSION,
      exported_at: new Date().toISOString(),
      app_version: releaseId(),
      workspace: {
        owner_id: snapshot.owner_id,
        timezone: snapshot.timezone,
        data_revision: snapshot.data_revision,
      },
      data: data,
      counts: {
        life_data: data.life_data.length,
        agent_advice: data.agent_advice.length,
        activity_log: data.activity_log.length,
        automation_rules: data.automation_rules.length,
        agent_clients: data.agent_clients.length,
        workspace_settings: data.workspace_settings.length,
      },
      integrity: {
        algorithm: 'SHA-256',
        canonicalization: 'RFC8785',
        data_sha256: dataSha,
      },
    };
  }

  // ========== 主流程 ==========
  // 返回 { ok:true, filename, fileText, bytes, data_sha256 } 或 { ok:false, error }。
  // 下载动作不在本函数内（便于测试与 UI 解耦），由调用方触发。
  async function runExport(onStatus) {
    const notify = typeof onStatus === 'function' ? onStatus : function () {};
    let lastError = null;
    let snapshot = null;

    for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt += 1) {
      if (attempt === 1) {
        notify('正在读取工作区数据…', 'running');
      } else if (lastError && lastError.kind === 'export_conflict') {
        notify('数据在导出期间发生变化，正在重新获取一致快照（第 ' + attempt + ' 次尝试）…', 'retry');
      } else {
        notify('读取中断，正在重试（第 ' + attempt + ' 次尝试）…', 'retry');
      }
      try {
        snapshot = await fetchConsistentSnapshot();
        break;
      } catch (err) {
        lastError = err && err.kind ? err : { kind: 'internal', text: '导出过程中发生未知错误', retryable: true };
        if (!lastError.retryable || attempt === MAX_ATTEMPTS) {
          return { ok: false, error: lastError };
        }
      }
    }
    if (!snapshot) {
      return { ok: false, error: lastError || { kind: 'internal', text: '导出失败', retryable: false } };
    }

    notify('正在计算完整性校验和…', 'running');
    const hits = [];
    scanValue(snapshot.data, 'data', hits);
    if (hits.length > 0) {
      return {
        ok: false,
        error: {
          kind: 'export_security',
          text: '导出内容安全检查未通过：' + hits[0] + '，已拒绝导出',
          retryable: false,
        },
      };
    }

    const dataSha = await sha256Hex(canonicalize(snapshot.data));
    const container = buildContainer(snapshot, dataSha);
    const fileText = JSON.stringify(container);
    const bytes = new TextEncoder().encode(fileText).length;
    if (bytes > MAX_EXPORT_BYTES) {
      return {
        ok: false,
        error: {
          kind: 'export_too_large',
          text: '导出数据超过 25MiB 上限（当前 ' + fmtBytes(bytes) + '）',
          retryable: false,
        },
      };
    }

    // round-trip 自校验：文件文本重新解析 + 重新 canonical hash，必须与记录值一致。
    // 若文件中混入任何不安全数字，普通 JSON.parse 即破坏，hash 必不匹配 → 拒绝下载。
    let reparsed = null;
    try {
      reparsed = JSON.parse(fileText);
    } catch (_) {
      reparsed = null;
    }
    let roundTripOk = false;
    if (reparsed && reparsed.integrity && reparsed.integrity.data_sha256 === dataSha) {
      const sha2 = await sha256Hex(canonicalize(reparsed.data));
      roundTripOk = sha2 === dataSha;
    }
    if (!roundTripOk) {
      return {
        ok: false,
        error: {
          kind: 'export_integrity',
          text: '导出文件自校验失败（round-trip 哈希不一致），已取消下载',
          retryable: false,
        },
      };
    }

    const filename = 'life-workspace_' + localDateStr(snapshot.timezone) + '_schema-v1.json';
    return { ok: true, filename: filename, fileText: fileText, bytes: bytes, data_sha256: dataSha };
  }

  // ========== 辅助 ==========
  function localDateStr(tz) {
    try {
      return new Intl.DateTimeFormat('en-CA', {
        timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit',
      }).format(new Date());
    } catch (_) {
      return new Date().toISOString().slice(0, 10);
    }
  }

  function fmtBytes(n) {
    if (n >= 1024 * 1024) return (n / (1024 * 1024)).toFixed(1) + ' MiB';
    if (n >= 1024) return (n / 1024).toFixed(1) + ' KiB';
    return n + ' B';
  }

  function setStatus(el, text, kind) {
    if (!el) return;
    el.textContent = text;
    el.dataset.kind = kind || 'running';
    el.hidden = false;
  }

  function downloadFile(filename, fileText) {
    const blob = new Blob([fileText], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    setTimeout(function () { URL.revokeObjectURL(url); }, 5000);
  }

  // ========== UI 挂载（今日页次级位置：更改日型区之下） ==========
  function mount(host) {
    if (!host) return;
    host.innerHTML =
      '<div class="export-actions" data-testid="export-actions">' +
        '<button type="button" id="export-run-btn" class="btn-secondary btn-today-secondary">导出数据（JSON）</button>' +
      '</div>' +
      '<p class="export-status" id="export-status" data-testid="export-status" role="status" hidden></p>';
    const btn = host.querySelector('#export-run-btn');
    const statusEl = host.querySelector('#export-status');

    btn.addEventListener('click', function () {
      if (btn.disabled) return;
      btn.disabled = true;
      setStatus(statusEl, '正在读取工作区数据…', 'running');
      runExport(function (text, kind) { setStatus(statusEl, text, kind); })
        .then(function (result) {
          if (result.ok) {
            downloadFile(result.filename, result.fileText);
            setStatus(
              statusEl,
              '已导出 ' + result.filename + '（' + fmtBytes(result.bytes) + '，SHA-256 校验通过）',
              'ok'
            );
          } else {
            setStatus(statusEl, (result.error && result.error.text) || '导出失败', 'error');
          }
        })
        .catch(function () {
          setStatus(statusEl, '导出失败：发生未知错误', 'error');
        })
        .finally(function () {
          btn.disabled = false;
        });
    });
  }

  Morrow.export = {
    mount: mount,
    // 测试钩子（drafts.js _read 先例）：E2E 用小页宽证明真实 keyset 多页路径
    _setPageSize: function (n) {
      pageSizeOverride = typeof n === 'number' && n > 0 ? Math.floor(n) : null;
    },
    _internals: {
      parseLossless: parseLossless,
      canonicalize: canonicalize,
      sha256Hex: sha256Hex,
      scanValue: scanValue,
      runExport: runExport,
      buildContainer: buildContainer,
      fetchConsistentSnapshot: fetchConsistentSnapshot,
      TABLES: FETCHED_TABLES,
      DEFAULT_PAGE_SIZE: DEFAULT_PAGE_SIZE,
      MAX_ATTEMPTS: MAX_ATTEMPTS,
      MAX_EXPORT_BYTES: MAX_EXPORT_BYTES,
    },
  };
})();
