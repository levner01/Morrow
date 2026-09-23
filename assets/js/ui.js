/* Morrow 渲染层（P0-006）：面板渲染、三态同步标识、版本帧、存储探针行、草稿登出对话。
 * 只渲染 Morrow.app 给的状态；不直接调 transport / SDK。
 * 同步状态严格三态（C-07）：已同步 / 同步中 / 同步失败·重试（时间戳为辅助说明）。
 */
(function () {
  'use strict';
  const Morrow = (window.Morrow = window.Morrow || {});

  const SYNC_LABELS = {
    synced: '已同步',
    syncing: '同步中',
    failed: '同步失败·重试',
    none: '未同步',
  };

  function el(id) {
    return document.getElementById(id);
  }

  function setText(id, text) {
    const node = el(id);
    if (node) node.textContent = text;
  }

  function setSyncStatus(state, detailText) {
    const badge = el('sync-badge');
    if (!badge) return;
    badge.dataset.state = state;
    badge.textContent = SYNC_LABELS[state] || SYNC_LABELS.none;
    setText('sync-detail', detailText || '');
  }

  // 版本帧：显示当前发行标识；若本机存储的发行标识不同 → 旧快照警告（防 stale 数据陷阱）。
  function renderVersionFrame(release, storedReleaseId) {
    setText('release-id', release.id);
    setText('release-sdk', 'supabase-js ' + release.sdk.version);
    const banner = el('stale-release-banner');
    if (storedReleaseId && storedReleaseId !== release.id) {
      banner.hidden = false;
      setText('stale-release-text', '检测到本机缓存来自旧发行（' + storedReleaseId + '），旧快照数据仅供参考，请以重新同步后的数据为准。');
    } else {
      banner.hidden = true;
    }
  }

  function renderStorageLine(probe) {
    const ls = probe.localStorage === 'ok' ? '可用' : '不可用';
    const idb = probe.indexedDB === 'ok' ? '可用' : probe.indexedDB === 'blocked' ? '被阻塞' : '不可用';
    const limited = probe.localStorage !== 'ok' || probe.indexedDB !== 'ok';
    const line = el('storage-line');
    if (line) {
      line.dataset.limited = limited ? 'true' : 'false';
      line.textContent =
        '本地存储探针（' + probe.origin + ' origin）：localStorage ' + ls + ' · IndexedDB ' + idb +
        (limited ? ' —— 浏览器本地存储能力受限，数据可能不能多机进行，但可以登录会话；草稿请用「下载草稿」另存。' : '');
    }
  }

  // 通用失败面板：可理解文案 + 主按钮（重试 / 检查配置 / 重新加载按 kind 决定）。
  function showFailure(kind, text, options) {
    const opts = options || {};
    const host = el('panel-host');
    const staleTime = opts.staleSnapshotAt ? '（最后成功同步：' + opts.staleSnapshotAt + '）' : '';
    const primaryLabel = kind === 'config' ? '检查配置' : kind === 'internal' ? '重新加载' : '重试';
    host.innerHTML =
      '<section class="panel panel-failure" role="alert" data-testid="failure-panel" data-kind="' + kind + '">' +
      '  <h2>' + escapeHtml(opts.title || '出错了') + '</h2>' +
      '  <p class="failure-text">' + escapeHtml(text) + escapeHtml(staleTime) + '</p>' +
      (opts.hint ? '<p class="failure-hint">' + escapeHtml(opts.hint) + '</p>' : '') +
      '  <div class="panel-actions">' +
      '    <button type="button" id="failure-primary" class="btn-primary">' + escapeHtml(primaryLabel) + '</button>' +
      '  </div>' +
      '</section>';
    el('failure-primary').addEventListener('click', function () {
      if (kind === 'internal') {
        window.location.reload();
      } else if (typeof opts.onPrimary === 'function') {
        opts.onPrimary();
      }
    });
  }

  function showResourceFailure() {
    showFailure('resource', '页面资源加载失败（脚本或样式被拦截/损坏）。请检查网络后重试，或使用本地 loopback 方式访问同一发行文件。', {
      title: '资源加载失败',
      onPrimary: function () {
        window.location.reload();
      },
    });
  }

  function showConfigPanel(problems, onSaved) {
    const host = el('panel-host');
    host.innerHTML =
      '<section class="panel" data-testid="config-panel">' +
      '  <h2>连接配置</h2>' +
      '  <p class="panel-note">首次使用：请输入 Supabase 项目地址与 publishable key。两者只保存在本机浏览器存储，不会写入页面文件或日志。</p>' +
      (problems && problems.length
        ? '<ul class="problem-list" data-testid="config-problems">' + problems.map(function (p) {
            return '<li>' + escapeHtml(p) + '</li>';
          }).join('') + '</ul>'
        : '') +
      '  <form id="config-form" novalidate>' +
      '    <label for="cfg-url">项目地址</label>' +
      '    <input id="cfg-url" name="url" type="url" autocomplete="off" spellcheck="false" placeholder="https://<project-ref>.supabase.co">' +
      '    <label for="cfg-key">Publishable key</label>' +
      '    <input id="cfg-key" name="key" type="text" autocomplete="off" spellcheck="false" placeholder="sb_publishable_...">' +
      '    <div class="panel-actions"><button type="submit" class="btn-primary">保存并继续</button></div>' +
      '  </form>' +
      '</section>';
    el('config-form').addEventListener('submit', function (ev) {
      ev.preventDefault();
      const url = el('cfg-url').value.trim();
      const key = el('cfg-key').value.trim();
      const errs = Morrow.config.validate(url, key);
      if (errs.length > 0) {
        showConfigPanel(errs, onSaved);
        return;
      }
      Morrow.config.save({ url: url, key: key });
      if (typeof onSaved === 'function') onSaved({ url: url, key: key });
    });
  }

  function showLoginPanel(errorText) {
    const host = el('panel-host');
    host.innerHTML =
      '<section class="panel" data-testid="login-panel">' +
      '  <h2>登录 Morrow</h2>' +
      '  <p class="panel-note">仅工作区 owner 可登录。密码不会写入任何日志、导出或页面文件。</p>' +
      (errorText ? '<p class="form-error" role="alert" data-testid="login-error">' + escapeHtml(errorText) + '</p>' : '') +
      '  <form id="login-form" novalidate>' +
      '    <label for="login-email">邮箱</label>' +
      '    <input id="login-email" name="email" type="email" autocomplete="username" required>' +
      '    <label for="login-password">密码</label>' +
      '    <input id="login-password" name="password" type="password" autocomplete="current-password" required>' +
      '    <div class="panel-actions"><button type="submit" class="btn-primary" id="login-submit">登录</button></div>' +
      '  </form>' +
      '</section>';
  }

  function setLoginBusy(busy) {
    const btn = el('login-submit');
    if (!btn) return;
    btn.disabled = busy;
    btn.textContent = busy ? '登录中…' : '登录';
  }

  // 登录成功后的业务壳（MVP-002 起）：账号/登出/版本帧保留，今日页渲染进 today-host。
  function showShellPanel(user) {
    const host = el('panel-host');
    host.innerHTML =
      '<section class="panel panel-shell" data-testid="shell-panel">' +
      '  <div class="shell-head">' +
      '    <p class="shell-account">' + escapeHtml(user.email || user.id) + '</p>' +
      '    <button type="button" id="logout-btn" class="btn-secondary">退出登录</button>' +
      '  </div>' +
      '  <div id="today-host" class="today-host" aria-live="polite"></div>' +
      '</section>';
    if (Morrow.today && typeof Morrow.today.start === 'function') {
      Morrow.today.start();
    }
  }

  // 登出草稿处理（失败矩阵：不默默擦除）：下载 / 保留在本机 / 删除并退出。
  function showDraftLogoutDialog(count, actions) {
    const host = el('panel-host');
    host.innerHTML =
      '<section class="panel" data-testid="draft-dialog">' +
      '  <h2>检测到 ' + count + ' 条未同步草稿</h2>' +
      '  <p class="panel-note">退出登录不会替你做决定，请选择草稿处理方式。</p>' +
      '  <div class="panel-actions">' +
      '    <button type="button" id="draft-download" class="btn-primary">下载草稿（JSON）</button>' +
      '    <button type="button" id="draft-keep" class="btn-secondary">保留在本机</button>' +
      '    <button type="button" id="draft-wipe" class="btn-danger">删除草稿并退出</button>' +
      '  </div>' +
      '</section>';
    el('draft-download').addEventListener('click', actions.onDownload);
    el('draft-keep').addEventListener('click', actions.onKeep);
    el('draft-wipe').addEventListener('click', actions.onWipe);
  }

  function escapeHtml(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function formatStamp(iso) {
    try {
      const d = new Date(iso);
      return isNaN(d.getTime()) ? '' : d.toLocaleString('zh-CN', { hour12: false });
    } catch (_) {
      return '';
    }
  }

  Morrow.ui = {
    setSyncStatus: setSyncStatus,
    renderVersionFrame: renderVersionFrame,
    renderStorageLine: renderStorageLine,
    showFailure: showFailure,
    showResourceFailure: showResourceFailure,
    showConfigPanel: showConfigPanel,
    showLoginPanel: showLoginPanel,
    setLoginBusy: setLoginBusy,
    showShellPanel: showShellPanel,
    showDraftLogoutDialog: showDraftLogoutDialog,
    formatStamp: formatStamp,
  };
})();
