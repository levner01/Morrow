/* Morrow 三态同步 store（MVP-003）：server snapshot / per-record command / form draft 三类状态严格分离。
 * 合同依据：02-contracts.md C-07（页面状态机与草稿）、C-04（统一命令事务）。
 * 架构依据：01-architecture.md §6（Sync & Consistency）、§9（Failure & Recovery Matrix）。
 *
 * 核心纪律：
 * 1. server snapshot 只由成功读写更新，旧快照/本地草稿禁止冒充"已同步"。
 * 2. per-record command 单 flight 队列：同一 record 只有一个 in-flight，新意图等待前一 flight 返回。
 * 3. form draft 是未提交的编辑中表单，local 持久化，可失联保留。
 * 4. 同步文案严格三态：已同步 / 同步中 / 同步失败·重试。
 */
(function () {
  'use strict';
  const Morrow = (window.Morrow = window.Morrow || {});

  // ---------- 内部状态（三类分离，禁止互相冒充） ----------

  // 1. Server Snapshot：来自 get_today_context_v1 等只读返回（唯一权威数据源）
  let serverSnapshot = {
    context: null,           // get_today_context_v1 返回的完整投影
    dataRevision: '0',       // 服务端数据版本（BIGINT 字符串）
    lastSyncAt: null,        // 最后成功同步时间（ISO 8601）
    loaded: false,           // 是否已成功加载过至少一次
  };

  // 2. Per-Record Command 状态：单 flight 队列（同一 record 只有一个 in-flight）
  // key: `${biz_date}:${anchor_type}` 或 record_id
  const commands = new Map();

  // 3. Form Draft：未提交的编辑中表单（local，可失联保留）
  // key: `${biz_date}:${anchor_type}:${field}` (e.g., "2026-09-24:wake:note")
  const formDrafts = new Map();

  // ---------- 同步状态派生（三态：synced / syncing / failed） ----------

  function deriveSyncState() {
    let hasSending = false;
    let hasFailed = false;
    let hasUnknown = false;

    commands.forEach(function (cmd) {
      if (cmd.state === 'sending') hasSending = true;
      if (cmd.state === 'failed') hasFailed = true;
      if (cmd.state === 'unknown') hasUnknown = true;
    });

    // 有失败或未知 → failed（需要用户介入）
    if (hasFailed || hasUnknown) return 'failed';
    // 有发送中 → syncing
    if (hasSending) return 'syncing';
    // 无命令进行中 → synced
    return 'synced';
  }

  function getSyncState() {
    return deriveSyncState();
  }

  function getSyncDetail() {
    const state = deriveSyncState();
    if (state === 'synced' && serverSnapshot.lastSyncAt) {
      return '最后同步 ' + formatStamp(serverSnapshot.lastSyncAt);
    }
    if (state === 'syncing') {
      const sending = [];
      commands.forEach(function (cmd, key) {
        if (cmd.state === 'sending') sending.push(key);
      });
      return sending.length > 0 ? '正在同步 ' + sending.join(', ') : '正在同步…';
    }
    if (state === 'failed') {
      const failed = [];
      commands.forEach(function (cmd, key) {
        if (cmd.state === 'failed' || cmd.state === 'unknown') failed.push(key);
      });
      return failed.length > 0 ? '同步失败：' + failed.join(', ') : '同步失败';
    }
    return '';
  }

  // ---------- Server Snapshot 管理 ----------

  function setServerSnapshot(context, dataRevision) {
    serverSnapshot = {
      context: context,
      dataRevision: String(dataRevision || '0'),
      lastSyncAt: new Date().toISOString(),
      loaded: true,
    };
    notifyStateChange();
  }

  function getServerSnapshot() {
    return {
      context: serverSnapshot.context,
      dataRevision: serverSnapshot.dataRevision,
      lastSyncAt: serverSnapshot.lastSyncAt,
      loaded: serverSnapshot.loaded,
    };
  }

  // 旧慢读不盖新写：response 返回时若 data_revision 比现有渲染的旧，按 server snapshot 处理
  function shouldAcceptSnapshot(incomingRevision) {
    const incoming = parseInt(incomingRevision, 10);
    const current = parseInt(serverSnapshot.dataRevision, 10);
    // 版本更低 → 旧值，不覆盖 newer local
    return incoming >= current;
  }

  // ---------- Per-Record Command 状态机（单 flight 队列） ----------

  function getCommandKey(bizDate, anchorType) {
    return bizDate + ':' + anchorType;
  }

  function getCommand(recordKey) {
    return commands.get(recordKey) || null;
  }

  // 提交命令（单 flight：同一 record 的新意图等待前一 flight 返回）
  async function submitCommand(recordKey, commandFn, input, options) {
    const opts = options || {};
    const existing = commands.get(recordKey);

    // 如果前一 flight 还在 pending——等它返回再发（M1 不排队批量）
    if (existing && existing.state === 'sending' && existing.promise) {
      try {
        await existing.promise;
      } catch (_) {
        // 前一 flight 失败也继续发送新意图
      }
    }

    // 生成幂等键（如果未提供）
    const idempotencyKey = opts.idempotencyKey || window.crypto.randomUUID();

    // 创建 command 记录
    const cmd = {
      state: 'sending',
      idempotency_key: idempotencyKey,
      input: input,
      sentAt: new Date().toISOString(),
      error: null,
      promise: null,
    };
    commands.set(recordKey, cmd);
    notifyStateChange();

    // 执行命令
    const promise = (async function () {
      try {
        const result = await commandFn(input, idempotencyKey);
        // 成功：更新 server snapshot
        if (result && result.context) {
          setServerSnapshot(result.context, result.dataRevision || result.context.data_revision);
        }
        commands.delete(recordKey);
        notifyStateChange();
        return { ok: true, result: result };
      } catch (err) {
        // 失败：区分网络错误（unknown）和业务错误（failed）
        const isNetworkError = err && (err.kind === 'network' || err.kind === 'server');
        cmd.state = isNetworkError ? 'unknown' : 'failed';
        cmd.error = err;
        commands.set(recordKey, cmd);
        notifyStateChange();

        // 网络错误 → 进入未知结果处理流程
        if (isNetworkError) {
          return await handleUnknownResult(recordKey, idempotencyKey, commandFn, input);
        }

        return { ok: false, error: err };
      }
    })();

    cmd.promise = promise;
    return promise;
  }

  // 未知结果处理（本卡最难的分支：RPC 成功但 response 丢失）
  async function handleUnknownResult(recordKey, idempotencyKey, commandFn, input) {
    const cmd = commands.get(recordKey);
    if (!cmd) return { ok: false, error: { kind: 'internal', text: '命令状态丢失' } };

    // 1. 先只读查询：用原 idempotency_key 对 get_command_result_v1 查 receipt
    try {
      const receiptRes = await Morrow.transport.rpc('get_command_result_v1', {
        idempotency_key: idempotencyKey,
      });

      if (receiptRes.ok && receiptRes.result) {
        // 已知结果则按原样恢复 UI（replayed:true 语义），不额外写库
        const receipt = receiptRes.result;
        if (receipt.ok && receipt.result) {
          // 恢复 UI 到收据状态
          if (receipt.result.context) {
            setServerSnapshot(receipt.result.context, receipt.result.dataRevision || receipt.result.context.data_revision);
          }
          commands.delete(recordKey);
          notifyStateChange();
          return { ok: true, result: receipt.result, replayed: true };
        }
      }
    } catch (_) {
      // 查询失败也继续走确认流程
    }

    // 2. 读不到（未知）时：先明确确认对话告知 LWW 风险
    const confirmed = await showLwwConfirmDialog(recordKey, input);
    if (!confirmed) {
      cmd.state = 'failed';
      cmd.error = { kind: 'cancelled', text: '用户取消重试' };
      commands.set(recordKey, cmd);
      notifyStateChange();
      return { ok: false, error: cmd.error };
    }

    // 3. 获得用户明确同意后，同 key 重试（绝不自动重放、绝不静默覆盖）
    try {
      const result = await commandFn(input, idempotencyKey);
      if (result && result.context) {
        setServerSnapshot(result.context, result.dataRevision || result.context.data_revision);
      }
      commands.delete(recordKey);
      notifyStateChange();
      return { ok: true, result: result };
    } catch (err) {
      cmd.state = 'failed';
      cmd.error = err;
      commands.set(recordKey, cmd);
      notifyStateChange();
      return { ok: false, error: err };
    }
  }

  // LWW 风险确认对话（需要 UI 层实现）
  function showLwwConfirmDialog(recordKey, input) {
    return new Promise(function (resolve) {
      if (!Morrow.ui || typeof Morrow.ui.showLwwConfirmDialog !== 'function') {
        // UI 未就绪时默认取消（安全兜底）
        resolve(false);
        return;
      }
      Morrow.ui.showLwwConfirmDialog(recordKey, input, function (confirmed) {
        resolve(confirmed === true);
      });
    });
  }

  // 取消命令（用户主动放弃）
  function cancelCommand(recordKey) {
    const cmd = commands.get(recordKey);
    if (cmd) {
      cmd.state = 'failed';
      cmd.error = { kind: 'cancelled', text: '用户取消' };
      commands.set(recordKey, cmd);
      notifyStateChange();
    }
  }

  // 清除所有命令状态（登出时调用）
  function clearCommands() {
    commands.clear();
    notifyStateChange();
  }

  // ---------- Form Draft 管理（未提交的编辑中表单） ----------

  function getFormDraftKey(bizDate, anchorType, field) {
    return bizDate + ':' + anchorType + ':' + field;
  }

  function setFormDraft(bizDate, anchorType, field, value, persisted) {
    const key = getFormDraftKey(bizDate, anchorType, field);
    formDrafts.set(key, {
      value: value,
      updatedAt: new Date().toISOString(),
      persisted: persisted === true,
    });
  }

  function getFormDraft(bizDate, anchorType, field) {
    const key = getFormDraftKey(bizDate, anchorType, field);
    return formDrafts.get(key) || null;
  }

  function clearFormDraft(bizDate, anchorType, field) {
    const key = getFormDraftKey(bizDate, anchorType, field);
    formDrafts.delete(key);
  }

  function getAllFormDrafts() {
    const drafts = [];
    formDrafts.forEach(function (draft, key) {
      drafts.push({ key: key, value: draft.value, updatedAt: draft.updatedAt, persisted: draft.persisted });
    });
    return drafts;
  }

  // ---------- 状态变更通知 ----------

  const listeners = [];

  function onStateChange(listener) {
    if (typeof listener === 'function') {
      listeners.push(listener);
    }
  }

  function notifyStateChange() {
    const state = getSyncState();
    const detail = getSyncDetail();
    listeners.forEach(function (listener) {
      try {
        listener(state, detail);
      } catch (_) {
        // 监听器异常不阻断主流程
      }
    });
  }

  // ---------- 工具函数 ----------

  function formatStamp(iso) {
    try {
      const d = new Date(iso);
      return isNaN(d.getTime()) ? '' : d.toLocaleString('zh-CN', { hour12: false });
    } catch (_) {
      return '';
    }
  }

  // ---------- 导出接口 ----------

  Morrow.store = {
    // Server Snapshot
    setServerSnapshot: setServerSnapshot,
    getServerSnapshot: getServerSnapshot,
    shouldAcceptSnapshot: shouldAcceptSnapshot,

    // Per-Record Command
    submitCommand: submitCommand,
    getCommand: getCommand,
    cancelCommand: cancelCommand,
    clearCommands: clearCommands,
    getCommandKey: getCommandKey,

    // Form Draft
    setFormDraft: setFormDraft,
    getFormDraft: getFormDraft,
    clearFormDraft: clearFormDraft,
    getAllFormDrafts: getAllFormDrafts,

    // 同步状态
    getSyncState: getSyncState,
    getSyncDetail: getSyncDetail,
    onStateChange: onStateChange,
  };
})();
