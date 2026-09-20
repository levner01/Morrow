/* Morrow app 引导层（P0-006）：状态机 boot → auth_check → synced / config_required / auth_required / failed。
 * 依据 C-07：loading 失败进 failed（可重试，展示旧快照时间戳）；session 失效进 auth_required（不丢草稿）。
 * 全局兜底：SDK 缺失 → 资源失败面板；未捕获异常/Promise 拒绝 → 内部异常面板（不白屏）。
 */
(function () {
  'use strict';
  const Morrow = (window.Morrow = window.Morrow || {});
  const RELEASE_KEY = 'morrow.release_seen.v1';
  const LAST_SYNC_KEY = 'morrow.last_sync.v1';

  // 发行标识由打包脚本注入 window.MORROW_RELEASE；源码直跑时用开发标识。
  function releaseInfo() {
    if (window.MORROW_RELEASE && window.MORROW_RELEASE.id) return window.MORROW_RELEASE;
    return { id: 'dev-source', source_sha256: '0'.repeat(64), sdk: { name: '@supabase/supabase-js', version: 'vendor-dev' } };
  }

  function readJson(key) {
    try {
      const raw = window.localStorage.getItem(key);
      return raw ? JSON.parse(raw) : null;
    } catch (_) {
      return null;
    }
  }

  function writeJson(key, value) {
    try {
      window.localStorage.setItem(key, JSON.stringify(value));
    } catch (_) { /* 存储不可用时静默：辅助信息，不影响主流程 */ }
  }

  function lastSyncStamp() {
    const rec = readJson(LAST_SYNC_KEY);
    return rec && rec.at ? Morrow.ui.formatStamp(rec.at) : '';
  }

  function markSynced() {
    writeJson(LAST_SYNC_KEY, { at: new Date().toISOString() });
    Morrow.ui.setSyncStatus('synced', '最后同步 ' + lastSyncStamp());
  }

  async function authCheck() {
    Morrow.ui.setSyncStatus('syncing', '正在校验会话…');
    const session = await Morrow.transport.currentSession();
    if (session.error) {
      if (session.error.kind === 'auth_expired') {
        Morrow.ui.setSyncStatus('failed', '登录已过期');
        Morrow.ui.showLoginPanel(session.error.text + '（草稿仍保留在本机）');
        return;
      }
      Morrow.ui.setSyncStatus('failed', '同步失败');
      Morrow.ui.showFailure('network', session.error.text, {
        title: '无法同步',
        staleSnapshotAt: lastSyncStamp(),
        onPrimary: function () {
          authCheck();
        },
      });
      return;
    }
    if (!session.session) {
      Morrow.ui.setSyncStatus('failed', '未登录');
      Morrow.ui.showLoginPanel('');
      return;
    }
    // 有本地会话 → 轻量 RPC 权威校验（网络/owner/Auth 三合一证据）。
    const verify = await Morrow.transport.verifyOwner();
    if (verify.ok) {
      markSynced();
      Morrow.ui.showShellPanel(session.session);
      bindLogout();
      return;
    }
    const err = verify.error;
    if (err.kind === 'auth_expired') {
      Morrow.ui.setSyncStatus('failed', '登录已过期');
      Morrow.ui.showLoginPanel(err.text + '（草稿仍保留在本机）');
      return;
    }
    if (err.kind === 'owner_denied') {
      Morrow.ui.setSyncStatus('failed', '账号校验未通过');
      Morrow.ui.showFailure('config', err.text, {
        title: '身份校验失败',
        onPrimary: function () {
          Morrow.config.clear();
          showConfigThenAuth();
        },
      });
      return;
    }
    Morrow.ui.setSyncStatus('failed', '同步失败');
    Morrow.ui.showFailure('network', err.text, {
      title: '无法同步',
      staleSnapshotAt: lastSyncStamp(),
      onPrimary: function () {
        authCheck();
      },
    });
  }

  function showConfigThenAuth() {
    Morrow.ui.showConfigPanel(null, function (cfg) {
      bootWithConfig(cfg);
    });
  }

  function bootWithConfig(cfg) {
    try {
      Morrow.transport.init(cfg);
    } catch (err) {
      if (err && err.message === 'SDK_NOT_LOADED') {
        Morrow.ui.showResourceFailure();
        return;
      }
      Morrow.ui.showFailure('internal', '初始化失败，请重试');
      return;
    }
    authCheck();
  }

  function bindLogout() {
    const btn = document.getElementById('logout-btn');
    if (!btn) return;
    btn.addEventListener('click', function () {
      const n = Morrow.drafts.count();
      if (n > 0) {
        Morrow.ui.showDraftLogoutDialog(n, {
          onDownload: function () {
            downloadDrafts();
            doLogout();
          },
          onKeep: function () {
            doLogout();
          },
          onWipe: function () {
            Morrow.drafts.clear();
            doLogout();
          },
        });
      } else {
        doLogout();
      }
    });
  }

  function downloadDrafts() {
    try {
      const blob = new Blob([Morrow.drafts.exportJson()], { type: 'application/json' });
      const a = document.createElement('a');
      a.href = URL.createObjectURL(blob);
      a.download = 'morrow-drafts.json';
      document.body.appendChild(a);
      a.click();
      a.remove();
      setTimeout(function () {
        URL.revokeObjectURL(a.href);
      }, 1000);
    } catch (_) { /* 下载失败不阻断登出 */ }
  }

  async function doLogout() {
    Morrow.ui.setSyncStatus('syncing', '正在退出…');
    await Morrow.transport.logout();
    Morrow.ui.setSyncStatus('none', '');
    Morrow.ui.showLoginPanel('');
  }

  function bindLoginForm() {
    const form = document.getElementById('login-form');
    if (!form) return; // 当前面板不是登录面板
    form.addEventListener('submit', async function (ev) {
      ev.preventDefault();
      const email = document.getElementById('login-email').value;
      const password = document.getElementById('login-password').value;
      Morrow.ui.setLoginBusy(true);
      Morrow.ui.setSyncStatus('syncing', '正在登录…');
      const res = await Morrow.transport.login(email, password);
      if (res.ok) {
        const verify = await Morrow.transport.verifyOwner();
        if (verify.ok) {
          markSynced();
          Morrow.ui.showShellPanel(res.user);
          bindLogout();
          return;
        }
        // 登录成功但权威校验失败（网络/owner）按失败面板处理
        Morrow.ui.setLoginBusy(false);
        Morrow.ui.setSyncStatus('failed', '同步失败');
        Morrow.ui.showFailure(verify.error.kind === 'owner_denied' ? 'config' : 'network', verify.error.text, {
          title: '登录后校验失败',
          staleSnapshotAt: lastSyncStamp(),
          onPrimary: function () {
            authCheck();
          },
        });
        return;
      }
      Morrow.ui.setLoginBusy(false);
      Morrow.ui.setSyncStatus('failed', '登录失败');
      Morrow.ui.showLoginPanel(res.error.text);
    });
  }

  // 登录面板每次重渲染后需要重新绑定提交 → 用 MutationObserver 兜底绑定。
  function watchLoginForm() {
    const host = document.getElementById('panel-host');
    if (!host || typeof MutationObserver === 'undefined') return;
    const observer = new MutationObserver(function () {
      if (document.getElementById('login-form')) bindLoginForm();
    });
    observer.observe(host, { childList: true });
  }

  async function boot() {
    const release = releaseInfo();
    // 版本帧 + 旧发行检测（stale 快照防线 1：版本不一致即提示）
    const seen = readJson(RELEASE_KEY);
    Morrow.ui.renderVersionFrame(release, seen && seen.id);
    writeJson(RELEASE_KEY, { id: release.id });

    // 存储探针先行（file:// 能力差异必须可见）
    const probe = await Morrow.storage.probe();
    Morrow.ui.renderStorageLine(probe);

    watchLoginForm();

    // 一次性 URL 配置注入（测试 hook）
    Morrow.config.consumeQueryParams();

    const cfg = Morrow.config.load();
    if (!cfg) {
      Morrow.ui.setSyncStatus('none', '未配置');
      showConfigThenAuth();
      return;
    }
    bootWithConfig(cfg);
  }

  function installGlobalGuards() {
    window.addEventListener('error', function (ev) {
      // 已渲染失败面板时不重复覆盖（避免与业务错误竞争）
      if (document.querySelector('.panel-failure')) return;
      Morrow.ui.showFailure('internal', '页面发生内部异常：' + (ev && ev.message ? ev.message : '未知错误'), {
        title: '内部异常',
      });
    });
    window.addEventListener('unhandledrejection', function (ev) {
      if (document.querySelector('.panel-failure')) return;
      const reason = ev && ev.reason;
      Morrow.ui.showFailure('internal', '异步操作发生未处理异常：' + (reason && reason.message ? reason.message : '未知错误'), {
        title: '内部异常',
      });
    });
  }

  Morrow.app = { boot: boot };
  Morrow.APP_RELEASE_KEYS = { RELEASE_KEY: RELEASE_KEY, LAST_SYNC_KEY: LAST_SYNC_KEY };

  installGlobalGuards();
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () {
      boot().catch(function () {
        Morrow.ui.showFailure('internal', '启动失败，请重新加载');
      });
    });
  } else {
    boot().catch(function () {
      Morrow.ui.showFailure('internal', '启动失败，请重新加载');
    });
  }
})();
