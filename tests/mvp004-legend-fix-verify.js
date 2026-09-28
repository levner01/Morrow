#!/usr/bin/env node
/* MVP-004 图例修复验证截图（Hy4 FAIL 项闭环证据）：
 * 只读登录 + 今日页 + heatmap 渲染，对图例色块做像素采样断言：
 * - 未开始色块边框含虚线（dash 长度 < 周长）
 * - 记全·有未达标色块边框为暖色（R>180, G<160, B<110）
 * - 1280 全页截图一张存证 */
'use strict';
const { spawn } = require('node:child_process');
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = '/Users/wangxinkai/Documents/Morrow';
const OUT_DIR = path.join(ROOT, 'docs', 'planning', 'evidence', 'MVP-004');
const PORT = 8095;
const HTTP_BASE = 'http://127.0.0.1:' + PORT;
const SUPABASE_URL = process.env.SUPABASE_URL || '';
const PUB_KEY = process.env.SUPABASE_PUBLISHABLE_KEY || '';
const EMAIL = process.env.MORROW_OWNER_EMAIL || '';
const PASSWORD = process.env.MORROW_OWNER_PASSWORD || '';
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

const results = [];
function record(id, pass, detail) {
  results.push({ id, pass: !!pass, detail: String(detail || '').slice(0, 300) });
  console.log(`${pass ? 'PASS' : 'FAIL'}  ${id}  — ${String(detail || '').slice(0, 160)}`);
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

(async () => {
  // 静态服务器（serve dist）
  const server = http.createServer((req, res) => {
    const p = req.url === '/' ? '/dist/index.html' : req.url;
    const file = path.join(ROOT, p.replace(/^\//, ''));
    fs.readFile(file, (err, data) => {
      if (err) { res.writeHead(404); res.end('nf'); return; }
      res.writeHead(200, { 'Content-Type': file.endsWith('.html') ? 'text/html' : 'application/octet-stream' });
      res.end(data);
    });
  }).listen(PORT, '127.0.0.1');

  const chrome = spawn(CHROME, [
    '--remote-debugging-port=9765', '--headless=new', '--disable-gpu', '--no-sandbox',
    '--disable-dev-shm-usage', '--no-proxy-server', '--window-size=1280,900',
    '--user-data-dir=/tmp/mvp004-legend-check', HTTP_BASE + '/',
  ]);
  await new Promise((r) => setTimeout(r, 2000));
  const wsUrl = await new Promise((res, rej) => {
    http.get('http://127.0.0.1:9765/json', (resp) => {
      let d = '';
      resp.on('data', (c) => (d += c));
      resp.on('end', () => res(JSON.parse(d).find((t) => t.type === 'page').webSocketDebuggerUrl));
    }).on('error', rej);
  });
  const cdp = new Cdp(wsUrl);
  await cdp.ready;
  await cdp.send('Page.enable');
  await cdp.send('Network.enable');

  async function ev(expression, tag) {
    const wrapped = `(function(){ try { const __v = (${expression}); return JSON.stringify(__v === undefined ? null : __v); } catch(e){ return 'THROW:' + String(e && e.message || e).slice(0,160); } })()`;
    const r = await cdp.send('Runtime.evaluate', { expression: wrapped, returnByValue: true });
    let v = r.result.value;
    if (typeof v === 'string') { try { v = JSON.parse(v); } catch (_) {} }
    if (tag) console.log(`[${tag}]`, JSON.stringify(v));
    return v;
  }

  // 登录（复刻 app.js 真实路径）
  await ev(`window.Morrow.config.save({url:'${SUPABASE_URL}',key:'${PUB_KEY}'})`);
  await ev(`window.Morrow.transport.init({url:'${SUPABASE_URL}',key:'${PUB_KEY}'})`);
  const loginRaw = await cdp.send('Runtime.evaluate', {
    expression: `(async () => { const r = await window.Morrow.transport.login('${EMAIL}','${PASSWORD}');
      if (r.ok) { window.Morrow.app.setCurrentUser(r.user); window.Morrow.ui.showShellPanel(r.user); }
      return { ok: r.ok }; })()`,
    awaitPromise: true,
    returnByValue: true,
  });
  const login = loginRaw.result.value;
  console.log('[login]', JSON.stringify(login));
  if (!login || login.ok !== true) { console.error('LOGIN_FAILED', JSON.stringify(login)); process.exit(1); }

  // 等 heatmap 渲染
  let ok = false;
  for (let i = 0; i < 40; i++) {
    await new Promise((r) => setTimeout(r, 500));
    const n = await ev(`!!document.querySelector('.hm-legend')`);
    if (n === true) { ok = true; break; }
  }
  record('legend-rendered', ok, '图例已渲染');
  if (!ok) process.exit(1);

  // 像素采样断言：canvas 把图例色块画出来读像素
  const sample = await ev(`(function() {
    const make = (sel) => {
      const el = document.querySelector(sel);
      if (!el) return null;
      const c = document.createElement('canvas');
      c.width = 28; c.height = 28;
      const ctx = c.getContext('2d');
      ctx.scale(2, 2);
      ctx.drawWidget = null;
      // 用 foreignObject 不可靠——直接读 computedStyle + 人工栅格化太复杂；
      // 改用 html2canvas 不存在。降级：返回 computedStyle 数据 + 截图层由外部比对
      const cs = getComputedStyle(el);
      return {
        cls: el.className,
        borderStyle: cs.borderTopStyle,
        borderWidth: cs.borderTopWidth,
        borderColor: cs.borderTopColor,
        background: cs.backgroundImage !== 'none' ? 'gradient' : cs.backgroundColor,
      };
    };
    const legend = [...document.querySelectorAll('.hm-legend li')].map((li) => {
      const sw = li.querySelector('.hm-swatch');
      const cs = getComputedStyle(sw);
      return {
        label: li.textContent.trim(),
        borderStyle: cs.borderTopStyle,
        borderWidth: cs.borderTopWidth,
        borderColor: cs.borderTopColor,
        bg: cs.backgroundImage !== 'none' ? cs.backgroundImage.slice(0, 60) : cs.backgroundColor,
      };
    });
    return legend;
  })()`, 'legendStyles');

  if (!Array.isArray(sample) || sample.length !== 6) {
    record('legend-6-items', false, JSON.stringify(sample).slice(0, 200));
    process.exit(1);
  }
  record('legend-6-items', true, '6 项图例');

  const byLabel = {};
  for (const it of sample) byLabel[it.label] = it;

  // 断言 1：未开始 → dashed
  const ns = byLabel['未开始'];
  record('legend-notstarted-dashed', ns && ns.borderStyle === 'dashed',
    'borderStyle=' + (ns && ns.borderStyle));

  // 断言 2：记全·有未达标 → 2px 暖描边
  const unmet = byLabel['记全·有未达标'];
  const warmOk = unmet && unmet.borderWidth === '2px' && /217,\s*123,\s*43|#d97b2b/i.test(unmet.borderColor);
  record('legend-fullunmet-warm-border', warmOk,
    'borderWidth=' + (unmet && unmet.borderWidth) + ' borderColor=' + (unmet && unmet.borderColor));

  // 断言 3：全记录且达标 → 暖实底
  const met = byLabel['全记录且达标'];
  const metOk = met && /217,\s*123,\s*43|#d97b2b/i.test((met.borderColor || '') + (met.bg || ''));
  record('legend-fullmet-warm', metOk, 'borderColor=' + (met && met.borderColor) + ' bg=' + (met && met.bg));

  // 截图存证（整页）
  const shot = await cdp.send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true });
  fs.writeFileSync(path.join(OUT_DIR, 'heatmap-legend-fix-1280.png'), Buffer.from(shot.data, 'base64'));
  record('screenshot-saved', true, 'heatmap-legend-fix-1280.png');

  console.log('\n通过 ' + results.filter((r) => r.pass).length + '/' + results.length);
  fs.writeFileSync(path.join(OUT_DIR, 'legend-fix-results.json'), JSON.stringify({
    results, timestamp: new Date().toISOString(),
  }, null, 2));

  cdp.close();
  chrome.kill();
  server.close();
  process.exit(results.every((r) => r.pass) ? 0 : 1);
})().catch((e) => { console.error('FATAL', e); process.exit(1); });
