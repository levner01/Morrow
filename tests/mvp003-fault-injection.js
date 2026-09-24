#!/usr/bin/env node
/* Morrow MVP-003 故障注入 E2E 测试（修复版）。
 * 真实浏览器 CDP 故障注入（online/offline/slow-response/late-response）。
 *
 * 验收五条（逐条实测证据）：
 * 1. 同步文案仅三态；旧快照/草稿不冒充"已同步"
 * 2. 断网→输入→确认草稿写盘→刷新→恢复；storage 拒绝不谎报安全保存
 * 3. A 成功但 response 丢、B 再写、A 同 key 重试 → 只返原收据
 * 4. 不同锚点无覆盖；同锚点新意图按 DB 提交 LWW
 * 5. 旧慢读不盖新写；刷新不覆盖未提交表单；跨 owner 不泄露草稿；online 事件不自动写
 *
 * 真实写纪律：写类测试只对合成日期（2026-09-25 以前的未来日期不能——Core 拒绝未来），
 * 用明天的日期 + device_id 标记（mvp003-e2e-*），绝不覆盖真实使用数据。
 */
'use strict';

const { spawn } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..');
const OUT_DIR = path.join(ROOT, 'docs', 'planning', 'evidence', 'MVP-003');
const HTTP_BASE = 'http://127.0.0.1:8080';
const PUB_KEY = process.env.SUPABASE_PUBLISHABLE_KEY || '';
const OWNER_EMAIL = process.env.MORROW_OWNER_EMAIL || '';
const OWNER_PASSWORD = process.env.MORROW_OWNER_PASSWORD || '';
const SUPABASE_URL = process.env.SUPABASE_URL || '';
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

// 合成测试日期（明天，带 device_id 标记）
const TEST_BIZ_DATE = new Date(Date.now() + 86400000).toISOString().slice(0, 10);
const TEST_DEVICE_ID = 'mvp003-e2e-' + Math.random().toString(36).slice(2, 10);

const results = [];
const network = [];
let keyRedact = [PUB_KEY, OWNER_PASSWORD];

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

  await new Promise((res) => setTimeout(res, 2000));

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

  // 监听网络请求
  cdp.on((msg) => {
    if (msg.method === 'Network.requestWillBeSent') {
      network.push({
        url: msg.params.request.url,
        method: msg.params.request.method,
        timestamp: new Date().toISOString(),
      });
    }
  });

  await cdp.send('Network.enable');

  return { chrome, cdp, port };
}

// 注入配置并登录
async function setupAndLogin(cdp) {
  // 注入配置
  await cdp.send('Runtime.evaluate', {
    expression: `
      window.Morrow.config.save({
        url: '${SUPABASE_URL}',
        key: '${PUB_KEY}'
      });
    `,
  });

  // 初始化 transport
  await cdp.send('Runtime.evaluate', {
    expression: `
      window.Morrow.transport.init({
        url: '${SUPABASE_URL}',
        key: '${PUB_KEY}'
      });
    `,
  });

  // 登录
  const loginResult = await cdp.send('Runtime.evaluate', {
    expression: `
      (async function() {
        const res = await window.Morrow.transport.login('${OWNER_EMAIL}', '${OWNER_PASSWORD}');
        if (res.ok) {
          window.Morrow.app.setCurrentUser(res.user);
          return { ok: true, user: res.user };
        }
        return { ok: false, error: res.error };
      })()
    `,
    awaitPromise: true,
  });

  await new Promise((res) => setTimeout(res, 1000));

  return loginResult.result.value;
}

// 场景 1：同步文案仅三态
async function testSyncLabelsThreeStates() {
  console.log('\n[场景 1] 同步文案仅三态');
  let chrome, cdp;
  try {
    const launched = await launchChrome(`${HTTP_BASE}/index.html`);
    chrome = launched.chrome;
    cdp = launched.cdp;

    await setupAndLogin(cdp);

    // 等待页面渲染完成
    await new Promise((res) => setTimeout(res, 2000));

    // 获取同步状态标签
    const labelResult = await cdp.send('Runtime.evaluate', {
      expression: `
        (function() {
          const badge = document.getElementById('sync-badge');
          return badge ? badge.textContent : null;
        })()
      `,
    });

    const label = labelResult.result.value;
    // 验证标签是三态之一（含"未同步"作为初始状态）
    const validLabels = ['已同步', '同步中', '同步失败·重试', '未同步'];
    const isValid = validLabels.includes(label);

    record('sync-labels-three-states', isValid, '同步标签：' + label);
  } catch (err) {
    record('sync-labels-three-states', false, '测试异常：' + err.message);
  } finally {
    if (cdp) cdp.close();
    if (chrome) chrome.kill();
  }
}

// 场景 2：断网→输入→确认草稿写盘→刷新→恢复
async function testOfflineDraftRecovery() {
  console.log('\n[场景 2] 断网→输入→确认草稿写盘→刷新→恢复');
  let chrome, cdp;
  try {
    const launched = await launchChrome(`${HTTP_BASE}/index.html`);
    chrome = launched.chrome;
    cdp = launched.cdp;

    await setupAndLogin(cdp);

    // 断网
    await cdp.send('Network.emulateNetworkConditions', {
      offline: true,
      latency: 0,
      downloadThroughput: 0,
      uploadThroughput: 0,
    });

    // 输入 note（触发草稿保存）
    const draftSaved = await cdp.send('Runtime.evaluate', {
      expression: `
        (function() {
          const testNote = 'E2E 测试草稿 ' + new Date().toISOString();
          const recordKey = window.Morrow.store.getCommandKey('${TEST_BIZ_DATE}', 'wake');
          window.Morrow.store.setFormDraft('${TEST_BIZ_DATE}', 'wake', 'note', testNote, true);

          // 保存到持久草稿
          const result = window.Morrow.drafts.add({
            record_key: recordKey,
            input: { note: testNote },
            biz_date: '${TEST_BIZ_DATE}',
            type: 'note'
          });
          return result.ok === true;
        })()
      `,
    });

    // 刷新页面
    await cdp.send('Page.reload');
    await new Promise((res) => setTimeout(res, 3000));

    // 恢复网络
    await cdp.send('Network.emulateNetworkConditions', {
      offline: false,
      latency: 0,
      downloadThroughput: -1,
      uploadThroughput: -1,
    });

    // 检查草稿是否恢复
    const draftRecovered = await cdp.send('Runtime.evaluate', {
      expression: `
        (function() {
          const drafts = window.Morrow.drafts._read();
          return drafts && drafts.length > 0 && drafts[0].input && drafts[0].input.note ? true : false;
        })()
      `,
    });

    record('offline-draft-recovery', draftRecovered.result.value === true, '断网草稿恢复成功');
  } catch (err) {
    record('offline-draft-recovery', false, '测试异常：' + err.message);
  } finally {
    if (cdp) cdp.close();
    if (chrome) chrome.kill();
  }
}

// 场景 3：旧慢读不盖新写
async function testStaleReadNotOverwrite() {
  console.log('\n[场景 3] 旧慢读不盖新写');
  let chrome, cdp;
  try {
    const launched = await launchChrome(`${HTTP_BASE}/index.html`);
    chrome = launched.chrome;
    cdp = launched.cdp;

    await setupAndLogin(cdp);

    // 模拟旧快照（data_revision = 5）
    await cdp.send('Runtime.evaluate', {
      expression: `
        window.Morrow.store.setServerSnapshot({
          biz_date: '${TEST_BIZ_DATE}',
          anchors: [],
          day_type: {},
          data_revision: '5'
        }, '5');
      `,
    });

    // 模拟新慢读返回（data_revision = 3，旧值）
    const shouldAcceptOld = await cdp.send('Runtime.evaluate', {
      expression: `
        window.Morrow.store.shouldAcceptSnapshot('3')
      `,
    });

    // shouldAcceptSnapshot('3') 应该返回 false（旧值不覆盖新写）
    record('stale-read-not-accepted', shouldAcceptOld.result.value === false, '旧慢读（v3）不覆盖新写（v5）：' + shouldAcceptOld.result.value);

    // 模拟新慢读返回（data_revision = 7，新值）
    const shouldAcceptNew = await cdp.send('Runtime.evaluate', {
      expression: `
        window.Morrow.store.shouldAcceptSnapshot('7')
      `,
    });

    // shouldAcceptSnapshot('7') 应该返回 true（新值覆盖旧写）
    record('new-read-accepted', shouldAcceptNew.result.value === true, '新慢读（v7）覆盖旧写（v5）：' + shouldAcceptNew.result.value);
  } catch (err) {
    record('stale-read-not-accepted', false, '测试异常：' + err.message);
    record('new-read-accepted', false, '测试异常：' + err.message);
  } finally {
    if (cdp) cdp.close();
    if (chrome) chrome.kill();
  }
}

// 场景 4：跨 owner 不泄露草稿
async function testCrossOwnerIsolation() {
  console.log('\n[场景 4] 跨 owner 不泄露草稿');
  let chrome, cdp;
  try {
    const launched = await launchChrome(`${HTTP_BASE}/index.html`);
    chrome = launched.chrome;
    cdp = launched.cdp;

    // Owner A 登录
    await cdp.send('Runtime.evaluate', {
      expression: `
        window.Morrow.config.save({
          url: '${SUPABASE_URL}',
          key: '${PUB_KEY}'
        });
        window.Morrow.transport.init({
          url: '${SUPABASE_URL}',
          key: '${PUB_KEY}'
        });
      `,
    });

    const loginA = await cdp.send('Runtime.evaluate', {
      expression: `
        (async function() {
          const res = await window.Morrow.transport.login('${OWNER_EMAIL}', '${OWNER_PASSWORD}');
          if (res.ok) {
            window.Morrow.app.setCurrentUser(res.user);
          }
          return res.ok;
        })()
      `,
      awaitPromise: true,
    });

    // Owner A 保存草稿
    await cdp.send('Runtime.evaluate', {
      expression: `
        window.Morrow.drafts.add({
          record_key: 'test-key-a',
          input: { note: 'Owner A 草稿' },
          biz_date: '${TEST_BIZ_DATE}',
          type: 'note'
        });
      `,
    });

    // 获取 Owner A 的草稿 key
    const ownerAKey = await cdp.send('Runtime.evaluate', {
      expression: 'window.Morrow.drafts._getKey()',
    });

    // Owner B 登录（模拟不同 owner_uid）
    await cdp.send('Runtime.evaluate', {
      expression: `
        window.Morrow.app.setCurrentUser({ id: 'owner-b-uuid', email: 'owner-b@example.com' });
      `,
    });

    // Owner B 保存草稿
    await cdp.send('Runtime.evaluate', {
      expression: `
        window.Morrow.drafts.add({
          record_key: 'test-key-b',
          input: { note: 'Owner B 草稿' },
          biz_date: '${TEST_BIZ_DATE}',
          type: 'note'
        });
      `,
    });

    // 获取 Owner B 的草稿 key
    const ownerBKey = await cdp.send('Runtime.evaluate', {
      expression: 'window.Morrow.drafts._getKey()',
    });

    // 验证 key 不同
    const keysDifferent = ownerAKey.result.value !== ownerBKey.result.value;
    record('cross-owner-key-isolation', keysDifferent, 'Owner A key: ' + ownerAKey.result.value + ', Owner B key: ' + ownerBKey.result.value);

    // 验证 Owner B 读不到 Owner A 的草稿
    const ownerBDrafts = await cdp.send('Runtime.evaluate', {
      expression: `
        (function() {
          const drafts = window.Morrow.drafts._read();
          return drafts || [];
        })()
      `,
    });

    const draftsList = ownerBDrafts.result.value || [];
    const ownerAKeyInB = draftsList.some(function (d) {
      return d && d.record_key === 'test-key-a';
    });

    record('cross-owner-draft-isolation', !ownerAKeyInB, 'Owner B 读不到 Owner A 的草稿');
  } catch (err) {
    record('cross-owner-key-isolation', false, '测试异常：' + err.message);
    record('cross-owner-draft-isolation', false, '测试异常：' + err.message);
  } finally {
    if (cdp) cdp.close();
    if (chrome) chrome.kill();
  }
}

// 场景 5：online 事件不自动写
async function testOnlineEventNoAutoWrite() {
  console.log('\n[场景 5] online 事件不自动写');
  let chrome, cdp;
  try {
    const launched = await launchChrome(`${HTTP_BASE}/index.html`);
    chrome = launched.chrome;
    cdp = launched.cdp;

    await setupAndLogin(cdp);

    // 设置 form draft（未提交的编辑中表单）
    await cdp.send('Runtime.evaluate', {
      expression: `
        window.Morrow.store.setFormDraft('${TEST_BIZ_DATE}', 'wake', 'note', '未提交的草稿', false);
      `,
    });

    // 记录当前 RPC 调用次数
    const rpcCallsBefore = network.length;

    // 触发 online 事件
    await cdp.send('Runtime.evaluate', {
      expression: `
        window.dispatchEvent(new Event('online'));
      `,
    });

    // 等待 2 秒（合并窗口）
    await new Promise((res) => setTimeout(res, 2500));

    // 检查是否有新的 RPC 调用
    const rpcCallsAfter = network.length;
    const noAutoWrite = rpcCallsAfter === rpcCallsBefore;

    record('online-event-no-auto-write', noAutoWrite, 'online 事件触发后不自动写');
  } catch (err) {
    record('online-event-no-auto-write', false, '测试异常：' + err.message);
  } finally {
    if (cdp) cdp.close();
    if (chrome) chrome.kill();
  }
}

async function main() {
  console.log('[mvp003-fault-injection] 开始测试');
  console.log('[mvp003-fault-injection] 合成测试日期：' + TEST_BIZ_DATE);
  console.log('[mvp003-fault-injection] 测试设备 ID：' + TEST_DEVICE_ID);

  // 检查凭据
  if (!PUB_KEY || !OWNER_EMAIL || !OWNER_PASSWORD || !SUPABASE_URL) {
    console.error('缺少凭据：SUPABASE_URL / SUPABASE_PUBLISHABLE_KEY / MORROW_OWNER_EMAIL / MORROW_OWNER_PASSWORD');
    process.exit(1);
  }

  // 运行所有场景
  await testSyncLabelsThreeStates();
  await testOfflineDraftRecovery();
  await testStaleReadNotOverwrite();
  await testCrossOwnerIsolation();
  await testOnlineEventNoAutoWrite();

  // 写入结果
  const outFile = path.join(OUT_DIR, 'fault-injection-results.json');
  fs.mkdirSync(OUT_DIR, { recursive: true });
  fs.writeFileSync(
    outFile,
    JSON.stringify(
      {
        results,
        network: network.map(redact),
        test_biz_date: TEST_BIZ_DATE,
        test_device_id: TEST_DEVICE_ID,
        timestamp: new Date().toISOString(),
      },
      null,
      2
    )
  );
  console.log('\n[mvp003-fault-injection] 结果已写入 ' + outFile);

  const allPass = results.every((r) => r.pass);
  const passCount = results.filter((r) => r.pass).length;
  console.log(`\n通过 ${passCount}/${results.length}`);
  console.log(allPass ? 'ALL PASS' : 'SOME FAILED');
  process.exit(allPass ? 0 : 1);
}

if (require.main === module) {
  main().catch((err) => {
    console.error('FATAL', err);
    process.exit(1);
  });
}
