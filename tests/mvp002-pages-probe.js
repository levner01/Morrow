#!/usr/bin/env node
/* Morrow MVP-002 Pages 模式等价实测：真实浏览器跑 Pages URL，登录后校验今日页渲染。 */
'use strict';
const { spawn } = require('node:child_process');
const path = require('node:path');
const os = require('node:os');
const fs = require('node:fs');

const PAGES_BASE = 'https://levner01.github.io/Morrow/';
const PUB_KEY = process.env.SUPABASE_PUBLISHABLE_KEY || '';
const OWNER_EMAIL = process.env.MORROW_OWNER_EMAIL || '';
const OWNER_PASSWORD = process.env.MORROW_OWNER_PASSWORD || '';
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
let keyRedact = [PUB_KEY, OWNER_PASSWORD].filter(Boolean);
const redact = (s) => { let o = String(s); for (const k of keyRedact) o = o.split(k).join('<redacted>'); return o; };

class Cdp {
  constructor(wsUrl) {
    this.ws = new WebSocket(wsUrl); this.nextId = 1; this.pending = new Map();
    this.ready = new Promise((res, rej) => { this.ws.addEventListener('open', res); this.ws.addEventListener('error', () => rej(new Error('ws'))); });
    this.ws.addEventListener('message', (ev) => { const m = JSON.parse(ev.data); if (m.id && this.pending.has(m.id)) { const p = this.pending.get(m.id); this.pending.delete(m.id); m.error ? p.rej(new Error(m.error.message)) : p.res(m.result); } });
  }
  send(method, params, sessionId, t = 30000) {
    const id = this.nextId++; const payload = { id, method, params: params || {} }; if (sessionId) payload.sessionId = sessionId;
    this.ws.send(JSON.stringify(payload));
    return new Promise((res, rej) => { const timer = setTimeout(() => { this.pending.delete(id); rej(new Error('timeout ' + method)); }, t); this.pending.set(id, { res: (v) => { clearTimeout(timer); res(v); }, rej: (e) => { clearTimeout(timer); rej(e); } }); });
  }
  close() { try { this.ws.close(); } catch (_) {} }
}

async function main() {
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'morrow-mvp002p-'));
  const chrome = spawn(CHROME, ['--headless=new', '--remote-debugging-port=0', `--user-data-dir=${profile}`, '--no-first-run', '--disable-extensions', '--password-store=basic', '--use-mock-keychain', '--disable-sync', '--window-size=1280,900', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
  const wsUrl = await new Promise((res, rej) => {
    let buf = ''; const t = setTimeout(() => rej(new Error('ws timeout')), 15000);
    chrome.stderr.on('data', (d) => { buf += d.toString(); const m = buf.match(/DevTools listening on (ws:\/\/\S+)/); if (m) { clearTimeout(t); res(m[1]); } });
  });
  const browser = new Cdp(wsUrl); await browser.ready;
  try {
    const { targetId } = await browser.send('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await browser.send('Target.attachToTarget', { targetId, flatten: true });
    await browser.send('Page.enable', {}, sessionId); await browser.send('Runtime.enable', {}, sessionId);
    const evalJs = async (expression) => {
      const r = await browser.send('Runtime.evaluate', { expression, returnByValue: true }, sessionId);
      if (r.exceptionDetails) throw new Error(redact(r.exceptionDetails.exception?.description || r.exceptionDetails.text));
      return r.result ? r.result.value : undefined;
    };
    const waitFor = async (expr, ms, label) => {
      const t0 = Date.now();
      for (;;) { try { if (await evalJs(`(function(){try{return (${expr});}catch(e){return false;}})()`)) return; } catch (_) {} if (Date.now() - t0 > ms) throw new Error('waitFor: ' + label); await new Promise((r) => setTimeout(r, 250)); }
    };
    await browser.send('Page.navigate', { url: `${PAGES_BASE}?sb_url=${encodeURIComponent('https://umutubzcwwmmbxfjkyvj.supabase.co')}&sb_key=${encodeURIComponent(PUB_KEY)}` }, sessionId);
    await waitFor(`!!document.querySelector('[data-testid="login-panel"]')`, 25000, 'login panel (pages)');
    await evalJs(`
      document.getElementById('login-email').value = ${JSON.stringify(OWNER_EMAIL)};
      document.getElementById('login-password').value = ${JSON.stringify(OWNER_PASSWORD)};
      document.getElementById('login-form').dispatchEvent(new Event('submit', {cancelable:true}));
    `);
    await waitFor(`!!document.querySelector('[data-testid="today-page"]')`, 30000, 'today page (pages)');
    const order = await evalJs(`Array.from(document.querySelectorAll('.anchor-row')).map(r => r.dataset.anchor).join(',')`);
    const targets = await evalJs(`Array.from(document.querySelectorAll('.anchor-row .anchor-col-target .anchor-value')).map(e => e.textContent.trim()).join(',')`);
    const next = await evalJs(`(document.querySelector('.next-text')||{textContent:''}).textContent`);
    const bannerGone = await evalJs(`getComputedStyle(document.getElementById('boot-fallback')).display === 'none'`);
    const ok = order === 'wake,workout_end,lights_off' && targets === '06:50,19:15,22:15' && bannerGone;
    console.log(`${ok ? 'PASS' : 'FAIL'}  PAGES_equiv  — order=${order}; targets=${targets}; next="${next}"; boot-fallback hidden=${bannerGone}`);
    process.exitCode = ok ? 0 : 1;
  } finally { browser.close(); chrome.kill('SIGKILL'); fs.rmSync(profile, { recursive: true, force: true }); }
}
main().catch((e) => { console.error('CRASH:', e.message); process.exitCode = 1; });
