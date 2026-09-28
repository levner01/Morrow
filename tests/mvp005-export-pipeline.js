#!/usr/bin/env node
/* MVP-005 导出管线 Node 证明（T-E1b/T-E2b/T-E3b/T-E4/T-E5/T-E6/T-E7a）。
 * 方法：vm 沙箱加载发行 assets/js/export.js（真实 IIFE，非复制品），注入假 transport
 * （记录请求序列、支持竞态注入 / 原始文本覆盖），对 runExport 全链路断言。
 * RFC8785 向量：tests/fixtures/rfc8785/（cyberphone/json-canonicalization 官方 testdata，
 *   来源 https://github.com/cyberphone/json-canonicalization master testdata/）。
 * 运行：node tests/mvp005-export-pipeline.js；退出码 0=全绿。
 */
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const ROOT = path.resolve(__dirname, '..');
const OWNER = '0c645909-ebb5-4910-ab99-4f7b238c9529';

let passes = 0;
let failures = 0;
function check(name, cond, detail) {
  if (cond) {
    passes += 1;
    console.log('PASS ' + name);
  } else {
    failures += 1;
    console.log('FAIL ' + name + (detail ? ' :: ' + detail : ''));
  }
}

// —— 沙箱加载发行 export.js ——
function loadExportModule(transportMock) {
  const sandbox = {
    window: { crypto: globalThis.crypto, MORROW_RELEASE: { id: 'mvp005-pipeline-test' } },
    TextEncoder: TextEncoder,
    console: console,
  };
  sandbox.self = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(path.join(ROOT, 'assets/js/export.js'), 'utf8'), sandbox, {
    filename: 'assets/js/export.js',
  });
  const Morrow = sandbox.window.Morrow;
  Morrow.transport = transportMock; // export.js 运行时动态查找 Morrow.transport.restText
  return Morrow;
}

// —— 假 transport：keyset 语义（id 字典序）+ 请求记录 + 竞态/文本覆盖钩子 ——
function makeTransport(db, hooks) {
  const requests = [];
  const t = {
    requests: requests,
    restText: async function (pq) {
      if (hooks && hooks.before) hooks.before(pq, requests.length);
      requests.push(pq);
      const q = String(pq);
      const view = q.split('?')[0];
      const params = new URLSearchParams(q.split('?')[1] || '');
      let result;
      if (view === 'export_workspace_state_v1') {
        result = { ok: true, status: 200, text: JSON.stringify([{ user_id: db.user_id, data_revision: String(db.revision) }]) };
      } else if (view === 'export_workspace_settings_v1') {
        result = { ok: true, status: 200, text: JSON.stringify(db.settings) };
      } else if (db.tables[view]) {
        const table = db.tables[view];
        if (table.textOverride) {
          result = { ok: true, status: 200, text: table.textOverride };
        } else {
          const limit = parseInt(params.get('limit'), 10);
          // 与真实 PostgREST 一致：in-column 语法 id=gt.<value>（URLSearchParams 解出 'gt.<value>'）
          const idFilter = params.get('id') || '';
          const gt = idFilter.indexOf('gt.') === 0 ? idFilter.slice(3) : null;
          let rows = table.rows;
          if (gt) rows = rows.filter(function (r) { return r.id > gt; });
          result = { ok: true, status: 200, text: JSON.stringify(rows.slice(0, limit)) };
        }
      } else {
        result = { ok: false, status: 404, error: { kind: 'invalid_request', text: 'unknown view ' + view, retryable: false } };
      }
      if (hooks && hooks.after) hooks.after(pq, result);
      return result;
    },
  };
  return t;
}

function makeDb(lifeRows, clientRows, activityRows) {
  return {
    user_id: OWNER,
    revision: 42,
    settings: [{
      user_id: OWNER, timezone: 'Asia/Shanghai', tracking_started_on: '2026-09-17',
      schedule_history: [], version: '3',
      created_at: '2026-09-17T00:00:00Z', updated_at: '2026-09-20T00:00:00Z',
    }],
    tables: {
      export_life_data_v1: { rows: lifeRows || [] },
      export_agent_clients_v1: { rows: clientRows || [] },
      export_activity_log_v1: { rows: activityRows || [] },
    },
  };
}

function makeLifeRows(n) {
  const rows = [];
  for (let i = 0; i < n; i += 1) {
    rows.push({
      id: 'id-' + String(i).padStart(6, '0'),
      user_id: OWNER,
      module: 'anchor',
      entity_key: 'mvp005test:row-' + i,
      biz_date: '2026-09-28',
      payload: { payload_v: 1, note: 'row ' + i },
      version: String(i + 1),
      source_type: 'human', source_id: OWNER,
      created_at: '2026-09-28T00:00:00Z', updated_at: '2026-09-28T00:00:00Z', deleted_at: null,
    });
  }
  return rows;
}

function makeActivityRows(n) {
  const rows = [];
  for (let i = 0; i < n; i += 1) {
    rows.push({
      id: 'al-' + String(i).padStart(6, '0'),
      user_id: OWNER, actor_type: 'human', actor_id: OWNER, agent_id: null,
      action: 'human.opened', resource: 'workspace', resource_id: null,
      request_id: null, metadata: { device_id: 'dev-' + i, biz_date: '2026-09-28' },
      created_at: '2026-09-28T00:00:00Z',
    });
  }
  return rows;
}

const CLIENT_ROWS = [{
  id: 'cl-000001', user_id: OWNER, name: 'health-agent', type: 'health',
  scopes: ['health:read'], enabled: true,
  created_at: '2026-09-17T00:00:00Z', updated_at: '2026-09-17T00:00:00Z',
  last_seen_at: null, revoked_at: null, version: '1',
}];

// ============================================================
async function main() {
  const I = 'T-E6'; // RFC8785 官方向量（先跑：纯函数层）
  {
    const Morrow = loadExportModule(makeTransport(makeDb()));
    const names = ['arrays', 'french', 'structures', 'unicode', 'values', 'weird'];
    for (const n of names) {
      const input = fs.readFileSync(path.join(ROOT, 'tests/fixtures/rfc8785/input', n + '.json'), 'utf8');
      const expected = fs.readFileSync(path.join(ROOT, 'tests/fixtures/rfc8785/output', n + '.json'), 'utf8').trim();
      let got = null;
      let err = null;
      try {
        const parsed = Morrow.export._internals.parseLossless(input);
        got = Morrow.export._internals.canonicalize(parsed.value);
      } catch (e) {
        err = e.message;
      }
      check(I + ' RFC8785 向量 ' + n, got === expected, err || ('got=' + (got || '').slice(0, 80)));
    }
    // JCS 数字规则专项：-0 → "0"；1e+30 → ES6 序列化
    check(I + ' 负零', Morrow.export._internals.canonicalize(-0) === '0');
    check(I + ' 1e30', Morrow.export._internals.canonicalize(1e30) === '1e+30');
  }

  // T-E2b：BIGINT 保真（钉子 1）
  {
    const Morrow = loadExportModule(makeTransport(makeDb()));
    const raw = '{"v":9007199254740993,"safe":42,"big2":123456789012345678901234567890}';
    const parsed = Morrow.export._internals.parseLossless(raw);
    check('T-E2b 超安全整数保留原始字符串', parsed.value.v === '9007199254740993');
    check('T-E2b 更大整数同样保真', parsed.value.big2 === '123456789012345678901234567890');
    check('T-E2b 安全整数仍为 number', parsed.value.safe === 42 && typeof parsed.value.safe === 'number');
    check('T-E2b warning 记录', parsed.warnings.length === 2 && parsed.warnings[0].type === 'bigint_as_string');
    check('T-E2b 对照：JSON.parse 会破坏为 9007199254740992', JSON.parse(raw).v === 9007199254740992);

    // 端到端：原始响应文本含裸 BIGINT（未经视图 ::text 的场景）→ 容器中为字符串
    const bigRowText = '{"id":"id-big","user_id":"' + OWNER + '","module":"anchor","entity_key":"mvp005test:big",' +
      '"biz_date":"2026-09-28","payload":{"payload_v":1},"version":9007199254740993,"source_type":"human",' +
      '"source_id":"' + OWNER + '","created_at":"2026-09-28T00:00:00Z","updated_at":"2026-09-28T00:00:00Z","deleted_at":null}';
    const db = makeDb([], [], []);
    db.tables.export_life_data_v1.textOverride = '[' + bigRowText + ']';
    const Morrow2 = loadExportModule(makeTransport(db));
    const result = await Morrow2.export._internals.runExport();
    check('T-E2b 端到端导出成功（含裸 BIGINT 行）', result.ok === true, result.error && result.error.text);
    if (result.ok) {
      check('T-E2b 容器中 version 为字符串 "9007199254740993"', result.fileText.indexOf('"version":"9007199254740993"') >= 0);
      const roundTrip = JSON.parse(result.fileText);
      check('T-E2b round-trip 后仍为字符串', roundTrip.data.life_data[0].version === '9007199254740993');
    }
  }

  // T-E1b：分页组装（1001 行 life_data → 500/500/1；10000 行 activity_log → 21 次请求）
  {
    const db = makeDb(makeLifeRows(1001), CLIENT_ROWS, makeActivityRows(10000));
    const transport = makeTransport(db);
    const Morrow = loadExportModule(transport);
    const result = await Morrow.export._internals.runExport();
    check('T-E1b 导出成功', result.ok === true, result.error && result.error.text);
    if (result.ok) {
      const lifeReqs = transport.requests.filter(function (q) { return q.indexOf('export_life_data_v1') === 0; });
      check('T-E1b life_data 恰 3 次请求（500/500/1）', lifeReqs.length === 3, 'got ' + lifeReqs.length);
      check('T-E1b 第 1 页无游标', lifeReqs[0].indexOf('id=gt.') < 0);
      check('T-E1b 第 2 页游标 id-000499', lifeReqs[1].indexOf('id=gt.id-000499') >= 0);
      check('T-E1b 第 3 页游标 id-000999', lifeReqs[2].indexOf('id=gt.id-000999') >= 0);
      const actReqs = transport.requests.filter(function (q) { return q.indexOf('export_activity_log_v1') === 0; });
      check('T-E1b activity_log 21 次请求（20 满页 + 1 空页）', actReqs.length === 21, 'got ' + actReqs.length);
      const c = JSON.parse(result.fileText);
      check('T-E1b counts.life_data=1001', c.counts.life_data === 1001);
      check('T-E1b counts.activity_log=10000', c.counts.activity_log === 10000);
      check('T-E1b counts.agent_clients=1', c.counts.agent_clients === 1);
      check('T-E1b counts.workspace_settings=1', c.counts.workspace_settings === 1);
      check('T-E1b 封闭集合空数组', c.counts.agent_advice === 0 && c.counts.automation_rules === 0 &&
        Array.isArray(c.data.agent_advice) && c.data.agent_advice.length === 0);
      check('T-E1b 无重复无丢失（行 id 唯一性抽验）',
        c.data.life_data[0].id === 'id-000000' && c.data.life_data[1000].id === 'id-001000' &&
        c.data.life_data.length === 1001);
    }
  }

  // T-E3b：一致性快照竞态（钉子 2）
  {
    // 场景 1：中途 bump 一次 → 第一次尝试冲突 → 第二次成功
    const db = makeDb(makeLifeRows(10), CLIENT_ROWS, []);
    let stateReads = 0;
    const transport = makeTransport(db, {
      after: function (pq) {
        if (pq.indexOf('export_workspace_state_v1') === 0) {
          stateReads += 1;
          if (stateReads === 1) db.revision += 1; // R0 读取完成后数据变化
        }
      },
    });
    const Morrow = loadExportModule(transport);
    const result = await Morrow.export._internals.runExport();
    check('T-E3b 场景1 冲突后重试成功', result.ok === true, result.error && result.error.text);
    const stateReqs = transport.requests.filter(function (q) { return q.indexOf('export_workspace_state_v1') === 0; });
    check('T-E3b 场景1 state 读取 4 次（2 次尝试 × R0/R1）', stateReqs.length === 4, 'got ' + stateReqs.length);
    if (result.ok) {
      const c = JSON.parse(result.fileText);
      check('T-E3b 场景1 成功包 revision=43（新值）', c.workspace.data_revision === '43');
    }

    // 场景 2：持续冲突 → 3 次尝试耗尽 → EXPORT_CONFLICT，绝不产出混合快照
    const db2 = makeDb(makeLifeRows(10), CLIENT_ROWS, []);
    const transport2 = makeTransport(db2, {
      after: function (pq) {
        if (pq.indexOf('export_workspace_state_v1') === 0) db2.revision += 1; // 每次 R0 后都变
      },
    });
    const Morrow2 = loadExportModule(transport2);
    const result2 = await Morrow2.export._internals.runExport();
    check('T-E3b 场景2 耗尽后失败', result2.ok === false);
    check('T-E3b 场景2 错误类型 export_conflict', result2.error && result2.error.kind === 'export_conflict');
    const stateReqs2 = transport2.requests.filter(function (q) { return q.indexOf('export_workspace_state_v1') === 0; });
    check('T-E3b 场景2 state 读取 6 次（3 次尝试）', stateReqs2.length === 6, 'got ' + stateReqs2.length);
  }

  // T-E5：无凭据防线（钉子 3）
  {
    // 场景 A：敏感键名
    const rowsA = makeLifeRows(1);
    rowsA[0].payload = { payload_v: 1, api_key: 'should-not-be-here' };
    const MorrowA = loadExportModule(makeTransport(makeDb(rowsA, [], [])));
    const resA = await MorrowA.export._internals.runExport();
    check('T-E5 敏感键名拒绝', resA.ok === false && resA.error.kind === 'export_security', resA.error && resA.error.text);

    // 场景 B：JWT 形态值
    const rowsB = makeLifeRows(1);
    rowsB[0].payload = { payload_v: 1, note: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c' };
    const MorrowB = loadExportModule(makeTransport(makeDb(rowsB, [], [])));
    const resB = await MorrowB.export._internals.runExport();
    check('T-E5 JWT 形态值拒绝', resB.ok === false && resB.error.kind === 'export_security', resB.error && resB.error.text);

    // 场景 C：sb_secret 形态值
    const rowsC = makeLifeRows(1);
    rowsC[0].payload = { payload_v: 1, note: 'sb_secret_0123456789abcdef' };
    const MorrowC = loadExportModule(makeTransport(makeDb(rowsC, [], [])));
    const resC = await MorrowC.export._internals.runExport();
    check('T-E5 sb_secret 形态值拒绝', resC.ok === false && resC.error.kind === 'export_security', resC.error && resC.error.text);

    // 场景 D：正常数据不误伤（metadata/agent_clients 白名单列不触发）
    const MorrowD = loadExportModule(makeTransport(makeDb(makeLifeRows(5), CLIENT_ROWS, makeActivityRows(5))));
    const resD = await MorrowD.export._internals.runExport();
    check('T-E5 正常数据不误伤', resD.ok === true, resD.error && resD.error.text);
  }

  // T-E4：25MiB 上限
  {
    const rows = makeLifeRows(4000);
    for (let i = 0; i < rows.length; i += 1) rows[i].payload.note = 'x'.repeat(7000); // ≈28MB
    const Morrow = loadExportModule(makeTransport(makeDb(rows, [], [])));
    const result = await Morrow.export._internals.runExport();
    check('T-E4 超 25MiB 拒绝', result.ok === false && result.error.kind === 'export_too_large', result.error && result.error.text);
    check('T-E4 错误文案含当前大小', result.error && result.error.text.indexOf('MiB') >= 0);
  }

  // T-E7a：round-trip 独立复核 + 容器形状（C-08 对齐）
  {
    const db = makeDb(makeLifeRows(37), CLIENT_ROWS, makeActivityRows(59));
    const Morrow = loadExportModule(makeTransport(db));
    const result = await Morrow.export._internals.runExport();
    check('T-E7a 导出成功', result.ok === true, result.error && result.error.text);
    if (result.ok) {
      const c = JSON.parse(result.fileText);
      check('T-E7a schema_version=1', c.schema_version === 1);
      check('T-E7a exported_at ISO 格式', /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(c.exported_at));
      check('T-E7a app_version=发行标识', c.app_version === 'mvp005-pipeline-test');
      check('T-E7a workspace 三字段', c.workspace.owner_id === OWNER && c.workspace.timezone === 'Asia/Shanghai' && c.workspace.data_revision === '42');
      check('T-E7a data 六集合', ['life_data', 'agent_advice', 'activity_log', 'automation_rules', 'agent_clients', 'workspace_settings'].every(function (k) { return k in c.data; }));
      check('T-E7a integrity 三字段', c.integrity.algorithm === 'SHA-256' && c.integrity.canonicalization === 'RFC8785' && /^[0-9a-f]{64}$/.test(c.integrity.data_sha256));
      check('T-E7a 文件名格式', /^life-workspace_\d{4}-\d{2}-\d{2}_schema-v1\.json$/.test(result.filename), result.filename);
      // 独立复核（不只信 runExport 内部 round-trip）：
      const sha2 = await Morrow.export._internals.sha256Hex(Morrow.export._internals.canonicalize(JSON.parse(result.fileText).data));
      check('T-E7a 独立 round-trip 哈希一致', sha2 === c.integrity.data_sha256);
      check('T-E7a 返回值 data_sha256 一致', result.data_sha256 === c.integrity.data_sha256);
      check('T-E7a bytes 与实际一致', result.bytes === Buffer.byteLength(result.fileText, 'utf8'));
    }
  }

  console.log('');
  console.log('==== mvp005-export-pipeline: ' + passes + ' passed, ' + failures + ' failed ====');
  process.exit(failures > 0 ? 1 : 0);
}

main().catch(function (err) {
  console.error('PIPELINE_HARNESS_ERROR', err);
  process.exit(1);
});
