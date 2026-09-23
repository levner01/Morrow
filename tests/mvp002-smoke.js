#!/usr/bin/env node
/* Morrow MVP-002 烟测 runner（公司机源码模式 http://127.0.0.1:8080）。
 * 真实凭据 env 注入（keychain → env → 内存），凭据零落盘。
 * 真实写纪律（写进 result.md 的策略）：
 *   - 写类 RPC 只对今日 biz_date 做一组显式验证；打卡 → 修正 → 清空 最终复原未记录态；
 *   - 日型：今日已物化锁定，切普通工作日预期 DAY_PLAN_LOCKED（如实显示即验证，不真改）；
 *   - 未来时间打卡预期 VALIDATION_FAILED（错误反馈验证）。
 * 输出：docs/planning/evidence/MVP-002/smoke-output.json（redact）
 */
'use strict';

const { spawn } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');

const ROOT = path.resolve(__dirname, '..');
const OUT_DIR = path.join(ROOT, 'docs', 'planning', 'evidence', 'MVP-002');
const HTTP_BASE = 'http://127.0.0.1:8080';
const PUB_KEY = process.env.SUPABASE_PUBLISHABLE_KEY || '';
const OWNER_EMAIL = process.env.MORROW_OWNER_EMAIL || '';
const OWNER_PASSWORD = process.env.MORROW_OWNER_PASSWORD || '';
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
// SMOKE_SKIP_WRITES=1：跳过 S4–S8 真实写序列（已验证过一次，最终态已复原），只跑只读与拒绝类场景。
const SKIP_WRITES = process.env.SMOKE_SKIP_WRITES === '1';

const results = [];
const network = [];
let keyRedact = [];

function record(id, pass, detail) {
  results.push({ id, pass: !!pass, detail: String(detail == null ? '' : detail).slice(0, 400) });
  console.log(`${pass ? 'PASS' : 'FAIL'}  ${id}${detail ? '  — ' + String(detail).slice(0, 140) : ''}`);
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

let browser, page;
async function newPage() {
  const { targetId } = await browser.send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await browser.send('Target.attachToTarget', { targetId, flatten: true });
  page = { targetId, sessionId };
  await browser.send('Page.enable', {}, sessionId);
  await browser.send('Runtime.enable', {}, sessionId);
  await browser.send('Network.enable', {}, sessionId);
  browser.on((msg) => {
    if (msg.sessionId !== sessionId) return;
    if (msg.method === 'Network.requestWillBeSent') network.push(redact(msg.params.request.url));
  });
}

async function goto(url) { await browser.send('Page.navigate', { url }, page.sessionId); }
async function evalJs(expression, awaitPromise = false) {
  const res = await browser.send('Runtime.evaluate', { expression, awaitPromise, returnByValue: true }, page.sessionId);
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

async function login() {
  await goto(`${HTTP_BASE}/index.html?sb_url=${encodeURIComponent('https://umutubzcwwmmbxfjkyvj.supabase.co')}&sb_key=${encodeURIComponent(PUB_KEY)}`);
  await waitFor(`!!document.querySelector('[data-testid="login-panel"]')`, 20000, 'login panel');
  await evalJs(`
    document.getElementById('login-email').value = ${JSON.stringify(OWNER_EMAIL)};
    document.getElementById('login-password').value = ${JSON.stringify(OWNER_PASSWORD)};
    document.getElementById('login-form').dispatchEvent(new Event('submit', {cancelable:true}));
  `);
  await waitFor(`!!document.querySelector('[data-testid="today-page"]')`, 25000, 'today page after login');
}

async function main() {
  if (PUB_KEY) keyRedact.push(PUB_KEY);
  if (OWNER_PASSWORD) keyRedact.push(OWNER_PASSWORD);
  fs.mkdirSync(OUT_DIR, { recursive: true });

  const chromeProfile = fs.mkdtempSync(path.join(os.tmpdir(), 'morrow-mvp002-'));
  const chrome = spawn(CHROME, [
    '--headless=new', '--remote-debugging-port=0', `--user-data-dir=${chromeProfile}`,
    '--no-first-run', '--disable-extensions', '--disable-background-networking',
    '--password-store=basic', '--use-mock-keychain', '--disable-sync',
    '--window-size=1280,900', 'about:blank',
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
  const t0 = Date.now();

  try {
    await newPage();
    await login();

    // S1 页面结构：三锚点固定顺序 + 目标时间
    const order = await evalJs(`Array.from(document.querySelectorAll('.anchor-row')).map(r => r.dataset.anchor).join(',')`);
    const targets = await evalJs(`Array.from(document.querySelectorAll('.anchor-row .anchor-col-target .anchor-value')).map(e => e.textContent.trim()).join(',')`);
    record('S1_anchor_order_and_targets', order === 'wake,workout_end,lights_off' && targets === '06:50,19:15,22:15', `order=${order}; targets=${targets}`);

    // S2 下一步区域（Core 投影渲染）
    const hasNext = await evalJs(`!!document.querySelector('[data-testid="next-action"]')`);
    const nextText = hasNext ? await evalJs(`document.querySelector('.next-text').textContent`) : '';
    record('S2_next_action_rendered', hasNext && /记录/.test(nextText), 'next=' + nextText);

    // S3 record_open 已发（辅助证据，device_id 仅去重标识）
    await new Promise((r) => setTimeout(r, 1500));
    const opened = network.some((u) => /record_open_v1/.test(u));
    record('S3_record_open_fired', opened, 'record_open_v1 请求已捕获');

    if (!SKIP_WRITES) {
    // S4 打卡 wake（默认当下时间）→ 真实写
    await evalJs(`document.querySelector('[data-testid="anchor-wake"] [data-act="check"]').click()`);
    await waitFor(`!!document.querySelector('[data-testid="today-dialog"]')`, 8000, 'check dialog');
    await evalJs(`document.querySelector('[data-dialog="primary"]').click()`);
    await waitFor(`!!document.querySelector('[data-testid="anchor-wake"] .anchor-actual-time')`, 20000, 'wake actual after check');
    const wakeActual = await evalJs(`document.querySelector('[data-testid="anchor-wake"] .anchor-actual-time').textContent`);
    const wakeStatus = await evalJs(`document.querySelector('[data-testid="anchor-wake"] .status-recorded') !== null`);
    record('S4_check_anchor_persisted', wakeStatus && /^\d{2}:\d{2}$/.test(wakeActual), `wake actual=${wakeActual}; status=已记录`);

    // S5 修正 wake → 06:50（LWW 覆写，达标由 Core 投影）
    await evalJs(`document.querySelector('[data-testid="anchor-wake"] [data-act="edit"]').click()`);
    await waitFor(`!!document.getElementById('check-time')`, 8000, 'edit dialog');
    await evalJs(`
      const t = document.getElementById('check-time');
      t.value = '2026-09-23T06:50';
      document.querySelector('[data-dialog="primary"]').click();
    `);
    await waitFor(`document.querySelector('[data-testid="anchor-wake"] .anchor-actual-time').textContent.trim() === '06:50'`, 20000, 'wake 06:50');
    const met = await evalJs(`document.querySelector('[data-testid="anchor-wake"] .anchor-met') ? document.querySelector('[data-testid="anchor-wake"] .anchor-met').textContent : ''`);
    record('S5_edit_anchor_lww', true, `wake=06:50; Core 投影 met=${met}`);

    // S6 刷新回显（持久化验证）
    await goto(`${HTTP_BASE}/index.html`);
    await waitFor(`!!document.querySelector('[data-testid="today-page"]')`, 25000, 'today page after reload');
    const persisted = await evalJs(`(document.querySelector('[data-testid="anchor-wake"] .anchor-actual-time')||{textContent:''}).textContent.trim()`);
    record('S6_reload_persistence', persisted === '06:50', `refresh 后 wake actual=${persisted}`);

    // S7 清空 wake（确认对话文案如实）
    await evalJs(`document.querySelector('[data-testid="anchor-wake"] [data-act="clear"]').click()`);
    await waitFor(`!!document.querySelector('[data-testid="today-dialog"]')`, 8000, 'clear dialog');
    const clearNote = await evalJs(`document.querySelector('.dialog-note').textContent`);
    await evalJs(`document.querySelector('[data-dialog="primary"]').click()`);
    await waitFor(`!!document.querySelector('[data-testid="anchor-wake"] .anchor-actual-empty')`, 20000, 'wake cleared');
    record('S7_clear_anchor', /分母保持不变/.test(clearNote), `确认文案="${clearNote.slice(0, 40)}"；wake 已回未记录`);

    // S8 日型切换：今日已物化锁定 → 切普通工作日预期 DAY_PLAN_LOCKED 如实显示
    await evalJs(`document.getElementById('daytype-change-btn').click()`);
    await waitFor(`!!document.querySelector('[data-testid="today-dialog"]')`, 8000, 'daytype dialog');
    await evalJs(`
      const r = document.querySelector('input[name="daytype-opt"][value="ordinary_workday"]');
      r.checked = true;
      document.querySelector('[data-dialog="primary"]').click();
    `);
    await waitFor(`!!document.getElementById('today-error') && !document.getElementById('today-error').hidden`, 20000, 'daytype error visible');
    const dtErr = await evalJs(`document.getElementById('today-error').textContent`);
    const dtName = await evalJs(`document.querySelector('.daytype-name').textContent`);
    record('S8_day_plan_locked_shown', /已锁定|DAY_PLAN_LOCKED/.test(dtErr) && dtName === '训练工作日', `error="${dtErr.slice(0, 50)}"；日型保持=${dtName}`);
    } // end if (!SKIP_WRITES)

    // S9 错误反馈：未来时间打卡 → VALIDATION_FAILED message
    // 先快照当前错误文本（S8 可能残留），等待文本变化再断言，避免把残留当新错误。
    await evalJs(`document.querySelector('[data-testid="anchor-lights_off"] [data-act="check"]').click()`);
    await waitFor(`!!document.getElementById('check-time')`, 8000, 'check dialog lights');
    const prevErr = await evalJs(`document.getElementById('today-error') ? document.getElementById('today-error').textContent : ''`);
    await evalJs(`
      const t = document.getElementById('check-time');
      t.value = '2026-09-25T23:00';
      document.querySelector('[data-dialog="primary"]').click();
    `);
    await waitFor(
      `(function(){ const e = document.getElementById('today-error'); return !!e && !e.hidden && e.textContent !== ${JSON.stringify(prevErr)}; })()`,
      20000,
      'future check error (text changed)'
    );
    const futErr = await evalJs(`document.getElementById('today-error').textContent`);
    record('S9_validation_error_shown', /实际时间不可为未来|VALIDATION/.test(futErr), `error="${futErr.slice(0, 60)}"`);
    await evalJs(`document.querySelector('[data-dialog="cancel"]').click()`);

    // S10 网络面板：远程仅 supabase.co
    const remote = network.filter((u) => !/^(chrome|devtools|data|blob):/.test(u) && !u.startsWith(HTTP_BASE) && !/\.supabase\.co/i.test(u));
    record('S10_network_remote_clean', remote.length === 0, remote.length ? '远程: ' + remote.join(',') : `远程 0；supabase 调用 ${network.filter((u) => /\.supabase\.co/.test(u)).length} 条`);
  } finally {
    fs.writeFileSync(path.join(OUT_DIR, 'smoke-output.json'), JSON.stringify({
      generated_at_utc: new Date().toISOString(),
      runtime: { node: process.version, chrome: 'headless new (CDP)', duration_ms: Date.now() - t0 },
      env_presence: { SUPABASE_PUBLISHABLE_KEY: PUB_KEY ? 'set(len=' + PUB_KEY.length + ')' : 'unset', MORROW_OWNER_EMAIL: OWNER_EMAIL ? 'set' : 'unset', MORROW_OWNER_PASSWORD: OWNER_PASSWORD ? 'set' : 'unset' },
      results,
      network_sample: network.filter((u) => /\.supabase\.co|rpc/.test(u)).slice(0, 20),
    }, null, 2) + '\n');
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
  // 崩溃前导出页面可见状态，便于定位是登录失败 / 引导失败 / 渲染失败。
  (async () => {
    try {
      const state = await evalJs(`(function(){
        return JSON.stringify({
          testids: Array.from(document.querySelectorAll('[data-testid]')).map(function(n){return n.dataset.testid;}),
          syncBadge: (document.getElementById('sync-badge')||{textContent:''}).textContent,
          loginErr: (document.querySelector('[data-testid="login-error"]')||{textContent:''}).textContent,
          failureKind: (document.querySelector('[data-testid="failure-panel"]')||{dataset:{}}).dataset.kind || '',
          url: location.href
        });
      })()`);
      console.error('PAGE STATE:', state);
    } catch (_) {}
    try { browser && browser.close(); } catch (_) {}
    process.exitCode = 1;
  })();
});
