#!/usr/bin/env node
/* Morrow MVP-002 视觉/响应式/可访问性实测 runner（源码模式 http://127.0.0.1:8080）。
 * 产出：
 *   docs/planning/evidence/MVP-002/shot-{375,1280}-{today,dialog}.png
 *   docs/planning/evidence/MVP-002/shot-textzoom200.png
 *   docs/planning/evidence/MVP-002/shot-keyboard-focus.png
 *   docs/planning/evidence/MVP-002/responsive-matrix.json
 * 无横向溢出为程序化断言（scrollWidth <= innerWidth），覆盖 320/375/390/768/1280。
 * 200% 文本缩放：:root font-size 16px→32px（全站 rem 体系，等效文本翻倍重排）。
 * 键盘 focus：CDP Input.dispatchKeyEvent 真实 Tab 键，非脚本 focus()。
 * 凭据 env 注入零落盘；截图不含地址栏/凭据。
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

let keyRedact = [];
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
      }
    });
  }
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
async function setViewport(width, height) {
  await browser.send('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 1, mobile: width < 768 }, sessionId);
}
async function shot(name) {
  const res = await browser.send('Page.captureScreenshot', { format: 'png' }, sessionId);
  fs.writeFileSync(path.join(OUT_DIR, name), Buffer.from(res.data, 'base64'));
  console.log('SHOT ' + name);
}
async function overflowRow(width, height, extra) {
  await setViewport(width, height);
  if (extra) await evalJs(extra);
  const r = await evalJs(`(function(){
    const de = document.documentElement;
    return { sw: de.scrollWidth, iw: window.innerWidth, zoom: getComputedStyle(document.documentElement).fontSize };
  })()`);
  return { viewport: width + 'x' + height, scrollWidth: r.sw, innerWidth: r.iw, fontSize: r.zoom, no_h_overflow: r.sw <= r.iw };
}

async function main() {
  if (PUB_KEY) keyRedact.push(PUB_KEY);
  if (OWNER_PASSWORD) keyRedact.push(OWNER_PASSWORD);
  fs.mkdirSync(OUT_DIR, { recursive: true });

  const chromeProfile = fs.mkdtempSync(path.join(os.tmpdir(), 'morrow-mvp002v-'));
  const chrome = spawn(CHROME, [
    '--headless=new', '--remote-debugging-port=0', `--user-data-dir=${chromeProfile}`,
    '--no-first-run', '--disable-extensions', '--disable-background-networking',
    '--password-store=basic', '--use-mock-keychain', '--disable-sync',
    '--window-size=1280,900', '--force-device-scale-factor=1', 'about:blank',
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
  const matrix = [];
  try {
    const { targetId } = await browser.send('Target.createTarget', { url: 'about:blank' });
    const att = await browser.send('Target.attachToTarget', { targetId, flatten: true });
    sessionId = att.sessionId;
    await browser.send('Page.enable', {}, sessionId);
    await browser.send('Runtime.enable', {}, sessionId);

    // 登录（首屏 1280）
    await setViewport(1280, 900);
    await browser.send('Page.navigate', { url: `${HTTP_BASE}/index.html?sb_url=${encodeURIComponent('https://umutubzcwwmmbxfjkyvj.supabase.co')}&sb_key=${encodeURIComponent(PUB_KEY)}` }, sessionId);
    await waitFor(`!!document.querySelector('[data-testid="login-panel"]')`, 20000, 'login panel');
    await evalJs(`
      document.getElementById('login-email').value = ${JSON.stringify(OWNER_EMAIL)};
      document.getElementById('login-password').value = ${JSON.stringify(OWNER_PASSWORD)};
      document.getElementById('login-form').dispatchEvent(new Event('submit', {cancelable:true}));
    `);
    await waitFor(`!!document.querySelector('[data-testid="today-page"]')`, 25000, 'today page');

    // 桌面 1280：整页 + 修正对话框
    await setViewport(1280, 900);
    await new Promise((r) => setTimeout(r, 600));
    await shot('shot-1280-today.png');
    await evalJs(`document.querySelector('[data-testid="anchor-wake"] [data-act="check"]').click()`);
    await waitFor(`!!document.getElementById('check-time')`, 8000, 'check dialog 1280');
    await new Promise((r) => setTimeout(r, 400));
    await shot('shot-1280-dialog.png');
    await evalJs(`document.querySelector('[data-dialog="cancel"]').click()`);
    await waitFor(`!document.querySelector('[data-testid="today-dialog"]')`, 8000, 'dialog closed');
    matrix.push(await overflowRow(1280, 900));

    // 768
    matrix.push(await overflowRow(768, 1024));

    // 移动 375：整页 + 打卡对话框
    await setViewport(375, 812);
    await new Promise((r) => setTimeout(r, 400));
    await shot('shot-375-today.png');
    await evalJs(`document.querySelector('[data-testid="anchor-wake"] [data-act="check"]').click()`);
    await waitFor(`!!document.getElementById('check-time')`, 8000, 'check dialog 375');
    await new Promise((r) => setTimeout(r, 400));
    await shot('shot-375-dialog.png');
    await evalJs(`document.querySelector('[data-dialog="cancel"]').click()`);
    await waitFor(`!document.querySelector('[data-testid="today-dialog"]')`, 8000, 'dialog closed 375');
    matrix.push({ viewport: '375x812', no_h_overflow: true }); // 下方统一用 375 复测行替代
    matrix.pop();
    matrix.push(await overflowRow(375, 812));

    // 390 / 320 溢出断言
    matrix.push(await overflowRow(390, 844));
    matrix.push(await overflowRow(320, 568));

    // 200% 文本缩放（375 视口，:root 16px→32px）
    await setViewport(375, 812);
    await evalJs(`document.documentElement.style.fontSize = '32px'`);
    await new Promise((r) => setTimeout(r, 400));
    await shot('shot-textzoom200.png');
    const zoomRow = await overflowRow(375, 812);
    zoomRow.viewport = '375x812 @200% text';
    matrix.push(zoomRow);
    await evalJs(`document.documentElement.style.fontSize = ''`);

    // 键盘 focus：真实 Tab 键导航到 wake 打卡按钮
    await setViewport(1280, 900);
    await evalJs(`document.body.focus && document.body.focus()`);
    for (let i = 0; i < 30; i += 1) {
      const onWake = await evalJs(`document.activeElement && document.activeElement.getAttribute && document.activeElement.getAttribute('data-act') === 'check' && document.activeElement.closest('[data-testid="anchor-wake"]') !== null`);
      if (onWake) break;
      await browser.send('Input.dispatchKeyEvent', { type: 'rawKeyDown', key: 'Tab', code: 'Tab', windowsVirtualKeyCode: 9, nativeVirtualKeyCode: 9 }, sessionId);
      await new Promise((r) => setTimeout(r, 120));
    }
    const focusInfo = await evalJs(`(function(){
      const a = document.activeElement;
      const vis = a && a.matches && a.matches(':focus-visible');
      return { tag: a ? a.tagName : '', act: a && a.getAttribute ? a.getAttribute('data-act') : '', focusVisible: !!vis, rect: a ? a.getBoundingClientRect().width >= 44 : false };
    })()`);
    await shot('shot-keyboard-focus.png');
    matrix.push({ viewport: 'keyboard', tab_reaches_wake_check: focusInfo.act === 'check', focus_visible_ring: focusInfo.focusVisible, target_ge_44px: focusInfo.rect });

    fs.writeFileSync(path.join(OUT_DIR, 'responsive-matrix.json'), JSON.stringify({
      generated_at_utc: new Date().toISOString(),
      note: 'no_h_overflow = documentElement.scrollWidth <= innerWidth；200% 文本缩放 = :root font-size 32px',
      matrix,
    }, null, 2) + '\n');
    console.log('MATRIX ' + JSON.stringify(matrix, null, 1));
  } finally {
    browser.close();
    chrome.kill('SIGKILL');
    fs.rmSync(chromeProfile, { recursive: true, force: true });
  }
}

main().catch((e) => { console.error('RUNNER CRASH:', e.message); process.exitCode = 1; });
