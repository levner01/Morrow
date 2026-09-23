#!/usr/bin/env node
/* Morrow MVP-002 file:// 断网行为实测。
 * 场景 F1：file:// 引导（origin=null），存储探针如实显示；
 * 场景 F2：断网（Network.emulateNetworkConditions offline）→ today 上下文加载失败，
 *         显式错误展示，且无自动重放（supabase 出站请求有界）。
 * 说明：drafts.add 在 P0-006 壳中为休眠设施（无任何调用方），本卡今日页无草稿生产者，
 *       故不断言草稿条目，只验证「断网不静默、不自动重放」的合同行为。
 * 输出：file:// 断言打到 stdout + docs/planning/evidence/MVP-002/file-mode-output.json
 */
'use strict';

const { spawn } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');

const ROOT = path.resolve(__dirname, '..');
const OUT_DIR = path.join(ROOT, 'docs', 'planning', 'evidence', 'MVP-002');
const FILE_URL = 'file://' + path.join(ROOT, 'index.html');
const PUB_KEY = process.env.SUPABASE_PUBLISHABLE_KEY || '';
const OWNER_EMAIL = process.env.MORROW_OWNER_EMAIL || '';
const OWNER_PASSWORD = process.env.MORROW_OWNER_PASSWORD || '';
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

const results = [];
let keyRedact = [];
function record(id, pass, detail) {
  results.push({ id, pass: !!pass, detail: String(detail == null ? '' : detail).slice(0, 300) });
  console.log(`${pass ? 'PASS' : 'FAIL'}  ${id}${detail ? '  — ' + String(detail).slice(0, 140) : ''}`);
}
function redact(s) {
  let out = String(s);
  for (const k of keyRedact) if (k) out = out.split(k).join('<redacted>');
  return out;
}

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
      } else if (msg.method) this.handlers.forEach((h) => h(msg));
    });
  }
  on(fn) { this.handlers.push(fn); }
  send(method, params, sessionId, timeoutMs = 30000) {
    const id = this.nextId++;
    const payload = { id, method, params: params || {} };
    if (sessionId) payload.sessionId = sessionId;
    this.ws.send(JSON.stringify(payload));
    return new Promise((res, rej) => {
      const t = setTimeout(() => { this.pending.delete(id); rej(new Error('CDP timeout: ' + method)); }, timeoutMs);
      this.pending.set(id, { res: (v) => { clearTimeout(t); res(v); }, rej: (e) => { clearTimeout(t); rej(e); } });
    });
  }
  close() { try { this.ws.close(); } catch (_) {} }
}

let browser, sessionId;
const network = [];
async function evalJs(expression, awaitPromise = false) {
  const res = await browser.send('Runtime.evaluate', { expression, awaitPromise, returnByValue: true }, sessionId);
  if (res.exceptionDetails) throw new Error('eval exception: ' + redact(res.exceptionDetails.exception?.description || res.exceptionDetails.text));
  return res.result ? res.result.value : undefined;
}
async function waitFor(predicateExpr, timeoutMs = 15000, label = '') {
  const t0 = Date.now();
  for (;;) {
    const ok = await evalJs(`(function(){ try { return (${predicateExpr}); } catch (e) { return false; } })()`);
    if (ok) return true;
    if (Date.now() - t0 > timeoutMs) throw new Error('waitFor timeout: ' + (label || predicateExpr));
    await new Promise((r) => setTimeout(r, 250));
  }
}

async function main() {
  if (PUB_KEY) keyRedact.push(PUB_KEY);
  if (OWNER_PASSWORD) keyRedact.push(OWNER_PASSWORD);
  fs.mkdirSync(OUT_DIR, { recursive: true });

  const chromeProfile = fs.mkdtempSync(path.join(os.tmpdir(), 'morrow-mvp002f-'));
  const chrome = spawn(CHROME, [
    '--headless=new', '--remote-debugging-port=0', `--user-data-dir=${chromeProfile}`,
    '--no-first-run', '--disable-extensions', '--disable-background-networking',
    '--password-store=basic', '--use-mock-keychain', '--disable-sync',
    '--window-size=1280,900', '--allow-file-access-from-files', 'about:blank',
  ], { stdio: ['ignore', 'ignore', 'pipe'] });

  const wsUrl = await new Promise((res, rej) => {
    let buf = '';
    const t = setTimeout(() => rej(new Error('chrome ws timeout')), 15000);
    chrome.stderr.on('data', (d) => {
      buf += d.toString();
      const m = buf.match(/DevTools listening on (ws:\/\/\S+)/);
      if (m) { clearTimeout(t); res(m[1]); }
    });
  });

  browser = new Cdp(wsUrl);
  await browser.ready;
  try {
    const { targetId } = await browser.send('Target.createTarget', { url: 'about:blank' });
    const att = await browser.send('Target.attachToTarget', { targetId, flatten: true });
    sessionId = att.sessionId;
    await browser.send('Page.enable', {}, sessionId);
    await browser.send('Runtime.enable', {}, sessionId);
    await browser.send('Network.enable', {}, sessionId);
    browser.on((msg) => {
      if (msg.sessionId !== sessionId) return;
      if (msg.method === 'Network.requestWillBeSent') network.push(redact(msg.params.request.url));
    });

    // F1：file:// 引导 + 配置注入 + 登录（在线）
    await browser.send('Page.navigate', { url: `${FILE_URL}?sb_url=${encodeURIComponent('https://umutubzcwwmmbxfjkyvj.supabase.co')}&sb_key=${encodeURIComponent(PUB_KEY)}` }, sessionId);
    await waitFor(`!!document.querySelector('[data-testid="login-panel"]')`, 20000, 'login panel (file)');
    const storageLine = await evalJs(`document.getElementById('storage-line').textContent`);
    record('F1_file_boot_storage_probe', /localStorage/.test(storageLine), 'file:// origin 探针: ' + storageLine.slice(0, 60));
    await evalJs(`
      document.getElementById('login-email').value = ${JSON.stringify(OWNER_EMAIL)};
      document.getElementById('login-password').value = ${JSON.stringify(OWNER_PASSWORD)};
      document.getElementById('login-form').dispatchEvent(new Event('submit', {cancelable:true}));
    `);
    await waitFor(`!!document.querySelector('[data-testid="today-page"]')`, 25000, 'today page (file)');
    record('F1_file_today_page', true, 'file:// 登录后今日页渲染');

    // F2：断网 → 刷新 → 显式错误 + 出站请求有界（无自动重放）
    await browser.send('Network.emulateNetworkConditions', { offline: true, latency: 0, downloadThroughput: -1, uploadThroughput: -1 }, sessionId);
    const before = network.length;
    await browser.send('Page.navigate', { url: `${FILE_URL}` }, sessionId);
    await new Promise((r) => setTimeout(r, 14000)); // 超时 12s 窗口 + 余量
    const visibleState = await evalJs(`(function(){
      const fail = document.querySelector('[data-testid="failure-panel"]');
      const login = document.querySelector('[data-testid="login-panel"]');
      const today = document.querySelector('[data-testid="today-page"]');
      const err = document.querySelector('[data-testid="login-error"], .form-error, [data-testid="today-error"]');
      return JSON.stringify({
        failure: fail ? fail.dataset.kind : '',
        login: !!login, today: !!today,
        errText: err ? err.textContent.slice(0, 60) : ''
      });
    })()`);
    const st = JSON.parse(visibleState);
    const outbound = network.slice(before).filter((u) => /\.supabase\.co/.test(u));
    const explicit = st.failure === 'network' || /无法连接|超时/.test(st.errText);
    record('F2_offline_explicit_error', explicit, `state=${visibleState}`);
    record('F2_no_auto_replay', outbound.length <= 8, `断网期间 supabase 出站 ${outbound.length} 条（含 auth+context 首试，无重试风暴）`);
    await browser.send('Network.emulateNetworkConditions', { offline: false, latency: 0, downloadThroughput: -1, uploadThroughput: -1 }, sessionId);
  } finally {
    fs.writeFileSync(path.join(OUT_DIR, 'file-mode-output.json'), JSON.stringify({
      generated_at_utc: new Date().toISOString(),
      mode: 'file:// + offline emulation (Network.emulateNetworkConditions)',
      results,
    }, null, 2) + '\n');
    browser.close();
    chrome.kill('SIGKILL');
    fs.rmSync(chromeProfile, { recursive: true, force: true });
  }
  const fails = results.filter((r) => !r.pass);
  console.log(`\n== 汇总: ${results.length - fails.length}/${results.length} 通过 ==`);
  process.exitCode = fails.length ? 1 : 0;
}

main().catch((e) => { console.error('RUNNER CRASH:', e.message); process.exitCode = 1; });
