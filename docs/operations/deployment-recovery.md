# Morrow 部署与恢复 Runbook（P0-008）

适用对象：Morrow 单用户（owner）双机（公司机/家机）运维。本文档所有操作可由下一次工程直接重复执行；不依赖任何 Agent 常驻能力。

- 发布 URL：`https://levner01.github.io/Morrow/`
- 仓库：`github.com/levner01/Morrow`（public，main 分支）
- 部署方式：GitHub Actions（`build_type=workflow`），产物固定 `dist/`
- 当前发行：`p0-006-15bb333e567b`，dist sha256 `5e46b6d3169e228479a313044d38a32367f41b8d5987d1e511cfc2ae927200ac`

---

## 1. 发布链路（Pages 部署与重发）

### 1.1 正常重发流程

1. 源文件修改后重新打包：`node scripts/package-html.js && node scripts/package-html.js --check`
   - `--check` 必须输出 `REPRODUCIBLE: PASS`；两次构建 SHA256 不一致则停止排查。
2. 提交并 push main：`.github/workflows/deploy-pages.yml` 监听 `dist/**` 变更自动触发部署。
3. 等待 Actions 绿：`gh run watch <run-id> --exit-status`（或仓库 Actions 页查看）。
4. 验证：`curl -sS -o /dev/null -w "%{http_code} %{num_redirects}" https://levner01.github.io/Morrow/` 应为 `200 0`。
5. 浏览器实测：打开 Pages URL → 配置面板/登录面板正常出现（详见第 6 节验证清单）。

### 1.2 手动触发部署

push 未触发时（如 workflow 文件本身变更被过滤）：
```bash
gh workflow run deploy-pages.yml --repo levner01/Morrow
```

### 1.3 Pages 服务自身状态查询

```bash
gh api repos/levner01/Morrow/pages -q '.status+" "+.build_type+" "+.html_url'
```
`build_type` 必须为 `workflow`。若为 `legacy`，用 PUT 纠正（root cause 见 evidence/P0-008/result.md）：
```bash
printf '{"source":{"branch":"main","path":"/"},"build_type":"workflow"}' | \
  gh api repos/levner01/Morrow/pages -X PUT --input -
```

---

## 2. Supabase 项目 Pause 识别与 Dashboard Resume

**不承诺"永不暂停"。** Supabase 免费层可能暂停长期无请求项目（[官方说明](https://supabase.com/docs/guides/platform/free-project-pausing)）；Keepalive 降低概率但不能根除。

### 2.1 识别 Pause

登录或操作时页面长时间无响应，先区分两类故障：

| 现象 | 初步判断 | 下一步 |
|---|---|---|
| 页面正常打开，登录报"无法连接到服务器" | 项目 Pause / 网络故障 | 2.2 查项目状态 |
| 页面本身打不开 | Pages 问题（非 Supabase） | 第 4 节 |

**查项目状态**（不经 Agent，owner 本人操作）：
1. 登录 Supabase Dashboard → 项目 `umutubzcwwmmbxfjkyvj`。
2. 项目卡片显示 **"Paused"** 即确认 Pause；显示 "Healthy/Active" 则 Pause 排除，转网络矩阵排查（docs/planning/evidence/P0-002/network-matrix.md）。
3. 或直接调 API（凭据在 keychain，runtime 注入）：
   ```bash
   curl -sS -H "Authorization: Bearer $(security find-generic-password -s MORROW_SUPABASE_ACCESS_TOKEN -a morrow -w)" \
     https://api.supabase.com/v1/projects/umutubzcwwmmbxfjkyvj | head -c 300
   ```

### 2.2 Resume 流程（平台动作，owner 手动执行）

1. Dashboard → 选项目 → **Resume project** → Confirm（以当前 Dashboard UI 为准）。
2. 等待项目状态回 Active（通常数秒到一分钟）。
3. **不主动 Pause 项目做演练**——Resume 后先跑 health 检查再正常使用：
   ```bash
   # health Agent 探针（P0-007 交付的 manage 脚本路径见 evidence/P0-007/result.md）
   ```
4. 浏览器实测：Pages URL 重新登录确认 `sync-badge=synced`。

**责任边界**：Dashboard 的 Restart / Pause / Resume 是**平台动作**，由 owner 本人在 Dashboard 执行，**不经 Agent、不写入任何自动化**。

---

## 3. Session 丢失（expired JWT 本地 refresh 失败）

### 3.1 识别

登录态页面刷新后跳回登录面板（状态机 `auth_required`），或操作时报鉴权错误。原因：refresh token 过期/被轮换/本地存储被清理。

### 3.2 恢复流程

1. **草稿优先**：回登录面板前先检查未同步草稿。在旧页面 DevTools Console：
   ```js
   Morrow.drafts.count()   // > 0 表示有未同步草稿
   ```
   有草稿则先导出（见第 5 节）再重新登录。
2. 重新登录：正常邮箱密码登录。session 存于本机 localStorage（前缀 `morrow.auth.`），重新登录即重建。
3. 若反复弹回登录面板：清掉残留 session 键后重试：
   ```js
   Object.keys(localStorage).filter(k => k.startsWith('morrow.auth.')).forEach(k => localStorage.removeItem(k));
   ```
4. 登录后恢复草稿（第 5.3 节）。

### 3.3 预防

- 两台机器各自保持正常使用即可（refresh token 自动续期）。
- Keepalive（P0-007）只保项目活跃，**不代替** Human 登录。

---

## 4. Pages 不可达降级（file:// / loopback 双路径）

Pages 不可达时（github.io 故障、网络封锁、Actions 失败），发行 HTML 可完全离线使用——**dist 是单文件，无 CDN 依赖**。

### 4.1 首选：file:// 双击（双机已实测 PASS）

1. 取离线副本：`dist/index.html`（仓库内）或 `curl -sS https://levner01.github.io/Morrow/ -o Morrow.html`（Pages 可达时预先保存）。
2. 双击打开（file origin）。实测结论（公司机 F3/F4、家机 F1/F2）：
   - 壳正常启动，storage probe 显示 `localStorage 可用 · IndexedDB 可用`；
   - 启动零远程 fetch；
   - 凭据经 `?sb_url=&sb_key=` 注入或本机已存配置 → 登录 → supabase 调用正常（唯一远程）。
3. file origin 的存储与 http origin **隔离**：在 file:// 下的配置/草稿不与其他 origin 共享，属正常行为。

### 4.2 备选：loopback 静态服务（固定端口）

file:// 若被未来浏览器策略破坏（当前双机实测通过，此为已批准备用分支）：
```bash
cd <仓库根目录> && python3 -m http.server 8080 --bind 127.0.0.1
# 浏览器打开 http://127.0.0.1:8080/dist/index.html
```
固定 `127.0.0.1:8080` + 同一发行 HTML，不经任何外部网络。

### 4.3 降级后恢复同步

网络恢复 / Pages 恢复后：在任一路径重新登录，草稿走第 5.3 节恢复。版本帧自动提示发行差异（旧快照显示时间戳）。

---

## 5. 草稿导出、备份与恢复

### 5.1 导出草稿（JSON）

DevTools Console（任意 origin 均可）：
```js
Morrow.drafts.exportJson()
```
返回 JSON 字符串：`{kind:"morrow-drafts", schema_version:1, exported_at:"<ISO>", drafts:[...]}`。
保存为文件：把返回值粘到文本文件存为 `morrow-drafts-YYYYMMDD.json`（敏感内容仅 owner 自存，不进 git、不上传）。

### 5.2 配置备份/恢复

配置（Supabase URL + publishable key）存于本机 localStorage `morrow.config.v1`。

- **备份**：DevTools Console → `JSON.stringify(JSON.parse(localStorage.getItem('morrow.config.v1')))`，存为私密文件。或更简——publishable key 非机密（可公开），URL 固定，重新粘贴一次等效备份（配置面板）。
- **恢复**：新机器/新浏览器 → 打开 Pages URL 或 dist → 配置面板粘贴 URL + key → 保存。`?sb_url=&sb_key=` 查询参数注入亦可（应用接收后 `replaceState` 抹除参数）。
- **删除**：配置面板清除按钮，或 `localStorage.removeItem('morrow.config.v1')`。

### 5.3 草稿恢复（导入）

应用当前无自动导入入口（M1 范围）。手动恢复：
```js
// 1. 读出草稿 JSON 文本（从备份文件粘贴）
const backup = <粘贴备份 JSON>;
const drafts = JSON.parse(backup).drafts;
// 2. 合并进本机存储（不覆盖同日已存在的同 key 草稿，除非确认覆盖）
const existing = Morrow.drafts._read();
const keys = new Set(existing.map(d => d.record_key));
drafts.forEach(d => { if (!keys.has(d.record_key)) existing.push(d); });
localStorage.setItem(Morrow.storage.DRAFTS_KEY, JSON.stringify(existing));
```
导入后在登录态页面按正常同步流程提交；**绝不自动重放 unknown 请求**——恢复草稿须先读最新服务端值再确认提交（C-04 迟到请求语义）。

---

## 6. 验证清单（每次恢复/发布后执行）

| # | 操作 | 期望 | 命令/方法 |
|---|---|---|---|
| V1 | Pages curl | `200 0`（无重定向） | `curl -sS -o /dev/null -w "%{http_code} %{num_redirects}" https://levner01.github.io/Morrow/` |
| V2 | served hash = dist hash | 两 sha256 一致 | `curl -sS https://levner01.github.io/Morrow/ \| shasum -a 256` 对比 manifest |
| V3 | 浏览器 boot | config-panel 或 login-panel 出现（无白屏） | Chrome/Firefox 实测，DevTools network 无意外远程 |
| V4 | 真实登录 | shell panel + `sync-badge=synced` | 双机实测 runner：`node tests/pages-evidence.js`（凭据 env 注入） |
| V5 | file:// 降级 | 双击 dist 启动正常、零远程 | 同 runner F3/F4 场景 |
| V6 | 登出草稿对话 | 有草稿时弹三选对话，session 键清零 | runner A12 场景 |

---

## 7. 版本回退（revert to previous release）

### 7.1 追溯

每次发行 `dist/release-manifest.json` 记录：`release.id`（`p0-006-<源hash12位>`）、`dist.sha256`、全部源文件 hash、`pages.url`。git 历史与 manifest 一一对应（P0-006 起 dist 入库）。

### 7.2 回退步骤

Pages 上回退 = 重新发布旧 dist：
```bash
# 1. 找到目标旧版本的 commit（manifest/dist.sha256 或 release.id 检索 git log）
git log --oneline -- dist/ | head -20
# 2. 检出旧 dist（示例：回退到上一发行）
git checkout <旧commit> -- dist/
node scripts/package-html.js --check   # 确认检出内容可复现
# 3. 提交并 push（Actions 自动重发 Pages）
git commit -m "revert dist to release <旧release.id> (sha256 <旧hash前12位>)"
git push origin main
# 4. V1/V2 验证 served hash = 旧 dist hash
```

### 7.3 约束

- 回退**前**先按第 5 节导出未同步草稿（回退不改服务端数据，但防本机混乱）。
- 已应用 migration **不可回退**（数据库向前兼容由 P0-003/P0-004 门禁保证）；HTML 只能回退到兼容当前 schema 的前版。
- 旧版不兼容提示：版本帧自动对比 `morrow.release_seen.v1`，发现发行差异显示旧快照时间——属正常提示，确认后继续使用。

---

## 8. 责任边界汇总

| 动作 | 执行方 | 说明 |
|---|---|---|
| Pages 部署/重发/回退 | git push + Actions（owner 发起） | 本 runbook 第 1、7 节 |
| Dashboard Restart/Pause/Resume | **owner 本人 Dashboard 手动** | **平台动作，不经 Agent、不自动化**（第 2 节） |
| Session 重登 / 草稿导出恢复 | owner 浏览器操作 | 第 3、5 节 |
| Keepalive 调度 | 宿主 launchd（P0-007） | 只保项目活跃，不代替登录 |
| 凭据 | keychain（macOS 安全存储） | publishable key / owner 密码 / access token 仅 runtime env 注入，零落盘 |

## 9. 相关证据索引

- 双机实测：[evidence/P0-008/device-matrix.md](../planning/evidence/P0-008/device-matrix.md)
- 家机 17/17：[evidence/P0-008/browser-evidence-real-cred.json](../planning/evidence/P0-008/browser-evidence-real-cred.json)
- 公司机 6/6：[evidence/P0-008/pages-evidence-company.json](../planning/evidence/P0-008/pages-evidence-company.json)
- 发布链路原始输出：[evidence/P0-008/deployment-evidence.md](../planning/evidence/P0-008/deployment-evidence.md)
- 网络矩阵：docs/planning/evidence/P0-002/network-matrix.md
