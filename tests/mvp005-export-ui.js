#!/usr/bin/env node
/* Morrow MVP-005 导出 UI E2E（真实浏览器 CDP + 真实 JWT 只读）。
 *
 * 验收对应（任务卡 5 条 + 施工提示词测试矩阵）：
 * 1. 入口在今日页「更改今日日型」之下的次级位置
 * 2. 点击导出 → 真实下载捕获（CDP Browser.setDownloadBehavior）
 *    → 落盘文件：容器形状（C-08）/ secret scan（键名+值形态+凭据值不泄漏）/
 *      round-trip（Node 独立复刻 RFC8785 canonicalize + SHA-256 对账 integrity.data_sha256）
 * 3. _setPageSize(2) 多页路径与默认单页全量对账（counts + data_sha256 全等）
 * 4. 竞态注入（in-page 包装 restText 篡改第一次 R1）→ 整包丢弃重试 →
 *    成功包 data_revision 为真实值（绝不产出混合快照）+ state 读取 ≥4 次
 * 5. 断网（Network.emulateNetworkConditions）→ 状态行 error 文案 + 无下载产出
 * 6. 1280 / 375 / 320 三视口无横向滚动（截图入 evidence）
 *
 * 真实数据红线：只读（导出本身零写入；不触任何写 RPC）；
 * 登录凭据走环境变量注入，输出全部脱敏。
 */
'use strict';

const { spawn } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const ROOT = path.resolve(__dirname, '..');
const OUT_DIR = path.join(ROOT, 'docs', 'planning', 'evidence', 'MVP-005');
const DL_DIR = '/tmp/mvp005-dl';
const HTTP_PORT = 8095;
const HTTP_BASE = `http://127.0.0.1:${HTTP_PORT}`;
const PAGE_URL = `${HTTP_BASE}/dist/index.html`;
const PUB_KEY = process.env.SUPABASE_PUBLISHABLE_KEY || '';
const OWNER_EMAIL = process.env.MORROW_OWNER_EMAIL || '';
const OWNER_PASSWORD = process.env.MORROW_OWNER_PASSWORD || '';
const SUPABASE_URL = process.env.SUPABASE_URL || '';
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

const results = [];
const keyRedact = [PUB_KEY, OWNER_PASSWORD, OWNER_EMAIL];

function record(id, pass, detail) {
  results.push({ id, pass: !!pass, detail: String(detail == null ? '' : detail).slice(0, 400) });
  console.log(`${pass ? 'PASS' : 'FAIL'}  ${id}${detail ? '  — ' + String(detail).slice(0, 160) : ''}`);
}

function redact(s) {
  let out = String(s);
  for (const k of keyRedact) if (k) out = out.split(k).join('<redacted>');
  return out.replace(/(password["']?\s*[:=]\s*["'])[^"']+/gi, '$1<redacted>');
}

class Cdp {
  constructor(wsUrl) {
    this.ws = new WebSocket(wsUrl);
    this.nextId = 1;
    this.pending = new Map();
    this.ready = new Promise((res, rej) => {
      this.ws.addEventListener('open', res);
      this.ws.addEventListener('error', () => rej(new Error('ws error')));
    });
    this.ws.addEventListener('message', (ev) => {
      const msg = JSON.parse(ev.data);
      if (msg.id && this.pending.has(msg.id)) {
        const { res, rej } = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        if (msg.error) rej(new Error(msg.error.message));
        else res(msg.result);
      }
    });
  }
  send(method, params) {
    const id = this.nextId++;
    return new Promise((res, rej) => {
      this.pending.set(id, { res, rej });
      this.ws.send(JSON.stringify({ id, method, params: params || {} }));
    });
  }
  close() { this.ws.close(); }
}

async function launchChrome(url) {
  const port = 9222 + Math.floor(Math.random() * 1000);
  const chrome = spawn(CHROME, [
    '--remote-debugging-port=' + port,
    '--headless=new',
    '--disable-gpu',
    '--no-sandbox',
    '--disable-dev-shm-usage',
    '--window-size=1280,900',
    '--no-proxy-server',
    url,
  ]);
  await new Promise((res) => setTimeout(res, 2000));
  const http = require('node:http');
  const wsUrl = await new Promise((res, rej) => {
    http.get(`http://127.0.0.1:${port}/json`, (resp) => {
      let data = '';
      resp.on('data', (chunk) => (data += chunk));
      resp.on('end', () => {
        try {
          const page = JSON.parse(data).find((t) => t.type === 'page');
          res(page.webSocketDebuggerUrl);
        } catch (e) { rej(e); }
      });
    }).on('error', rej);
  });
  const cdp = new Cdp(wsUrl);
  await cdp.ready;
  return { chrome, cdp };
}

async function evalJs(cdp, expression) {
  const r = await cdp.send('Runtime.evaluate', {
    expression,
    awaitPromise: true,
    returnByValue: true,
  });
  if (r.exceptionDetails) {
    throw new Error('页面内执行异常: ' + redact(JSON.stringify(r.exceptionDetails).slice(0, 300)));
  }
  return r.result.value;
}

async function waitFor(cdp, expression, timeoutMs, label) {
  const start = Date.now();
  for (;;) {
    const v = await evalJs(cdp, expression).catch(() => false);
    if (v) return v;
    if (Date.now() - start > timeoutMs) throw new Error('等待超时: ' + label);
    await new Promise((res) => setTimeout(res, 300));
  }
}

async function setupAndLogin(cdp) {
  await evalJs(cdp, `window.Morrow.config.save({ url: '${SUPABASE_URL}', key: '${PUB_KEY}' }); 'ok'`);
  await evalJs(cdp, `window.Morrow.transport.init({ url: '${SUPABASE_URL}', key: '${PUB_KEY}' }); 'ok'`);
  const login = await evalJs(cdp, `
    (async function() {
      const res = await window.Morrow.transport.login('${OWNER_EMAIL}', '${OWNER_PASSWORD}');
      if (res.ok) {
        window.Morrow.app.setCurrentUser(res.user);
        window.Morrow.ui.showShellPanel(res.user);
        return { ok: true };
      }
      return { ok: false, error: res.error };
    })()
  `);
  if (!login || login.ok !== true) {
    throw new Error('登录失败: ' + redact(JSON.stringify(login && login.error ? login.error : login).slice(0, 200)));
  }
}

async function screenshot(cdp, file) {
  const shot = await cdp.send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true });
  fs.writeFileSync(file, Buffer.from(shot.data, 'base64'));
}

// —— Node 侧独立校验（不复用页面代码，双保险） ——
function canonicalize(v) {
  if (v === null) return 'null';
  if (typeof v === 'boolean') return v ? 'true' : 'false';
  if (typeof v === 'number') {
    if (!Number.isFinite(v)) throw new Error('JCS_NON_FINITE');
    if (v === 0) return '0';
    return String(v);
  }
  if (typeof v === 'string') return JSON.stringify(v);
  if (Array.isArray(v)) return '[' + v.map(canonicalize).join(',') + ']';
  const keys = Object.keys(v).sort();
  return '{' + keys.map((k) => JSON.stringify(k) + ':' + canonicalize(v[k])).join(',') + '}';
}

const SENSITIVE_KEY_RE = /(token|credential|secret|password|session|receipt|api[_-]?key)/i;
const JWT_LIKE_RE = /^eyJ[A-Za-z0-9_-]{20,}\./;
const SUPABASE_KEY_RE = /^(sb_(secret|publishable)_|sk-)/;

function secretScan(v, p, hits) {
  if (v === null) return;
  if (typeof v === 'string') {
    if (JWT_LIKE_RE.test(v) || SUPABASE_KEY_RE.test(v)) hits.push(p + '(值形态)');
    return;
  }
  if (typeof v === 'number' || typeof v === 'boolean') return;
  if (Array.isArray(v)) {
    v.forEach((x, i) => secretScan(x, p + '[' + i + ']', hits));
    return;
  }
  for (const k of Object.keys(v)) {
    if (SENSITIVE_KEY_RE.test(k)) hits.push(p + '.' + k + '(键名)');
    secretScan(v[k], p + '.' + k, hits);
  }
}

function readDownloadedFile() {
  const files = fs.readdirSync(DL_DIR).filter((f) => f.endsWith('.json'));
  if (files.length !== 1) return null;
  const full = path.join(DL_DIR, files[0]);
  return { name: files[0], text: fs.readFileSync(full, 'utf8'), bytes: fs.statSync(full).size };
}

async function clickExportAndWait(cdp, timeoutMs) {
  fs.rmSync(DL_DIR, { recursive: true, force: true });
  fs.mkdirSync(DL_DIR, { recursive: true });
  await evalJs(cdp, `document.getElementById('export-run-btn').click(); 'clicked'`);
  const start = Date.now();
  for (;;) {
    const status = await evalJs(cdp, `
      (function() {
        const el = document.querySelector('[data-testid="export-status"]');
        return el && !el.hidden ? { text: el.textContent, kind: el.dataset.kind } : null;
      })()
    `);
    const file = readDownloadedFile();
    if (file) return { file, status };
    if (status && status.kind === 'error') return { file: null, status };
    if (Date.now() - start > (timeoutMs || 60000)) throw new Error('导出超时：' + redact(JSON.stringify(status)));
    await new Promise((res) => setTimeout(res, 400));
  }
}

function verifyExportFile(file, label) {
  const checks = {};
  const parsed = JSON.parse(file.text);
  checks.name = file.name;
  checks.schema_version = parsed.schema_version;
  checks.containerKeys = Object.keys(parsed).join(',');
  checks.dataKeys = Object.keys(parsed.data).sort().join(',');
  checks.revision = parsed.workspace.data_revision;
  checks.revisionIsDigits = /^[0-9]+$/.test(parsed.workspace.data_revision);
  checks.countsMatch = Object.keys(parsed.counts).every((k) => parsed.counts[k] === parsed.data[k].length);
  checks.versionAllString = parsed.data.life_data.every((r) => typeof r.version === 'string');
  // secret scan：键名/值形态 + 凭据值不泄漏
  const hits = [];
  secretScan(parsed, '$', hits);
  checks.secretHits = hits;
  checks.leakPubKey = file.text.indexOf(PUB_KEY) >= 0;
  checks.leakPassword = OWNER_PASSWORD ? file.text.indexOf(OWNER_PASSWORD) >= 0 : false;
  checks.leakEmail = OWNER_EMAIL ? file.text.indexOf(OWNER_EMAIL) >= 0 : false;
  // round-trip：Node 独立 canonicalize + SHA-256 对账
  const sha = crypto.createHash('sha256').update(canonicalize(parsed.data), 'utf8').digest('hex');
  checks.roundTrip = sha === parsed.integrity.data_sha256;
  checks.integrityShape = parsed.integrity.algorithm === 'SHA-256' && parsed.integrity.canonicalization === 'RFC8785';
  checks.dataSha = parsed.integrity.data_sha256;
  record(label + '-filename', /^life-workspace_\d{4}-\d{2}-\d{2}_schema-v1\.json$/.test(file.name), file.name);
  record(label + '-container-shape',
    checks.schema_version === 1 &&
    checks.containerKeys === 'schema_version,exported_at,app_version,workspace,data,counts,integrity' &&
    checks.dataKeys === 'activity_log,agent_advice,agent_clients,automation_rules,life_data,workspace_settings',
    'keys=' + checks.containerKeys);
  record(label + '-revision-digit-string', checks.revisionIsDigits === true, 'revision=' + checks.revision);
  record(label + '-counts-match-data', checks.countsMatch === true, JSON.stringify(parsed.counts));
  record(label + '-version-text-typed', checks.versionAllString === true, 'life_data 行全部 version:string');
  record(label + '-secret-scan-clean', checks.secretHits.length === 0, JSON.stringify(checks.secretHits.slice(0, 3)));
  record(label + '-no-cred-leak', !checks.leakPubKey && !checks.leakPassword && !checks.leakEmail,
    'pubkey/password/email 均不在文件中');
  record(label + '-roundtrip-sha', checks.roundTrip === true, checks.dataSha);
  record(label + '-integrity-shape', checks.integrityShape === true, JSON.stringify(parsed.integrity));
  return { parsed, checks };
}

async function main() {
  if (!PUB_KEY || !OWNER_EMAIL || !OWNER_PASSWORD || !SUPABASE_URL) {
    console.error('缺少凭据：SUPABASE_URL / SUPABASE_PUBLISHABLE_KEY / MORROW_OWNER_EMAIL / MORROW_OWNER_PASSWORD');
    process.exit(2);
  }
  fs.mkdirSync(OUT_DIR, { recursive: true });

  const server = spawn('python3', ['-m', 'http.server', String(HTTP_PORT), '--bind', '127.0.0.1'], {
    cwd: ROOT, stdio: 'ignore',
  });
  await new Promise((res) => setTimeout(res, 800));

  let chrome, cdp;
  try {
    const launched = await launchChrome(PAGE_URL);
    chrome = launched.chrome;
    cdp = launched.cdp;
    // 下载捕获：page target 上用 Page.setDownloadBehavior（Browser.* 需 browser-level WS，
    // 在 page session 上发不生效——首次实测教训）；Browser 域尝试失败则忽略。
    try {
      await cdp.send('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: DL_DIR });
    } catch (_) { /* browser-level domain 在 page session 不可用，走 Page 域 */ }
    await cdp.send('Page.setDownloadBehavior', { behavior: 'allow', downloadPath: DL_DIR });

    await setupAndLogin(cdp);
    await waitFor(cdp, `!!document.querySelector('[data-testid="anchor-list"]')`, 15000, '今日页渲染');
    await waitFor(cdp, `!!document.querySelector('[data-testid="export-actions"]')`, 5000, '导出入口渲染');

    // ---- T1：入口位置（「更改今日日型」之下的次级位置）----
    const pos = await evalJs(cdp, `
      (function() {
        const dt = document.querySelector('.daytype-actions');
        const ex = document.querySelector('[data-testid="export-actions"]');
        const hm = document.querySelector('#heatmap-host');
        return {
          belowDaytype: !!(dt && ex) && (dt.getBoundingClientRect().top + window.scrollY) < (ex.getBoundingClientRect().top + window.scrollY),
          aboveHeatmap: !!(hm && ex) && (ex.getBoundingClientRect().top + window.scrollY) < (hm.getBoundingClientRect().top + window.scrollY),
        };
      })()
    `);
    record('entry-position', pos.belowDaytype === true && pos.aboveHeatmap === true, JSON.stringify(pos));

    // ---- T2：真实导出（默认 500 页宽，真实 JWT 只读）----
    console.log('\n[T2] 真实导出：下载捕获 + secret scan + round-trip');
    const t2 = await clickExportAndWait(cdp);
    if (!t2.file) throw new Error('T2 未捕获下载: ' + redact(JSON.stringify(t2.status)));
    const t2v = verifyExportFile(t2.file, 't2');
    record('t2-status-ok', t2.status && t2.status.kind === 'ok' && t2.status.text.indexOf('已导出') === 0, t2.status && t2.status.text);
    record('t2-closed-empty', t2v.parsed.counts.agent_advice === 0 && t2v.parsed.counts.automation_rules === 0,
      'agent_advice/automation_rules 固定空数组');
    const counts2 = JSON.stringify(t2v.parsed.counts);
    const sha2 = t2v.parsed.integrity.data_sha256;
    const rev2 = t2v.parsed.workspace.data_revision;
    await screenshot(cdp, path.join(OUT_DIR, 'export-1280.png'));

    // ---- T3：多页路径（_setPageSize(2) 强制 keyset 多页，与 T2 全量对账）----
    console.log('\n[T3] 多页路径对账（pageSize=2）');
    const pageStats = await evalJs(cdp, `
      (function() {
        window.Morrow.export._setPageSize(2);
        // 记录真实请求序列以证明多页
        window.__mvp005reqs = [];
        const orig = window.Morrow.transport.restText;
        window.__mvp005origRestText = orig;
        window.Morrow.transport.restText = function (pq) {
          window.__mvp005reqs.push(String(pq));
          return orig.apply(this, arguments);
        };
        return 'armed';
      })()
    `);
    const t3 = await clickExportAndWait(cdp, 90000);
    if (!t3.file) throw new Error('T3 未捕获下载: ' + redact(JSON.stringify(t3.status)));
    const t3v = verifyExportFile(t3.file, 't3');
    const reqs = await evalJs(cdp, `window.__mvp005reqs`);
    const multiPage = reqs.filter((q) => q.indexOf('id=gt.') >= 0).length;
    record('t3-multipage-cursor-reqs', multiPage >= 5, '带 id=gt. 游标的请求数=' + multiPage);
    record('t3-counts-match-full', JSON.stringify(t3v.parsed.counts) === counts2,
      'pageSize2: ' + JSON.stringify(t3v.parsed.counts) + ' vs full: ' + counts2);
    record('t3-sha-match-full', t3v.parsed.integrity.data_sha256 === sha2, '同一数据 → 同一 data_sha256');
    await evalJs(cdp, `
      (function() {
        window.Morrow.transport.restText = window.__mvp005origRestText;
        window.Morrow.export._setPageSize(null);
        return 'restored';
      })()
    `);

    // ---- T4：竞态注入（篡改第一次 R1 → 整包丢弃 → 重试成功且 revision 为真实值）----
    console.log('\n[T4] 一致性快照竞态注入');
    await evalJs(cdp, `
      (function() {
        window.__mvp005stateCalls = 0;
        const orig = window.Morrow.transport.restText;
        window.__mvp005origRestText2 = orig;
        window.Morrow.transport.restText = async function (pq) {
          const r = await orig.apply(this, arguments);
          if (String(pq).indexOf('export_workspace_state_v1') === 0) {
            window.__mvp005stateCalls++;
            if (window.__mvp005stateCalls === 2) {
              // 第一次尝试的 R1：模拟导出期间数据变化（revision +1）
              const arr = JSON.parse(r.text);
              arr[0].data_revision = String(Number(arr[0].data_revision) + 1);
              return { ok: true, status: r.status, text: JSON.stringify(arr) };
            }
          }
          return r;
        };
        return 'armed';
      })()
    `);
    const t4 = await clickExportAndWait(cdp, 90000);
    if (!t4.file) throw new Error('T4 未捕获下载: ' + redact(JSON.stringify(t4.status)));
    const t4v = verifyExportFile(t4.file, 't4');
    const stateCalls = await evalJs(cdp, `window.__mvp005stateCalls`);
    record('t4-conflict-retried', stateCalls >= 4, 'state 读取 ' + stateCalls + ' 次（≥2 轮 R0/R1）');
    record('t4-no-mixed-snapshot', t4v.parsed.workspace.data_revision === rev2,
      '成功包 revision=' + t4v.parsed.workspace.data_revision + '（真实值，篡改值未入包）');
    record('t4-sha-stable', t4v.parsed.integrity.data_sha256 === sha2, '与 T2 同数据同哈希');
    await evalJs(cdp, `window.Morrow.transport.restText = window.__mvp005origRestText2; 'restored'`);

    // ---- T5：断网失败路径（不产出半包）----
    console.log('\n[T5] 断网失败路径');
    await cdp.send('Network.enable');
    await cdp.send('Network.emulateNetworkConditions', { offline: true, latency: 0, downloadThroughput: 0, uploadThroughput: 0 });
    fs.rmSync(DL_DIR, { recursive: true, force: true });
    fs.mkdirSync(DL_DIR, { recursive: true });
    await evalJs(cdp, `document.getElementById('export-run-btn').click(); 'clicked'`);
    const t5status = await waitFor(cdp, `
      (function() {
        const el = document.querySelector('[data-testid="export-status"]');
        if (el && !el.hidden && el.dataset.kind === 'error') return { text: el.textContent, kind: el.dataset.kind };
        return false;
      })()
    `, 60000, '断网错误状态');
    const t5files = fs.readdirSync(DL_DIR).filter((f) => f.endsWith('.json'));
    record('t5-offline-error-shown', t5status.kind === 'error' && /连接|网络|重试|失败/.test(t5status.text), redact(t5status.text));
    record('t5-no-partial-download', t5files.length === 0, '断网下零下载产出');
    await cdp.send('Network.emulateNetworkConditions', { offline: false, latency: 0, downloadThroughput: -1, uploadThroughput: -1 });

    // ---- T6：三视口无横向滚动 ----
    console.log('\n[T6] 三视口');
    const scroll = () => evalJs(cdp, `document.documentElement.scrollWidth <= window.innerWidth`);
    record('viewport-1280-no-hscroll', await scroll(), 'scrollW=' + await evalJs(cdp, `document.documentElement.scrollWidth`));
    await cdp.send('Emulation.setDeviceMetricsOverride', { width: 375, height: 800, deviceScaleFactor: 2, mobile: true });
    await new Promise((res) => setTimeout(res, 600));
    record('viewport-375-no-hscroll', await scroll(), 'scrollW=' + await evalJs(cdp, `document.documentElement.scrollWidth`));
    await screenshot(cdp, path.join(OUT_DIR, 'export-375.png'));
    await cdp.send('Emulation.setDeviceMetricsOverride', { width: 320, height: 700, deviceScaleFactor: 2, mobile: true });
    await new Promise((res) => setTimeout(res, 600));
    record('viewport-320-no-hscroll', await scroll(), 'scrollW=' + await evalJs(cdp, `document.documentElement.scrollWidth`));
    await screenshot(cdp, path.join(OUT_DIR, 'export-320.png'));
  } finally {
    if (cdp) cdp.close();
    if (chrome) chrome.kill();
    server.kill();
  }

  const pass = results.filter((r) => r.pass).length;
  const fail = results.length - pass;
  const summary = {
    task: 'MVP-005',
    ran_at_utc: new Date().toISOString(),
    page: PAGE_URL,
    total: results.length,
    pass,
    fail,
    results,
  };
  fs.writeFileSync(path.join(OUT_DIR, 'ui-e2e-results.json'), redact(JSON.stringify(summary, null, 2)) + '\n');
  console.log(`\n${pass}/${results.length} PASS，${fail} FAIL → docs/planning/evidence/MVP-005/ui-e2e-results.json`);
  process.exit(fail === 0 ? 0 : 1);
}

main().catch((e) => {
  console.error('E2E 运行异常:', redact(e && e.stack ? e.stack : e));
  process.exit(1);
});
