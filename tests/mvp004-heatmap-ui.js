#!/usr/bin/env node
/* Morrow MVP-004 热力图 UI E2E（真实浏览器 CDP，只读纪律）。
 *
 * 验收对应：
 * 1. 30 个工作区日期含今日（首格=今日-29，末格=今日，今日格蓝框标记）
 * 2. 未开始/未记录/部分/记全未达标/全达标五态 + 今日在途，全部带文字补充（aria-label + 图例）
 * 3. 记录率≠达标率分离显示；UI 只展示 Core 结果（DOM 数字与 RPC 投影逐一对账）
 * 4. 热力图在今日页次要位置（三锚点主轴之上不得被反抢：anchor-list 在 heatmap 之前）
 * 5. 1280 / 375 / 320 三视口无横向滚动（截图入 evidence）
 *
 * 真实数据红线：本脚本只发只读 RPC（context/history），不写任何 life_data；
 * 登录凭据走环境变量注入，输出全部脱敏。
 */
'use strict';

const { spawn } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..');
const OUT_DIR = path.join(ROOT, 'docs', 'planning', 'evidence', 'MVP-004');
const HTTP_PORT = 8094;
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
    // 不依赖宿主机系统代理状态（MVP-003 实测教训）
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
        // 与 app.js 真实登录路径一致：登录成功需显式渲染 shell（内部触发 today.start）
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

function pctText(rate) {
  if (rate == null) return '—';
  const n = Number(rate);
  if (!isFinite(n)) return '—';
  return Math.round(n * 100) + '%';
}

async function screenshot(cdp, file) {
  // 整页捕获（含折叠下方的热力图格与图例），证据一图到底
  const shot = await cdp.send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true });
  fs.writeFileSync(file, Buffer.from(shot.data, 'base64'));
}

async function collectDom(cdp) {
  return evalJs(cdp, `
    (function() {
      const cells = Array.from(document.querySelectorAll('.hm-cell'));
      const anchor = document.querySelector('[data-testid="anchor-list"]');
      const hm = document.querySelector('[data-testid="heatmap30"]');
      const txt = function (sel) { const n = document.querySelector(sel); return n ? n.textContent.trim() : null; };
      return {
        count: cells.length,
        first: cells.length ? cells[0].getAttribute('data-testid') : null,
        last: cells.length ? cells[cells.length - 1].getAttribute('data-testid') : null,
        todayMarked: document.querySelectorAll('.hm-cell.hm-today').length,
        allAria: cells.every(function (c) { return !!c.getAttribute('aria-label'); }),
        states: cells.reduce(function (acc, c) {
          const s = (c.className.match(/hm-s-[a-z-]+/) || ['?'])[0];
          acc[s] = (acc[s] || 0) + 1; return acc;
        }, {}),
        legendItems: document.querySelectorAll('.hm-legend li').length,
        streak: txt('[data-testid="hm-streak"]'),
        rec: txt('[data-testid="hm-recording-rate"]'),
        met: txt('[data-testid="hm-met-rate"]'),
        provisionalNote: !!document.querySelector('[data-testid="hm-provisional-note"]'),
        anchorBeforeHeatmap: !!(anchor && hm) &&
          (anchor.getBoundingClientRect().top + window.scrollY) < (hm.getBoundingClientRect().top + window.scrollY),
        scrollW: document.documentElement.scrollWidth,
        innerW: window.innerWidth,
      };
    })()
  `);
}

async function collectRpc(cdp) {
  return evalJs(cdp, `
    (async function() {
      const ctx = await window.Morrow.transport.rpc('get_today_context_v1', {});
      if (!ctx.ok) return { ok: false, stage: 'context', error: ctx.error };
      const to = ctx.result.biz_date;
      const d = new Date(to + 'T00:00:00Z');
      d.setUTCDate(d.getUTCDate() - 29);
      const from = d.toISOString().slice(0, 10);
      const h = await window.Morrow.transport.rpc('get_anchor_history_v1', { from: from, to: to });
      if (!h.ok) return { ok: false, stage: 'history', error: h.error };
      return {
        ok: true,
        from: from,
        to: to,
        days: h.result.days.length,
        streak: h.result.stats.streak_days,
        recording_rate: h.result.stats.recording_rate,
        met_rate: h.result.stats.met_rate,
        data_revision_type: typeof h.result.data_revision,
        next_cursor: h.result.next_cursor,
      };
    })()
  `);
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

    await setupAndLogin(cdp);
    await waitFor(cdp, `!!document.querySelector('[data-testid="anchor-list"]')`, 15000, '今日页渲染');
    await waitFor(cdp, `!!document.querySelector('[data-testid="heatmap30"] .hm-cell')`, 15000, '热力图渲染');

    // ---- Core E2E（真实 JWT 只读）：RPC 投影形状 ----
    const rpc = await collectRpc(cdp);
    record('core-rpc-ok', rpc.ok === true, rpc.ok ? `days=${rpc.days} ${rpc.from}..${rpc.to}` : redact(JSON.stringify(rpc)));
    record('core-days-30', rpc.days === 30, 'days=' + rpc.days);
    record('core-revision-string', rpc.data_revision_type === 'string', 'type=' + rpc.data_revision_type);
    record('core-next-cursor-null', rpc.next_cursor === null, 'next_cursor=' + JSON.stringify(rpc.next_cursor));

    // ---- 场景 1：1280 视口 DOM 断言 + 与 RPC 对账 ----
    console.log('\n[场景 1] 1280x900：形状 / 五态文字补充 / UI-Core 对账');
    const dom = await collectDom(cdp);
    record('dom-cells-30', dom.count === 30, 'cells=' + dom.count);
    record('dom-range-match', dom.first === 'hm-day-' + rpc.from && dom.last === 'hm-day-' + rpc.to,
      `${dom.first} .. ${dom.last}`);
    record('dom-today-marked', dom.todayMarked === 1 && dom.last === 'hm-day-' + rpc.to, 'today=' + dom.todayMarked);
    record('dom-all-aria', dom.allAria === true, '每格均有 aria-label 文字补充');
    record('dom-legend-6', dom.legendItems === 6, 'legend=' + dom.legendItems);
    record('dom-states-present', Object.keys(dom.states).length >= 2, JSON.stringify(dom.states));
    record('dom-anchor-first', dom.anchorBeforeHeatmap === true, '三锚点主轴在热力图之上');
    record('reconcile-streak', dom.streak === String(rpc.streak), `DOM=${dom.streak} RPC=${rpc.streak}`);
    record('reconcile-recording-rate', dom.rec === pctText(rpc.recording_rate), `DOM=${dom.rec} RPC=${pctText(rpc.recording_rate)}`);
    record('reconcile-met-rate', dom.met === pctText(rpc.met_rate), `DOM=${dom.met} RPC=${pctText(rpc.met_rate)}`);
    record('rates-separated', true, `记录率=${dom.rec} 达标率=${dom.met}（分离显示）`);
    record('viewport-1280-no-hscroll', dom.scrollW <= 1280, `scrollW=${dom.scrollW}`);
    await screenshot(cdp, path.join(OUT_DIR, 'heatmap-1280.png'));

    // ---- 场景 2：375 移动视口 ----
    console.log('\n[场景 2] 375x800：无横向滚动');
    await cdp.send('Emulation.setDeviceMetricsOverride', {
      width: 375, height: 800, deviceScaleFactor: 2, mobile: true,
    });
    await new Promise((res) => setTimeout(res, 600));
    const dom375 = await collectDom(cdp);
    record('viewport-375-no-hscroll', dom375.scrollW <= 375, `scrollW=${dom375.scrollW}`);
    record('viewport-375-cells-30', dom375.count === 30, 'cells=' + dom375.count);
    await screenshot(cdp, path.join(OUT_DIR, 'heatmap-375.png'));

    // ---- 场景 3：320 最小视口 ----
    console.log('\n[场景 3] 320x700：无横向滚动');
    await cdp.send('Emulation.setDeviceMetricsOverride', {
      width: 320, height: 700, deviceScaleFactor: 2, mobile: true,
    });
    await new Promise((res) => setTimeout(res, 600));
    const dom320 = await collectDom(cdp);
    record('viewport-320-no-hscroll', dom320.scrollW <= 320, `scrollW=${dom320.scrollW}`);
    await screenshot(cdp, path.join(OUT_DIR, 'heatmap-320.png'));
  } finally {
    if (cdp) cdp.close();
    if (chrome) chrome.kill();
    server.kill();
  }

  const pass = results.filter((r) => r.pass).length;
  const fail = results.length - pass;
  const summary = {
    task: 'MVP-004',
    ran_at_utc: new Date().toISOString(),
    page: PAGE_URL,
    total: results.length,
    pass,
    fail,
    results,
  };
  fs.writeFileSync(path.join(OUT_DIR, 'ui-e2e-results.json'), redact(JSON.stringify(summary, null, 2)) + '\n');
  console.log(`\n${pass}/${results.length} PASS，${fail} FAIL → docs/planning/evidence/MVP-004/ui-e2e-results.json`);
  process.exit(fail === 0 ? 0 : 1);
}

main().catch((e) => {
  console.error('E2E 运行异常:', redact(e && e.stack ? e.stack : e));
  process.exit(1);
});
