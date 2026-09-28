/* Morrow 近 30 天热力图（MVP-004）：次要位置低权重组件。
 * 数据契约：get_anchor_history_v1 投影（C-03）；前端零业务计算——
 *   连续天数 / 记录率 / 达标率 / 逐日状态全部渲染 Core 输出，前端不做任何统计推导。
 * 色弱可读：所有颜色状态配文字（legend + 每格 aria-label/title）；未开始=虚格、
 *   未记录=灰、部分记录=半填、记全有未达标=暖色描边、全达标=暖色实底、今日/在途=蓝框。
 * 不建泛 Dashboard；不请求未来日期（from/to 以 context 的工作区今日为界）。
 */
(function () {
  'use strict';
  const Morrow = (window.Morrow = window.Morrow || {});

  const DAY_TYPE_LABEL = {
    ordinary_workday: '普通工作日',
    workout_workday: '训练工作日',
    weekend: '周末',
    weekend_workout: '周末训练日',
  };

  function esc(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  // 工作区日历日（YYYY-MM-DD 字符串）±n 天：纯日期串换算（UTC 防设备时区漂移），业务日期仍以 Core 为准
  function addDays(bizDate, n) {
    const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(bizDate || ''));
    if (!m) return bizDate;
    const d = new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3])));
    d.setUTCDate(d.getUTCDate() + n);
    return d.toISOString().slice(0, 10);
  }

  // 展示用百分比格式化（Core 返回 0..1 numeric 或 null；不算率，只换显示形式）
  function pct(rate) {
    if (rate == null) return '—';
    const n = Number(rate);
    if (!isFinite(n)) return '—';
    return Math.round(n * 100) + '%';
  }

  // 逐格状态：全部字段来自 Core 投影（not_started / denominator / recorded_count / met_count）
  function cellState(d) {
    if (d.not_started) return 'notstarted';
    const den = Number(d.denominator) || 0;
    const rec = Number(d.recorded_count) || 0;
    const met = Number(d.met_count) || 0;
    if (rec <= 0) return 'empty';
    if (den > 0 && rec >= den) return met >= den ? 'full-met' : 'full-unmet';
    return 'partial';
  }

  // 每格文字补充（aria-label + title）：颜色不承担唯一信息通道
  function ariaText(d, state) {
    const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(d.biz_date || ''));
    const dateLabel = m ? Number(m[2]) + '月' + Number(m[3]) + '日' : String(d.biz_date || '');
    const dtLabel = DAY_TYPE_LABEL[d.day_type_code] || '';
    let body;
    if (state === 'notstarted') {
      body = '跟踪未开始';
    } else if (state === 'empty') {
      body = '未记录（漏记或未访问）';
    } else if (state === 'partial') {
      body = '部分记录：已记 ' + d.recorded_count + '/' + d.denominator + ' 项，达标 ' + d.met_count + ' 项';
    } else if (state === 'full-met') {
      body = '全部 ' + d.denominator + ' 项已记录且达标';
    } else {
      body = '全部 ' + d.denominator + ' 项已记录，达标 ' + d.met_count + ' 项';
    }
    let suffix = '';
    if (d.is_today) suffix += '，今日';
    if (d.provisional) suffix += '，在途未结算';
    return dateLabel + (dtLabel ? ' ' + dtLabel : '') + '：' + body + suffix;
  }

  function cellHtml(d) {
    const state = cellState(d);
    const cls = ['hm-cell', 'hm-s-' + state];
    if (d.is_today) cls.push('hm-today');
    if (d.provisional) cls.push('hm-provisional');
    const label = ariaText(d, state);
    const dayNum = state === 'notstarted' ? '' : String(Number(String(d.biz_date).slice(8, 10)));
    return (
      '<li class="' + cls.join(' ') + '" data-testid="hm-day-' + esc(d.biz_date) + '"' +
      ' role="img" aria-label="' + esc(label) + '" title="' + esc(label) + '">' +
      '<span class="hm-daynum" aria-hidden="true">' + esc(dayNum) + '</span></li>'
    );
  }

  function render(host, data) {
    const days = (data && data.days) || [];
    const stats = (data && data.stats) || {};
    const html = [];
    html.push('<section class="heatmap" data-testid="heatmap30" aria-label="近 30 天记录统计">');
    html.push(
      '<header class="hm-head">' +
        '<h3 class="hm-title">近 30 天</h3>' +
        '<p class="hm-stats" data-testid="hm-stats-line">' +
          '连续记录 <strong data-testid="hm-streak">' + esc(stats.streak_days == null ? 0 : stats.streak_days) + '</strong> 天' +
          '<span class="hm-sep" aria-hidden="true">·</span>' +
          '记录率 <strong data-testid="hm-recording-rate">' + esc(pct(stats.recording_rate)) + '</strong>' +
          '<span class="hm-sep" aria-hidden="true">·</span>' +
          '达标率 <strong data-testid="hm-met-rate">' + esc(pct(stats.met_rate)) + '</strong>' +
        '</p>' +
      '</header>'
    );
    // F12：今日在途不归零，也不提前 +1——说明文案如实告知
    if (stats.today_provisional === true && stats.today_complete !== true) {
      html.push('<p class="hm-note" data-testid="hm-provisional-note">今日仍在途：完成今日全部记录后，连续天数 +1。</p>');
    }
    html.push('<ol class="hm-grid">');
    days.forEach(function (d) { html.push(cellHtml(d)); });
    html.push('</ol>');
    // 图例：每个色态配文字（色弱可读硬要求）
    html.push(
      '<ul class="hm-legend">' +
        '<li><span class="hm-swatch hm-s-full-met" aria-hidden="true"></span>全记录且达标</li>' +
        '<li><span class="hm-swatch hm-s-full-unmet" aria-hidden="true"></span>记全·有未达标</li>' +
        '<li><span class="hm-swatch hm-s-partial" aria-hidden="true"></span>部分记录</li>' +
        '<li><span class="hm-swatch hm-s-empty" aria-hidden="true"></span>未记录</li>' +
        '<li><span class="hm-swatch hm-s-notstarted" aria-hidden="true"></span>未开始</li>' +
        '<li><span class="hm-swatch hm-swatch-today" aria-hidden="true"></span>今日 / 在途</li>' +
      '</ul>'
    );
    // F14：迟到计入记录率、不计达标率——有迟到记录时如实标注
    if (Number(stats.recorded_late_count) > 0) {
      html.push(
        '<p class="hm-note" data-testid="hm-late-note">含迟到记录 ' + esc(stats.recorded_late_count) +
        ' 次：迟到计入记录率，不计入达标率。</p>'
      );
    }
    html.push('</section>');
    host.innerHTML = html.join('');
  }

  // 挂载：bizDate 为 context 投影的工作区今日；失败不打扰今日主区（独立错误块 + 重试）
  async function mount(host, bizDate) {
    if (!host || !bizDate) return;
    host.innerHTML =
      '<section class="heatmap" aria-label="近 30 天记录统计">' +
      '<p class="hm-note">加载近 30 天记录…</p></section>';
    let res;
    try {
      res = await Morrow.transport.rpc('get_anchor_history_v1', {
        from: addDays(bizDate, -29),
        to: bizDate,
      });
    } catch (e) {
      res = { ok: false, error: { text: (e && e.message) || '网络异常' } };
    }
    if (!res.ok) {
      host.innerHTML =
        '<section class="heatmap" aria-label="近 30 天记录统计">' +
        '<p class="hm-error" role="alert" data-testid="hm-error">近 30 天统计加载失败：' +
        esc((res.error && res.error.text) || '未知错误') + '</p>' +
        '<div><button type="button" class="btn-secondary hm-retry">重试</button></div></section>';
      const btn = host.querySelector('.hm-retry');
      if (btn) btn.addEventListener('click', function () { mount(host, bizDate); });
      return;
    }
    render(host, res.result);
  }

  Morrow.heatmap = { mount: mount };
})();
