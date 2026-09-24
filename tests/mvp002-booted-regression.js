#!/usr/bin/env node
/* Morrow morrow-booted 回归测试（MVP-002 顺手修复 5）。
 * 验证：morrow-booted 类挂载则 fallback 永远不出现。
 * 场景：页面加载完成后，检查 documentElement 是否有 morrow-booted 类；
 *       如果有，则 resource-failure-banner 不应该显示。
 */
'use strict';

const { spawn } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..');
const OUT_DIR = path.join(ROOT, 'docs', 'planning', 'evidence', 'MVP-003');
const HTTP_BASE = 'http://127.0.0.1:8080';
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

const results = [];

function record(id, pass, detail) {
  results.push({ id, pass: !!pass, detail: String(detail == null ? '' : detail).slice(0, 400) });
  console.log(`${pass ? 'PASS' : 'FAIL'}  ${id}${detail ? '  — ' + String(detail).slice(0, 140) : ''}`);
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
        if (msg.error) rej(new Error(msg.error.message));
        else res(msg.result);
      } else if (msg.method) {
        this.handlers.forEach((h) => h(msg));
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

  on(fn) {
    this.handlers.push(fn);
  }

  close() {
    this.ws.close();
  }
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
    url,
  ]);

  // 等待 Chrome 启动
  await new Promise((res) => setTimeout(res, 2000));

  // 获取 WebSocket URL
  const http = require('node:http');
  const wsUrl = await new Promise((res, rej) => {
    http.get(`http://127.0.0.1:${port}/json`, (resp) => {
      let data = '';
      resp.on('data', (chunk) => (data += chunk));
      resp.on('end', () => {
        try {
          const targets = JSON.parse(data);
          const page = targets.find((t) => t.type === 'page');
          res(page.webSocketDebuggerUrl);
        } catch (e) {
          rej(e);
        }
      });
    }).on('error', rej);
  });

  const cdp = new Cdp(wsUrl);
  await cdp.ready;
  return { chrome, cdp, port };
}

async function testBootedFlag() {
  let chrome, cdp;
  try {
    // 启动本地 HTTP 服务器（假设已启动在 8080）
    const url = `${HTTP_BASE}/index.html`;
    const launched = await launchChrome(url);
    chrome = launched.chrome;
    cdp = launched.cdp;

    // 等待页面加载完成
    await new Promise((res) => setTimeout(res, 3000));

    // 检查 morrow-booted 类是否存在
    const hasBooted = await cdp.send('Runtime.evaluate', {
      expression: 'document.documentElement.classList.contains("morrow-booted")',
    });

    // 检查 resource-failure-banner 是否显示
    const bannerVisible = await cdp.send('Runtime.evaluate', {
      expression: `
        (function() {
          const banner = document.querySelector('.resource-failure-banner');
          return banner && !banner.hidden;
        })()
      `,
    });

    // 验证：如果有 morrow-booted 类，则 banner 不应该显示
    if (hasBooted.result.value === true) {
      record('booted-flag-mounted', true, 'morrow-booted 类已挂载');
      if (bannerVisible.result.value === false) {
        record('fallback-hidden', true, 'resource-failure-banner 未显示（符合预期）');
      } else {
        record('fallback-hidden', false, 'resource-failure-banner 显示了（不符合预期）');
      }
    } else {
      record('booted-flag-mounted', false, 'morrow-booted 类未挂载');
      record('fallback-hidden', false, '无法验证（booted 类未挂载）');
    }
  } catch (err) {
    record('booted-flag-mounted', false, '测试异常：' + err.message);
    record('fallback-hidden', false, '测试异常：' + err.message);
  } finally {
    if (cdp) cdp.close();
    if (chrome) chrome.kill();
  }
}

async function main() {
  console.log('[mvp002-booted-regression] 开始测试');
  await testBootedFlag();

  // 写入结果
  const outFile = path.join(OUT_DIR, 'booted-regression-results.json');
  fs.mkdirSync(OUT_DIR, { recursive: true });
  fs.writeFileSync(outFile, JSON.stringify({ results, timestamp: new Date().toISOString() }, null, 2));
  console.log('[mvp002-booted-regression] 结果已写入 ' + outFile);

  const allPass = results.every((r) => r.pass);
  console.log(allPass ? 'ALL PASS' : 'SOME FAILED');
  process.exit(allPass ? 0 : 1);
}

if (require.main === module) {
  main().catch((err) => {
    console.error('FATAL', err);
    process.exit(1);
  });
}
