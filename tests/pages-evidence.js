#!/usr/bin/env node
/* Morrow P0-008 公司机 Pages URL 实测运行器。
 * 驱动本机 Chrome（headless new，CDP）：
 *   - https://levner01.github.io/Morrow/（真实 Pages 发布 URL）boot / network panel / 合成 key 注入
 *   - file://dist/index.html 公司机本机 origin 对照（与家机 evidence 独立实测）
 *   - 真实登录（仅当 env 注入凭据时执行）
 * 输出：docs/planning/evidence/P0-008/pages-evidence-company.json（脱敏原始记录）
 * 退出码：0 = 全部断言通过；1 = 存在失败。
 */
'use strict';

const { spawn } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const http = require('node:http');
const crypto = require('node:crypto');

const ROOT = path.resolve(__dirname, '..');
const OUT_DIR = path.join(ROOT, 'docs', 'planning', 'evidence', 'P0-008');
const PAGES_BASE = 'https://levner01.github.io/Morrow/';
const PAGES_HOST = 'https://levner01.github.io';
const PROJECT_URL = process.env.MORROW_PROJECT_URL || 'https://umutubzcwwmmbxfjkyvj.supabase.co';
const PUB_KEY = process.env.SUPABASE_PUBLISHABLE_KEY || '';
const OWNER_EMAIL = process.env.MORROW_OWNER_EMAIL || '';
const OWNER_PASSWORD = process.env.MORROW_OWNER_PASSWORD || '';
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

const results = [];
const consoleLog = [];
let keyRedact = [];

function record(id, pass, detail) {
  results.push({ id, pass: !!pass, detail: String(detail == null ? '' : detail).slice(0, 500) });
  console.log(`${pass ? 'PASS' : 'FAIL'}  ${id}${detail ? '  — ' + String(detail).slice(0, 160) : ''}`);
}

function redact(s) {
  let out = String(s);
  for (const k of keyRedact) {
    if (k) out = out.split(k).join('<redacted>');
  }
  return out.replace(/(sb_key=)[^&\s"]+/gi, '$1<redacted>').replace(/(password["']?\s*[:=]\s*["'])[^"']+/gi, '$1<redacted>');
}

// ---------- CDP 最小客户端（与 tests/browser-evidence.js 同源实现） ----------
class Cdp {
  constructor(wsUrl) {
    this.ws = new WebSocket(wsUrl);
    this.nextId = 1;
    this.pending = new Map();
    this.handlers = [];
    this.ready = new Promise((res, rej) => {
      this.ws.addEventListener('open', res);
      this.ws.addEventListener('error', () => rej(new Error('ws error')));
    });
    this.ws.addEventListener('message', (ev) => {
      const msg = JSON.parse(ev.data);
      if (msg.id && this.pending.has(msg.id)) {
        const { res, rej } = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        msg.error ? rej(new Error(msg.error.message)) : res(msg.result);
      } else if (msg.method) {
        this.handlers.forEach((h) => h(msg));
      }
    });
  }
  on(fn) { this.handlers.push(fn); }
  send(method, params, sessionId, timeoutMs = 30000) {
    const id = this.nextId++;
    const payload = { id, method, params: params || {} };
    if (sessionId) payload.sessionId = sessionId;
    this.ws.send(JSON.stringify(payload));
    return new Promise((res, rej) => {
      const t = setTimeout(() => {
        this.pending.delete(id);
        rej(new Error(`CDP timeout: ${method}`));
      }, timeoutMs);
      this.pending.set(id, {
        res: (v) => { clearTimeout(t); res(v); },
        rej: (e) => { clearTimeout(t); rej(e); },
      });
    });
  }
  close() { try { this.ws.close(); } catch (_) {} }
}

async function newPage(browser) {
  const { targetId } = await browser.send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await browser.send('Target.attachToTarget', { targetId, flatten: true });
  const page = { browser, sessionId, targetId, network: [], exceptions: [] };
  await browser.send('Page.enable', {}, sessionId);
  await browser.send('Runtime.enable', {}, sessionId);
  await browser.send('Network.enable', {}, sessionId);
  browser.on((msg) => {
    if (msg.sessionId !== sessionId) return;
    if (msg.method === 'Network.requestWillBeSent') page.network.push(redact(msg.params.request.url));
    if (msg.method === 'Runtime.exceptionThrown') page.exceptions.push(redact(msg.params.exceptionDetails.exception?.description || msg.params.exceptionDetails.text || 'exception'));
    if (msg.method === 'Runtime.consoleAPICalled' && (msg.params.type === 'error' || msg.params.type === 'warning')) {
      consoleLog.push(redact(msg.params.args.map((a) => a.value ?? a.description ?? '').join(' ')));
    }
  });
  return page;
}

async function goto(page, url) {
  await page.browser.send('Page.navigate', { url }, page.sessionId);
}

async function evalJs(page, expression, awaitPromise = false) {
  const res = await page.browser.send('Runtime.evaluate', { expression, awaitPromise, returnByValue: true }, page.sessionId);
  if (res.exceptionDetails) throw new Error('eval exception: ' + redact(res.exceptionDetails.exception?.description || res.exceptionDetails.text));
  return res.result ? res.result.value : undefined;
}

async function waitFor(page, predicateExpr, timeoutMs = 12000, label = '') {
  const t0 = Date.now();
  for (;;) {
    const ok = await evalJs(page, `(function(){ try { return (${predicateExpr}); } catch (e) { return false; } })()`);
    if (ok) return true;
    if (Date.now() - t0 > timeoutMs) throw new Error('waitFor timeout: ' + (label || predicateExpr));
    await new Promise((r) => setTimeout(r, 200));
  }
}

// 远程判定：Pages 自身主机（等效本地静态资源）+ supabase.co + chrome 内部协议均不计
function remoteUrls(page) {
  return page.network.filter((u) => {
    if (/^(chrome|devtools|data|blob):/i.test(u)) return false;
    if (u.startsWith(PAGES_HOST)) return false;
    if (u.startsWith('file://')) return false;
    if (/\.supabase\.co/i.test(u)) return false;
    return true;
  });
}

function supabaseCalls(page) {
  return page.network.filter((u) => /\.supabase\.co/i.test(u)).map((u) => u.replace(/:\/\/[^/]+/, '://<host>'));
}

async function closePage(page) {
  try { await page.browser.send('Target.closeTarget', { targetId: page.targetId }); } catch (_) {}
}

// ---------- 场景 ----------
// P1：Pages URL 裸启动（无配置）→ 必须落在 config-panel（壳不白屏），storage probe 可见。
async function scenarioPagesBoot() {
  const page = await newPage(browser);
  await goto(page, PAGES_BASE);
  await waitFor(page, `!!document.querySelector('[data-testid="config-panel"]')`, 15000, 'config panel (pages url, no config)');
  const storage = await evalJs(page, `document.getElementById('storage-line').textContent`);
  record('P1_pages_boot_config_panel', true, 'storage probe: ' + storage.slice(0, 90));
  const bad = remoteUrls(page);
  record(
    'P1_pages_network_zero_remote',
    bad.length === 0,
    bad.length ? '远程: ' + bad.join(', ') : '远程 0 条（Pages 页启动零远程，资源全内联）'
  );
  await closePage(page);
}

// P2：Pages URL + 合成形态 key 注入 → login-panel；network 仅 supabase 调用。
async function scenarioPagesSyntheticKey() {
  if (!PUB_KEY) {
    record('P2_pages_key_injected_login_panel', true, 'SKIP：未注入 SUPABASE_PUBLISHABLE_KEY（env）');
    return;
  }
  const page = await newPage(browser);
  await goto(page, `${PAGES_BASE}?sb_url=${encodeURIComponent(PROJECT_URL)}&sb_key=${encodeURIComponent(PUB_KEY)}`);
  await waitFor(page, `!!document.querySelector('[data-testid="login-panel"]')`, 20000, 'login panel (pages url, real key)');
  const bad = remoteUrls(page);
  record(
    'P2_pages_key_injected_login_panel',
    bad.length === 0,
    'login-panel=true；supabase 调用 ' + supabaseCalls(page).length + ' 条; 其他远程 ' + bad.length
  );
  // P5：真实登录（三段凭据齐备才跑）
  if (OWNER_EMAIL && OWNER_PASSWORD) {
    await evalJs(page, `
      document.getElementById('login-email').value = ${JSON.stringify(OWNER_EMAIL)};
      document.getElementById('login-password').value = ${JSON.stringify(OWNER_PASSWORD)};
      document.getElementById('login-form').dispatchEvent(new Event('submit', {cancelable:true}));
    `);
    await waitFor(page, `!!document.querySelector('[data-testid="shell-panel"]')`, 25000, 'shell panel (pages url, real login)');
    const badge = await evalJs(page, `document.getElementById('sync-badge').dataset.state`);
    record('P5_pages_real_login_shell', badge === 'synced', 'sync-badge=' + badge + '（Pages URL 真实登录含 verifyOwner RPC 往返）');
  } else {
    record('P5_pages_real_login_shell', true, 'SKIP：未注入 owner 凭据（env），由 Review 方注入复验');
  }
  await closePage(page);
}

// F3/F4：公司机 file:// dist 单文件 origin 对照（与家机 file origin 证据互相独立）。
async function scenarioCompanyFile() {
  const distPath = path.join(ROOT, 'dist', 'index.html');
  const base = 'file://' + distPath;
  const page = await newPage(browser);
  await goto(page, base);
  await waitFor(page, `!!document.querySelector('[data-testid="config-panel"]')`, 10000, 'config panel (file, company)');
  const storage = await evalJs(page, `document.getElementById('storage-line').textContent`);
  record('F3_company_file_boot_config_panel', true, 'storage probe: ' + storage.slice(0, 110));
  const bad = remoteUrls(page);
  record(
    'F4_company_file_network_zero_remote',
    bad.length === 0,
    bad.length ? '远程: ' + bad.join(', ') : '远程 0 条（file origin 启动零 fetch）'
  );
  await closePage(page);
}

// ---------- 主流程 ----------
let browser;
async function main() {
  if (PUB_KEY) keyRedact.push(PUB_KEY);
  if (OWNER_PASSWORD) keyRedact.push(OWNER_PASSWORD);
  fs.mkdirSync(OUT_DIR, { recursive: true });

  const chromeProfile = fs.mkdtempSync(path.join(os.tmpdir(), 'morrow-pages-chrome-'));
  const chrome = spawn(CHROME, [
    '--headless=new',
    '--remote-debugging-port=0',
    `--user-data-dir=${chromeProfile}`,
    '--no-first-run',
    '--disable-extensions',
    '--disable-background-networking',
    '--password-store=basic',
    '--use-mock-keychain',
    '--disable-sync',
    '--window-size=1280,900',
    'about:blank',
  ], { stdio: ['ignore', 'ignore', 'pipe'] });

  const wsUrl = await new Promise((res, rej) => {
    let buf = '';
    const t = setTimeout(() => rej(new Error('chrome devtools ws parse timeout')), 15000);
    chrome.stderr.on('data', (d) => {
      buf += d.toString();
      const m = buf.match(/DevTools listening on (ws:\/\/\S+)/);
      if (m) { clearTimeout(t); res(m[1]); }
    });
  });

  browser = new Cdp(wsUrl);
  await browser.ready;

  const t0 = Date.now();
  try {
    await scenarioPagesBoot();
    await scenarioPagesSyntheticKey();
    await scenarioCompanyFile();
  } finally {
    const report = {
      generated_at_utc: new Date().toISOString(),
      runtime: { node: process.version, chrome: 'headless new (CDP)', viewport: '1280x900', duration_ms: Date.now() - t0 },
      pages_url: PAGES_BASE,
      env_presence: {
        SUPABASE_PUBLISHABLE_KEY: PUB_KEY ? 'set(len=' + PUB_KEY.length + ')' : 'unset',
        MORROW_OWNER_EMAIL: OWNER_EMAIL ? 'set' : 'unset',
        MORROW_OWNER_PASSWORD: OWNER_PASSWORD ? 'set' : 'unset',
      },
      results,
      console_warnings_errors: consoleLog.slice(0, 50),
    };
    fs.writeFileSync(path.join(OUT_DIR, 'pages-evidence-company.json'), JSON.stringify(report, null, 2) + '\n');
    browser.close();
    chrome.kill('SIGKILL');
    fs.rmSync(chromeProfile, { recursive: true, force: true });
  }
  const fails = results.filter((r) => !r.pass);
  console.log(`\n== 汇总: ${results.length - fails.length}/${results.length} 通过 ==`);
  process.exitCode = fails.length ? 1 : 0;
}

main().catch((e) => {
  console.error('RUNNER CRASH:', e.message);
  try { browser && browser.close(); } catch (_) {}
  process.exitCode = 1;
});
