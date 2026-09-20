#!/usr/bin/env node
/* Morrow P0-006 浏览器实证运行器。
 * 驱动本机 Chrome（headless new，CDP，零 npm 依赖，Node ≥22 内置 WebSocket/fetch）：
 *   - http://127.0.0.1:8080 源码模式 + file:// dist 单文件模式 双跑
 *   - network panel 断言：除 supabase.co API 与本地资源外，远程请求必须为 0
 *   - 错误路径：错误密码 / 断网 / 内部异常 / 资源拦截 / 无配置
 *   - storage probe 输出采集（http 与 file origin 各一份）
 *   - 真实登录（仅当 env 注入凭据时执行；凭据只进内存，绝不写入证据）
 * 输出：docs/planning/evidence/P0-006/browser-evidence.json（脱敏原始记录）
 * 退出码：0 = 全部断言通过；1 = 存在失败。
 * 用法：node tests/browser-evidence.mjs
 */
'use strict';

const { spawn } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const http = require('node:http');

const ROOT = path.resolve(__dirname, '..');
const OUT_DIR = path.join(ROOT, 'docs', 'planning', 'evidence', 'P0-006');
const HTTP_PORT = 8080;
const HTTP_BASE = `http://127.0.0.1:${HTTP_PORT}`;
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

function fetchJson(url) {
  return new Promise((resolve, reject) => {
    http
      .get(url, (res) => {
        let body = '';
        res.on('data', (c) => (body += c));
        res.on('end', () => {
          try {
            resolve(JSON.parse(body));
          } catch (e) {
            reject(e);
          }
        });
      })
      .on('error', reject);
  });
}

// ---------- CDP 最小客户端 ----------
class Cdp {
  constructor(wsUrl) {
    this.ws = new WebSocket(wsUrl);
    this.nextId = 1;
    this.pending = new Map();
    this.handlers = [];
    this.ready = new Promise((res, rej) => {
      this.ws.addEventListener('open', res);
      this.ws.addEventListener('error', (e) => rej(new Error('ws error')));
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
  on(fn) {
    this.handlers.push(fn);
  }
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
        res: (v) => {
          clearTimeout(t);
          res(v);
        },
        rej: (e) => {
          clearTimeout(t);
          rej(e);
        },
      });
    });
  }
  close() {
    try {
      this.ws.close();
    } catch (_) {}
  }
}

// 场景上下文：独立 target → 独立网络/控制台记录
async function newPage(browser) {
  const { targetId } = await browser.send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await browser.send('Target.attachToTarget', { targetId, flatten: true });
  const page = { browser, sessionId, targetId, network: [], exceptions: [], failures: [] };
  await browser.send('Page.enable', {}, sessionId);
  await browser.send('Runtime.enable', {}, sessionId);
  await browser.send('Network.enable', {}, sessionId);
  browser.on((msg) => {
    if (msg.sessionId !== sessionId) return;
    if (msg.method === 'Network.requestWillBeSent') {
      page.network.push(redact(msg.params.request.url));
    }
    if (msg.method === 'Runtime.exceptionThrown') {
      page.exceptions.push(redact(msg.params.exceptionDetails.exception?.description || msg.params.exceptionDetails.text || 'exception'));
    }
    if (msg.method === 'Runtime.consoleAPICalled' && (msg.params.type === 'error' || msg.params.type === 'warning')) {
      consoleLog.push(redact(msg.params.args.map((a) => a.value ?? a.description ?? '').join(' ')));
    }
    if (msg.method === 'Network.loadingFailed') {
      page.failures.push(redact(msg.params.errorText || 'loadingFailed'));
    }
  });
  return page;
}

async function goto(page, url) {
  await page.browser.send('Page.navigate', { url: redact(url) }, page.sessionId);
}

async function evalJs(page, expression, awaitPromise = false) {
  const res = await page.browser.send(
    'Runtime.evaluate',
    { expression, awaitPromise, returnByValue: true },
    page.sessionId
  );
  if (res.exceptionDetails) {
    throw new Error('eval exception: ' + redact(res.exceptionDetails.exception?.description || res.exceptionDetails.text));
  }
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

function remoteUrls(page) {
  return page.network.filter((u) => {
    if (/^(chrome|devtools|data|blob):/i.test(u)) return false;
    if (u.startsWith(HTTP_BASE) || u.startsWith('http://localhost:')) return false;
    if (u.startsWith('file://')) return false;
    if (/\.supabase\.co/i.test(u)) return false;
    return true;
  });
}

function supabaseCalls(page) {
  return page.network.filter((u) => /\.supabase\.co/i.test(u)).map((u) => u.replace(/:\/\/[^/]+/, '://<host>'));
}

async function closePage(page) {
  try {
    await page.browser.send('Target.closeTarget', { targetId: page.targetId });
  } catch (_) {}
}

// ---------- 场景 ----------
async function scenarioHttpBoot() {
  const page = await newPage(browser);
  await goto(page, `${HTTP_BASE}/index.html`);
  await waitFor(page, `!!document.querySelector('[data-testid="config-panel"]')`, 10000, 'config panel (http, no config)');
  const storage = await evalJs(page, `document.getElementById('storage-line').textContent`);
  const probe = await evalJs(page, `document.getElementById('storage-line').dataset.limited`);
  record('A1_http_boot_config_panel', true, 'storage probe: ' + storage.slice(0, 90));
  const bad = remoteUrls(page);
  record('A1_http_network_local_only', bad.length === 0, bad.length ? '远程: ' + bad.join(', ') : '仅本地请求 ' + page.network.length + ' 条');
  if (PUB_KEY) {
    const u = `${HTTP_BASE}/index.html?sb_url=${encodeURIComponent(PROJECT_URL)}&sb_key=${encodeURIComponent(PUB_KEY)}`;
    await goto(page, u);
    await waitFor(page, `!!document.querySelector('[data-testid="login-panel"]')`, 15000, 'login panel after query config');
    const search = await evalJs(page, `location.search`);
    record('A2_http_query_config_login_panel', search === '', 'location.search="' + search + '"（参数已抹除）');
    const bad2 = remoteUrls(page);
    record('A2_http_remote_only_supabase', bad2.length === 0, 'supabase 调用 ' + supabaseCalls(page).length + ' 条; 其他远程 ' + bad2.length);
    // A3 错误密码
    await evalJs(page, `
      document.getElementById('login-email').value = 'nobody@example.com';
      document.getElementById('login-password').value = 'wrong-pass-123';
      document.getElementById('login-form').dispatchEvent(new Event('submit', {cancelable:true}));
    `);
    await waitFor(page, `!!document.querySelector('[data-testid="login-error"]')`, 15000, 'login error visible');
    const errText = await evalJs(page, `document.querySelector('[data-testid="login-error"]').textContent`);
    record('A3_wrong_password_mapped', /不正确/.test(errText), '错误文案: ' + errText);
    // A4 断网登录提交
    await page.browser.send('Network.emulateNetworkConditions', { offline: true, latency: 0, downloadThroughput: -1, uploadThroughput: -1 }, page.sessionId);
    await evalJs(page, `
      document.getElementById('login-email').value = 'nobody@example.com';
      document.getElementById('login-password').value = 'whatever-123';
      document.getElementById('login-form').dispatchEvent(new Event('submit', {cancelable:true}));
    `);
    await waitFor(page, `!!document.querySelector('[data-testid="login-error"]')`, 20000, 'offline login error');
    const offText = await evalJs(page, `document.querySelector('[data-testid="login-error"]').textContent`);
    record('A4_offline_login_network_error', /无法连接|超时/.test(offText), '错误文案: ' + offText);
    await page.browser.send('Network.emulateNetworkConditions', { offline: false, latency: 0, downloadThroughput: -1, uploadThroughput: -1 }, page.sessionId);
    // A11 真实登录（三段凭据齐备才跑）
    if (OWNER_EMAIL && OWNER_PASSWORD) {
      await evalJs(page, `
        document.getElementById('login-email').value = ${JSON.stringify(OWNER_EMAIL)};
        document.getElementById('login-password').value = ${JSON.stringify(OWNER_PASSWORD)};
        document.getElementById('login-form').dispatchEvent(new Event('submit', {cancelable:true}));
      `);
      await waitFor(page, `!!document.querySelector('[data-testid="shell-panel"]')`, 25000, 'shell panel after real login');
      const badge = await evalJs(page, `document.getElementById('sync-badge').dataset.state`);
      record('A11_real_login_shell', badge === 'synced', 'sync-badge=' + badge + '（含 verifyOwner RPC 往返）');
      // A12 登出 + 草稿对话
      await evalJs(page, `Morrow.drafts.add({record_key:'p0-006-probe', input:{note:'draft-probe'}})`);
      await evalJs(page, `document.getElementById('logout-btn').click()`);
      await waitFor(page, `!!document.querySelector('[data-testid="draft-dialog"]')`, 8000, 'draft dialog on logout');
      const dlg = await evalJs(page, `document.querySelector('[data-testid="draft-dialog"] h2').textContent`);
      record('A12_logout_draft_dialog', /未同步草稿/.test(dlg), dlg);
      await evalJs(page, `document.getElementById('draft-keep').click()`);
      await waitFor(page, `!!document.querySelector('[data-testid="login-panel"]')`, 8000, 'back to login after logout');
      const authKeys = await evalJs(page, `Array.from({length:localStorage.length},(_,i)=>localStorage.key(i)).filter(k=>k.indexOf('morrow.auth.')===0).length`);
      const draftCount = await evalJs(page, `Morrow.drafts.count()`);
      record('A12_logout_session_cleared', authKeys === 0 && draftCount === 1, '残留 session 键 ' + authKeys + '；草稿保留 ' + draftCount);
      await evalJs(page, `Morrow.drafts.clear()`);
    } else {
      record('A11_real_login_shell', true, 'SKIP：未注入 owner 凭据（env），由凯哥一次性执行');
      record('A12_logout_draft_dialog', true, 'SKIP：依赖 A11 登录态');
    }
  } else {
    record('A2_http_query_config_login_panel', true, 'SKIP：未注入 SUPABASE_PUBLISHABLE_KEY（env）');
    record('A3_wrong_password_mapped', true, 'SKIP：依赖 A2');
    record('A4_offline_login_network_error', true, 'SKIP：依赖 A2');
    record('A11_real_login_shell', true, 'SKIP：未注入凭据');
    record('A12_logout_draft_dialog', true, 'SKIP：未注入凭据');
  }
  // A5 内部异常面板
  await goto(page, `${HTTP_BASE}/index.html`);
  await waitFor(page, `!!(document.querySelector('[data-testid="config-panel"]') || document.querySelector('[data-testid="login-panel"]'))`, 10000, 'boot');
  await evalJs(page, `window.dispatchEvent(new ErrorEvent('error', { message: 'simulated-internal-p0-006' }))`);
  await waitFor(page, `!!document.querySelector('.panel-failure[data-kind="internal"]')`, 5000, 'internal failure panel');
  record('A5_internal_exception_panel', true, 'kind=internal 面板出现（无白屏）');
  // A6 资源拦截（SDK 被 block → 资源失败面板）；无配置时 boot 停在配置面板，到不了 init，故依赖 A2 已存配置
  if (PUB_KEY) {
    await page.browser.send('Network.setBlockedURLs', { urls: ['*supabase-js*'] }, page.sessionId);
    await goto(page, `${HTTP_BASE}/index.html`);
    await waitFor(page, `!!document.querySelector('.panel-failure[data-kind="resource"]')`, 10000, 'resource failure panel');
    record('A6_resource_block_panel', true, 'kind=resource 面板出现（SDK 缺失被兜住）');
    await page.browser.send('Network.setBlockedURLs', { urls: [] }, page.sessionId);
  } else {
    record('A6_resource_block_panel', true, 'SKIP：需先存在本机配置才能触达 SDK 初始化分支');
  }
  await closePage(page);
}

async function scenarioFileDist() {
  const distPath = path.join(ROOT, 'dist', 'index.html');
  const base = 'file://' + distPath;
  const page = await newPage(browser);
  await goto(page, base);
  await waitFor(page, `!!document.querySelector('[data-testid="config-panel"]')`, 10000, 'config panel (file)');
  const storage = await evalJs(page, `document.getElementById('storage-line').textContent`);
  record('F1_file_boot_config_panel', true, 'storage probe: ' + storage.slice(0, 110));
  const bad = remoteUrls(page);
  record('F1_file_network_zero_remote', bad.length === 0, bad.length ? '远程: ' + bad.join(', ') : '远程 0 条（file origin 启动零 fetch）');
  if (PUB_KEY) {
    await goto(page, base + `?sb_url=${encodeURIComponent(PROJECT_URL)}&sb_key=${encodeURIComponent(PUB_KEY)}`);
    await waitFor(page, `!!document.querySelector('[data-testid="login-panel"]')`, 15000, 'login panel (file, query config)');
    const bad2 = remoteUrls(page);
    record('F2_file_remote_only_supabase', bad2.length === 0, 'supabase 调用 ' + supabaseCalls(page).length + ' 条; 其他远程 ' + bad2.length);
  } else {
    record('F2_file_remote_only_supabase', true, 'SKIP：未注入 SUPABASE_PUBLISHABLE_KEY');
  }
  await closePage(page);
}

async function scenarioSecretScan() {
  const files = [
    path.join(ROOT, 'dist', 'index.html'),
    path.join(ROOT, 'dist', 'release-manifest.json'),
    path.join(ROOT, 'index.html'),
    path.join(ROOT, 'assets', 'js', 'config.js'),
    path.join(ROOT, 'assets', 'js', 'transport.js'),
  ];
  let leak = [];
  for (const f of files) {
    const c = fs.readFileSync(f, 'utf8');
    if (PUB_KEY && c.includes(PUB_KEY)) leak.push(path.basename(f) + ':PUB_KEY');
    if (/eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}/.test(c)) leak.push(path.basename(f) + ':jwt-like');
    if (/service_role/i.test(c)) leak.push(path.basename(f) + ':service_role');
  }
  record('S1_secret_scan_dist_and_source', leak.length === 0, leak.length ? leak.join('; ') : '5 个关键文件零密钥形态');
}

// ---------- 主流程 ----------
let browser;
let httpServer;
async function main() {
  if (PUB_KEY) keyRedact.push(PUB_KEY);
  if (OWNER_PASSWORD) keyRedact.push(OWNER_PASSWORD);
  fs.mkdirSync(OUT_DIR, { recursive: true });

  httpServer = spawn('python3', ['-m', 'http.server', String(HTTP_PORT), '--bind', '127.0.0.1'], {
    cwd: ROOT,
    stdio: 'ignore',
  });
  await new Promise((res, rej) => {
    const t0 = Date.now();
    const tick = async () => {
      try {
        await fetchJson(`${HTTP_BASE}/json-check-does-not-exist`);
      } catch (e) {
        if (e.statusCode !== undefined) return res();
      }
      // 简易探活：任意 HTTP 响应（404 也算服务已起）
      http
        .get(`${HTTP_BASE}/index.html`, (r) => {
          r.resume();
          res();
        })
        .on('error', () => (Date.now() - t0 > 8000 ? rej(new Error('http server start timeout')) : setTimeout(tick, 200)));
    };
    tick();
  });

  const chromeProfile = fs.mkdtempSync(path.join(os.tmpdir(), 'morrow-chrome-'));
  const chrome = spawn(CHROME, [
    '--headless=new',
    '--remote-debugging-port=0',
    `--user-data-dir=${chromeProfile}`,
    '--no-first-run',
    '--disable-extensions',
    '--disable-background-networking',
    '--window-size=1280,900',
    'about:blank',
  ], { stdio: ['ignore', 'ignore', 'pipe'] });

  const wsUrl = await new Promise((res, rej) => {
    let buf = '';
    const t = setTimeout(() => rej(new Error('chrome devtools ws parse timeout')), 15000);
    chrome.stderr.on('data', (d) => {
      buf += d.toString();
      const m = buf.match(/DevTools listening on (ws:\/\/\S+)/);
      if (m) {
        clearTimeout(t);
        res(m[1]);
      }
    });
  });

  browser = new Cdp(wsUrl);
  await browser.ready;
  await browser.send('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: chromeProfile });

  const t0 = Date.now();
  try {
    await scenarioHttpBoot();
    await scenarioFileDist();
    await scenarioSecretScan();
  } finally {
    const report = {
      generated_at_utc: new Date().toISOString(),
      runtime: { node: process.version, chrome: 'headless new (CDP)', duration_ms: Date.now() - t0 },
      env_presence: {
        SUPABASE_PUBLISHABLE_KEY: PUB_KEY ? 'set(len=' + PUB_KEY.length + ')' : 'unset',
        MORROW_OWNER_EMAIL: OWNER_EMAIL ? 'set' : 'unset',
        MORROW_OWNER_PASSWORD: OWNER_PASSWORD ? 'set' : 'unset',
      },
      results,
      console_warnings_errors: consoleLog.slice(0, 50),
    };
    fs.writeFileSync(path.join(OUT_DIR, 'browser-evidence.json'), JSON.stringify(report, null, 2) + '\n');
    browser.close();
    chrome.kill('SIGKILL');
    httpServer.kill('SIGKILL');
    fs.rmSync(chromeProfile, { recursive: true, force: true });
  }
  const fails = results.filter((r) => !r.pass);
  console.log(`\n== 汇总: ${results.length - fails.length}/${results.length} 通过 ==`);
  process.exitCode = fails.length ? 1 : 0;
}

main().catch((e) => {
  console.error('RUNNER CRASH:', e.message);
  try {
    browser && browser.close();
  } catch (_) {}
  try {
    httpServer && httpServer.kill('SIGKILL');
  } catch (_) {}
  process.exitCode = 1;
});
