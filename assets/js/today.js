/* Morrow 今日行动页（MVP-002）：三锚点主导的单主轴页面。
 * 数据契约：get_today_context_v1 投影（C-02/C-03）；写操作 check/clear/set_day_type 全走 Morrow.transport.rpc。
 * 前端零业务计算：target_met / interval_met / deviation / stats / next_action 一律渲染 Core 投影。
 * 有限 optimistic：提交后行内 pending（"已提交待确认"），以 RPC 返回 + 重载 context 为准。
 */
(function () {
  'use strict';
  const Morrow = (window.Morrow = window.Morrow || {});
  const DEVICE_KEY = 'morrow.device.v1';

  const ANCHOR_LABEL = { wake: '起床', workout_end: '健身结束', lights_off: '关灯' };
  const ANCHOR_ORDER = ['wake', 'workout_end', 'lights_off'];
  const DAY_TYPE_OPTIONS = [
    { code: 'ordinary_workday', label: '普通工作日' },
    { code: 'workout_workday', label: '训练工作日' },
    { code: 'weekend', label: '周末' },
    { code: 'weekend_workout', label: '周末训练日' },
  ];
  const WEEKDAY_LABEL = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

  function el(id) {
    return document.getElementById(id);
  }

  function esc(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  // ISO → HH:MM（展示用；不用于业务判断）
  function fmtTime(iso) {
    if (!iso) return '';
    const m = String(iso).match(/T(\d{2}):(\d{2})/);
    return m ? m[1] + ':' + m[2] : '';
  }

  // 目标时间 → HH:MM（target_at 或 target_local_time 均可）
  function fmtTarget(anchor, dayType) {
    if (anchor.target_at) return fmtTime(anchor.target_at);
    const spec = (dayType.anchors || []).find(function (a) { return a.type === anchor.anchor_type; });
    return spec && spec.target_local_time ? spec.target_local_time : '';
  }

  // 从 context 的工作区时区偏移（target_at 已带偏移，如 +08:00）；拼到 datetime-local 输入值后形成 actual_at。
  function tzOffset(ctx) {
    const probe = (ctx.anchors && ctx.anchors[0] && ctx.anchors[0].target_at) || '';
    const m = String(probe).match(/([+-]\d{2}:\d{2})$/);
    return m ? m[1] : '+08:00';
  }

  // datetime-local 值（YYYY-MM-DDTHH:MM）→ 带工作区偏移的 ISO 字符串
  function toActualAt(localValue, ctx) {
    if (!localValue) return null;
    return localValue + ':00' + tzOffset(ctx);
  }

  function getDeviceId() {
    try {
      let id = window.localStorage.getItem(DEVICE_KEY);
      if (!id) {
        id = 'web-' + window.crypto.randomUUID();
        window.localStorage.setItem(DEVICE_KEY, id);
      }
      return id;
    } catch (_) {
      return 'web-anon-' + Math.random().toString(36).slice(2);
    }
  }

  function setBusy(busy) {
    const host = el('today-host');
    if (host) host.setAttribute('aria-busy', busy ? 'true' : 'false');
  }

  function showError(text) {
    const box = el('today-error');
    if (!box) return;
    box.textContent = text || '';
    box.hidden = !text;
  }

  // ---------- 数据加载 ----------
  async function loadContext() {
    const res = await Morrow.transport.rpc('get_today_context_v1', {});
    return res;
  }

  async function reload() {
    setBusy(true);
    showError('');
    const res = await loadContext();
    setBusy(false);
    if (!res.ok) {
      showError(res.error.text || '加载今日上下文失败');
      return;
    }
    renderToday(res.result);
  }

  // ---------- 今日页渲染 ----------
  function renderToday(ctx) {
    const host = el('today-host');
    if (!host) return;
    const dt = ctx.day_type || {};
    const next = ctx.next_action;
    const html = [];
    html.push('<div class="today" data-testid="today-page">');
    // 主轴 1：日期 + 日型（唯一主页面标题）
    html.push(
      '<header class="today-header">' +
        '<h2 class="today-date">' + esc(fmtDateHeader(ctx.biz_date)) + '</h2>' +
        '<p class="today-daytype">' +
          '<span class="daytype-name">' + esc(dt.name || dt.code || '') + '</span>' +
          (dt.workout_expected ? '<span class="daytype-tag daytype-tag-workout">训练日</span>' : '') +
        '</p>' +
      '</header>'
    );
    html.push('<div class="today-error" id="today-error" role="alert" hidden></div>');

    // 主轴 2：三锚点（固定顺序；n/a 弱化但保留）
    html.push('<ol class="anchor-list" data-testid="anchor-list">');
    (ctx.anchors || []).forEach(function (a) {
      html.push(anchorRowHtml(a, dt));
    });
    html.push('</ol>');

    // 主轴 3：唯一下一步（无建议时整块不渲染）
    if (next && next.kind) {
      html.push(nextActionHtml(next));
    }

    // 日型切换入口（仅今日；无未来日期导航）
    html.push(
      '<div class="daytype-actions">' +
        '<button type="button" id="daytype-change-btn" class="btn-secondary btn-today-secondary">更改今日日型</button>' +
      '</div>'
    );
    html.push('</div>');
    host.innerHTML = html.join('');

    bindToday(ctx);
  }

  function fmtDateHeader(bizDate) {
    // biz_date（YYYY-MM-DD，工作区日历日）→ 中文短日期；不依赖设备时区换算
    const m = String(bizDate || '').match(/^(\d{4})-(\d{2})-(\d{2})$/);
    if (!m) return bizDate || '';
    return m[1] + '年' + Number(m[2]) + '月' + Number(m[3]) + '日';
  }

  // 锚点行：目标 / 实际 / 状态 三列对齐；实际与目标状态分离显示。
  function anchorRowHtml(a, dt) {
    const label = ANCHOR_LABEL[a.anchor_type] || a.anchor_type;
    const target = fmtTarget(a, dt);
    const na = a.planned === false || a.status === 'not_applicable';
    const recorded = a.status === 'recorded' && a.actual_at;
    const rowClass = 'anchor-row' + (na ? ' anchor-row-na' : '') + (recorded ? ' anchor-row-recorded' : '');
    const targetLabel = na ? '今日无计划' : target;

    // 实际列：主信息为实际时间；target_met 单独小字（Core 投影，前端不算）
    let actualHtml;
    if (recorded) {
      let metNote = '';
      if (a.target_met === true) metNote = '<span class="anchor-met anchor-met-yes">达标</span>';
      else if (a.target_met === false) metNote = '<span class="anchor-met anchor-met-no">未达标</span>';
      let intervalNote = '';
      if (a.anchor_type === 'workout_end' && a.interval_met != null) {
        intervalNote =
          '<span class="anchor-interval">' +
          (a.interval_met ? '间隔达标' : '间隔未达标') +
          (a.interval_to_lights_off_minutes != null ? ' · 距关灯 ' + a.interval_to_lights_off_minutes + ' 分钟' : '') +
          '</span>';
      }
      actualHtml =
        '<span class="anchor-actual-time">' + esc(fmtTime(a.actual_at)) + '</span>' +
        (a.deviation_minutes != null ? '<span class="anchor-deviation">偏差 ' + signed(a.deviation_minutes) + ' 分钟</span>' : '') +
        metNote + intervalNote;
    } else {
      actualHtml = '<span class="anchor-actual-empty">' + (na ? '—' : '未记录') + '</span>';
    }

    // 操作列
    let actions = '';
    if (na) {
      actions = '<span class="anchor-na-note">今日无训练计划</span>';
    } else if (recorded) {
      actions =
        '<button type="button" class="btn-row" data-act="edit" data-anchor="' + a.anchor_type + '">修正时间</button>' +
        '<button type="button" class="btn-row btn-row-danger" data-act="clear" data-anchor="' + a.anchor_type + '">清空</button>';
    } else {
      actions = '<button type="button" class="btn-row btn-row-primary" data-act="check" data-anchor="' + a.anchor_type + '">打卡</button>';
    }

    return (
      '<li class="' + rowClass + '" data-anchor="' + a.anchor_type + '" data-testid="anchor-' + a.anchor_type + '">' +
        '<div class="anchor-col anchor-col-name"><span class="anchor-name">' + esc(label) + '</span></div>' +
        '<div class="anchor-col anchor-col-target"><span class="anchor-label">目标</span><span class="anchor-value">' + esc(targetLabel) + '</span></div>' +
        '<div class="anchor-col anchor-col-actual"><span class="anchor-label">实际</span><span class="anchor-value">' + actualHtml + '</span></div>' +
        '<div class="anchor-col anchor-col-status"><span class="anchor-label">状态</span><span class="anchor-value">' + statusText(a, na, recorded) + '</span></div>' +
        '<div class="anchor-col anchor-col-actions">' + actions + '</div>' +
      '</li>'
    );
  }

  function signed(n) {
    return n > 0 ? '+' + n : String(n);
  }

  function statusText(a, na, recorded) {
    if (na) return '<span class="status-na">n/a</span>';
    if (a.materialized === false && !recorded) return '<span class="status-pending">待记录</span>';
    if (recorded) return '<span class="status-recorded">已记录</span>';
    return '<span class="status-pending">待记录</span>';
  }

  function nextActionHtml(next) {
    const label = ANCHOR_LABEL[next.anchor_type];
    let text = '';
    if (next.kind === 'record_anchor' && label) {
      text = '记录' + label;
    } else if (next.kind === 'day_complete') {
      text = '今日记录已完成';
    } else {
      return ''; // 未知 kind 视为无建议：不渲染占位
    }
    const overdue = next.overdue ? '<span class="next-overdue">已过时，可补记</span>' : '';
    return (
      '<section class="next-action" data-testid="next-action" aria-label="下一步">' +
        '<h3 class="next-title">下一步</h3>' +
        '<p class="next-text">' + esc(text) + '</p>' + overdue +
      '</section>'
    );
  }

  // ---------- 交互绑定 ----------
  function bindToday(ctx) {
    const host = el('today-host');
    host.querySelectorAll('[data-act]').forEach(function (btn) {
      btn.addEventListener('click', function () {
        const type = btn.getAttribute('data-anchor');
        const act = btn.getAttribute('data-act');
        if (act === 'check') openCheckEditor(ctx, type, false);
        else if (act === 'edit') openCheckEditor(ctx, type, true);
        else if (act === 'clear') confirmClear(ctx, type);
      });
    });
    const dtBtn = el('daytype-change-btn');
    if (dtBtn) dtBtn.addEventListener('click', function () { openDayTypeChange(ctx); });
  }

  // 打卡 / 修正共用：datetime-local 编辑（默认当下，可改）；修正语境下预填当前实际值。
  function openCheckEditor(ctx, anchorType, isEdit) {
    const a = (ctx.anchors || []).find(function (x) { return x.anchor_type === anchorType; });
    const label = ANCHOR_LABEL[anchorType] || anchorType;
    const defaultValue = isEdit && a.actual_at ? a.actual_at.slice(0, 16) : nowLocal(ctx);
    openDialog({
      title: (isEdit ? '修正' : '记录') + label + '时间',
      bodyHtml:
        '<label class="field-label" for="check-time">' + (isEdit ? '修正为' : '实际时间') + '</label>' +
        '<input type="datetime-local" id="check-time" class="field-input" value="' + esc(defaultValue) + '" step="60">',
      primaryLabel: isEdit ? '确认修正' : '确认打卡',
      onPrimary: async function () {
        const v = el('check-time').value;
        if (!v) { showError('请选择时间'); return false; }
        return submitCheck(ctx, anchorType, toActualAt(v, ctx), isEdit);
      },
    });
    setTimeout(function () { const t = el('check-time'); if (t) t.focus(); }, 0);
  }

  function nowLocal(ctx) {
    // 用 server 侧 biz_date + 浏览器当前时分合成（工作区日历日由 Core 定，时分取当下）
    const d = new Date();
    const hh = String(d.getHours()).padStart(2, '0');
    const mm = String(d.getMinutes()).padStart(2, '0');
    return ctx.biz_date + 'T' + hh + ':' + mm;
  }

  async function submitCheck(ctx, anchorType, actualAt, isEdit) {
    markPending(anchorType, isEdit ? '正在修正…' : '已提交待确认…');
    const res = await Morrow.transport.rpc('check_anchor_v1', {
      biz_date: ctx.biz_date,
      anchor_type: anchorType,
      actual_at: actualAt,
      note: '',
    });
    if (!res.ok) {
      clearPending(anchorType);
      showError((isEdit ? '修正失败：' : '打卡失败：') + (res.error.text || '未知错误'));
      return false; // 对话框保持打开，错误已显示
    }
    await reload();
    return true;
  }

  function confirmClear(ctx, anchorType) {
    const label = ANCHOR_LABEL[anchorType] || anchorType;
    openDialog({
      title: '清空' + label + '记录？',
      bodyHtml: '<p class="dialog-note">只清除实际记录，今日计划与记录分母保持不变。</p>',
      primaryLabel: '确认清空',
      danger: true,
      onPrimary: async function () {
        markPending(anchorType, '正在清空…');
        const res = await Morrow.transport.rpc('clear_anchor_v1', {
          biz_date: ctx.biz_date,
          anchor_type: anchorType,
        });
        if (!res.ok) {
          clearPending(anchorType);
          showError('清空失败：' + (res.error.text || '未知错误'));
          return false;
        }
        await reload();
        return true;
      },
    });
  }

  // 日型切换：仅今日；locked-append 场景显式确认文案；DAY_PLAN_LOCKED 如实展示。
  function openDayTypeChange(ctx) {
    const dt = ctx.day_type || {};
    const current = dt.code;
    const locked = dt.plan_locked === true;
    const options = DAY_TYPE_OPTIONS.map(function (o) {
      return '<label class="radio-option"><input type="radio" name="daytype-opt" value="' + o.code + '"' +
        (o.code === current ? ' checked' : '') + '> ' + o.label + '</label>';
    }).join('');
    openDialog({
      title: '更改今日日型',
      bodyHtml:
        '<p class="dialog-note">仅作用于今日（' + esc(ctx.biz_date) + '）。' +
        (locked ? '今日已有打卡记录：已锁计划只允许单向增加训练。' : '') + '</p>' +
        '<div class="radio-group" role="radiogroup" aria-label="日型">' + options + '</div>',
      primaryLabel: '确认更改',
      onPrimary: async function () {
        const sel = document.querySelector('input[name="daytype-opt"]:checked');
        if (!sel) { showError('请选择日型'); return false; }
        const code = sel.value;
        if (code === current) return true; // 无变化直接关闭
        // 已锁 + 追加训练场景：显式确认文案（C-02 §4 单向追加）
        const appendWorkout = locked && code === 'workout_workday' && dt.workout_expected !== true;
        if (appendWorkout) {
          return confirmAppendWorkout(ctx, code);
        }
        return submitDayType(ctx, code);
      },
    });
  }

  async function confirmAppendWorkout(ctx, code) {
    openDialog({
      title: '增加今日训练计划？',
      bodyHtml:
        '<p class="dialog-note">今日已有打卡记录，计划已锁定。增加训练将把健身结束纳入今日记录率，' +
        '既有锚点目标保持不变。</p>',
      primaryLabel: '增加今日训练计划并纳入记录率',
      onPrimary: function () { return submitDayType(ctx, code); },
    });
    return false; // 外层对话框流程转入本确认框
  }

  async function submitDayType(ctx, code) {
    const res = await Morrow.transport.rpc('set_day_type_v1', { biz_date: ctx.biz_date, code: code });
    if (!res.ok) {
      showError('更改日型失败：' + (res.error.text || '未知错误')); // DAY_PLAN_LOCKED 等如实展示
      return false;
    }
    await reload();
    return true;
  }

  // ---------- 对话框 ----------
  // 轻量对话框（MVP-002 范围内唯一模式交互；键盘 Esc 关闭、焦点管理见 accessibility-notes.md）
  let dialogCleanup = null;
  function openDialog(opts) {
    closeDialog();
    const wrap = document.createElement('div');
    wrap.className = 'dialog-backdrop';
    wrap.setAttribute('data-testid', 'today-dialog');
    wrap.innerHTML =
      '<div class="dialog" role="dialog" aria-modal="true" aria-label="' + esc(opts.title) + '">' +
        '<h3 class="dialog-title">' + esc(opts.title) + '</h3>' +
        '<div class="dialog-body">' + (opts.bodyHtml || '') + '</div>' +
        '<div class="dialog-actions">' +
          '<button type="button" class="btn-secondary" data-dialog="cancel">取消</button>' +
          '<button type="button" class="' + (opts.danger ? 'btn-danger' : 'btn-primary') + '" data-dialog="primary">' + esc(opts.primaryLabel || '确认') + '</button>' +
        '</div>' +
      '</div>';
    document.body.appendChild(wrap);
    const primaryBtn = wrap.querySelector('[data-dialog="primary"]');
    const cancelBtn = wrap.querySelector('[data-dialog="cancel"]');
    const prevFocus = document.activeElement;

    async function finish(result) {
      if (result === true) closeDialog();
      return result;
    }
    primaryBtn.addEventListener('click', async function () {
      primaryBtn.disabled = true;
      try {
        const r = await opts.onPrimary();
        primaryBtn.disabled = false;
        if (r === true) closeDialog();
      } catch (e) {
        primaryBtn.disabled = false;
        showError('操作失败：' + (e && e.message ? e.message : '未知错误'));
      }
    });
    cancelBtn.addEventListener('click', function () { closeDialog(); });
    wrap.addEventListener('click', function (ev) { if (ev.target === wrap) closeDialog(); });
    function onKey(ev) { if (ev.key === 'Escape') { ev.stopPropagation(); closeDialog(); } }
    document.addEventListener('keydown', onKey, true);

    dialogCleanup = function () {
      document.removeEventListener('keydown', onKey, true);
      if (prevFocus && prevFocus.focus) prevFocus.focus();
      wrap.remove();
      dialogCleanup = null;
    };
    setTimeout(function () { primaryBtn.focus(); }, 0);
  }

  function closeDialog() {
    if (dialogCleanup) dialogCleanup();
  }

  // ---------- pending 标记（有限 optimistic：只显示 pending，不预写实际值） ----------
  function markPending(anchorType, text) {
    const row = document.querySelector('[data-testid="anchor-' + anchorType + '"]');
    if (!row) return;
    row.classList.add('anchor-row-pending');
    const col = row.querySelector('.anchor-col-actions');
    if (col) col.innerHTML = '<span class="anchor-pending-note">' + esc(text) + '</span>';
  }

  function clearPending() {
    /* reload 后整表重建，无需恢复 */
  }

  // ---------- 初始向导（WORKSPACE_NOT_INITIALIZED 路径；新设备/新工作区可用） ----------
  function renderWizard() {
    const host = el('today-host');
    if (!host) return;
    host.innerHTML =
      '<section class="wizard" data-testid="init-wizard">' +
        '<h3 class="wizard-title">初始化工作区</h3>' +
        '<p class="dialog-note">首次使用需要两步设置：跟踪起始日 + 每周训练日。之后计划会按默认模板自动解析。</p>' +
        '<div class="wizard-step" data-step="1">' +
          '<label class="field-label" for="wiz-start">跟踪起始日</label>' +
          '<input type="date" id="wiz-start" class="field-input" value="' + esc(new Date().toISOString().slice(0, 10)) + '">' +
          '<div class="wizard-nav"><button type="button" id="wiz-next" class="btn-primary">下一步</button></div>' +
        '</div>' +
        '<div class="wizard-step" id="wiz-step2" data-step="2" hidden>' +
          '<p class="field-label">每周训练日（可多选）</p>' +
          '<div class="checkbox-group">' +
            WEEKDAY_LABEL.map(function (d, i) {
              const checked = i === 0 || i === 2 || i === 4 ? ' checked' : ''; // 默认一三五，用户显式可改
              return '<label class="checkbox-option"><input type="checkbox" class="wiz-wd" value="' + i + '"' + checked + '> ' + d + '</label>';
            }).join('') +
          '</div>' +
          '<div class="wizard-nav">' +
            '<button type="button" id="wiz-back" class="btn-secondary">上一步</button>' +
            '<button type="button" id="wiz-done" class="btn-primary">完成初始化</button>' +
          '</div>' +
        '</div>' +
        '<div class="today-error" id="today-error" role="alert" hidden></div>' +
      '</section>';
    el('wiz-next').addEventListener('click', function () {
      if (!el('wiz-start').value) { showError('请选择跟踪起始日'); return; }
      el('wiz-start').disabled = true;
      el('wiz-next').closest('.wizard-step').hidden = true;
      el('wiz-step2').hidden = false;
    });
    el('wiz-back').addEventListener('click', function () {
      el('wiz-step2').hidden = true;
      el('wiz-start').disabled = false;
      el('wiz-next').closest('.wizard-step').hidden = false;
    });
    el('wiz-done').addEventListener('click', async function () {
      const start = el('wiz-start').value;
      const codes = ['ordinary_workday', 'ordinary_workday', 'ordinary_workday', 'ordinary_workday', 'ordinary_workday', 'weekend', 'weekend'];
      document.querySelectorAll('.wiz-wd:checked').forEach(function (cb) {
        const i = Number(cb.value);
        codes[i] = i < 5 ? 'workout_workday' : 'weekend_workout';
      });
      const btn = el('wiz-done');
      btn.disabled = true;
      btn.textContent = '初始化中…';
      const res = await Morrow.transport.rpc('initialize_workspace_v1', {
        timezone: 'Asia/Shanghai',
        tracking_started_on: start,
        weekday_codes: codes,
      });
      if (!res.ok) {
        btn.disabled = false;
        btn.textContent = '完成初始化';
        showError('初始化失败：' + (res.error.text || '未知错误'));
        return;
      }
      await reload();
    });
  }

  // ---------- 入口 ----------
  async function start() {
    setBusy(true);
    const res = await loadContext();
    setBusy(false);
    if (!res.ok) {
      if (res.error && res.error.code === 'WORKSPACE_NOT_INITIALIZED') {
        renderWizard();
        return;
      }
      showError(res.error.text || '加载今日上下文失败');
      return;
    }
    renderToday(res.result);
    // record_open：辅助真实使用证据；device_id 仅去重标识，失败不打扰用户。
    Morrow.transport
      .rpc('record_open_v1', { device_id: getDeviceId(), biz_date: res.result.biz_date })
      .catch(function () { /* 辅助证据，静默 */ });
  }

  Morrow.today = { start: start, reload: reload, _renderWizard: renderWizard };
})();
