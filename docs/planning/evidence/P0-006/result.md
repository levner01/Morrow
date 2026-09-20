# P0-006 任务收据｜可降级静态登录壳和同源单HTML发行

## 任务/commit/执行环境/模型/UTC时间
- 任务：P0-006（本卡 `docs/planning/tasks/P0-006.md`）
- 主交付 commit：`3731f3c`（本收据为紧随其后的证据提交）
- 执行环境：公司机（Apple Silicon Mac，macOS 26.3.1 / Node v22.22.3 / Chrome 151 headless new / Python 3.13.12）；详见 `docs/runtime-environment.md`
- 执行模型：Trae + Kimi K2.7 Code
- 时间：2026-09-20（Asia/Shanghai）

## 前置依赖及其证据路径
- P0-005 PASS：`2e1bbcf`（`git log` 已核验）；安全矩阵 `docs/planning/evidence/P0-005/security-matrix.md`、并发 `concurrency-results.txt` 已实读
- 合同：`02-contracts.md` C-05（RPC 表面）、C-07（页面状态机与草稿）；架构 `01-architecture.md` AD-02 / §2 / §4 / §8 / §9

## 变更文件与行为摘要
- `index.html`：源页面（普通静态服务直开），classic scripts 固定顺序加载
- `assets/css/app.css`：原生 Grid、系统字体、320–1280 检查、三态标识不只靠颜色、reduced-motion
- `assets/js/config.js`：运行时配置（URL + publishable key）——仅存本机 localStorage；支持一次性 `?sb_url=&sb_key=` 注入后立即从地址栏抹除；格式校验
- `assets/js/transport.js`：supabase-js 唯一封装层；超时 fetch（12s AbortController）；登录/会话刷新/登出/权威校验 RPC（`get_workspace_revision_v1`）；错误收敛为有限集（network/invalid_credentials/auth_expired/owner_denied/rate_limited/server/internal），message 不含 token/SQL
- `assets/js/drafts.js`：localStorage 写/删实测 + IndexedDB open 实测探针（1.5s 超时防卡死）；草稿条目含 C-07 字段；无凭据导出 JSON
- `assets/js/ui.js`：失败面板（kind=config/resource/network/internal，主按钮按 kind 映射 检查配置/重新加载/重试）；三态同步标识（已同步/同步中/同步失败·重试）；版本帧 + 旧发行横幅（stale 防线）；登出草稿三选对话（下载/保留/删除）
- `assets/js/app.js`：boot → auth_check → synced/config_required/auth_required/failed 状态机；未捕获异常与 Promise 拒绝兜底（不白屏）；`morrow.last_sync.v1` 旧快照时间戳
- `assets/vendor/supabase-js@2.116.0.umd.js`：自托管 SDK，sha256 `84ee9bf45695c1dd3ba1595b6bcfb0f09672434631351ffc8ebe9140545d5ff6`，LICENSE 已登记 MIT 归属
- `scripts/package-html.js`：固定清单内联打包（转义 `</script` 序列）；`dist/index.html` 零时间戳，`--check` 两次构建 SHA256 一致
- `dist/index.html` / `dist/release-manifest.json`：发行物入库（.gitignore 按卡口径调整）；release id `p0-006-9fd1020e12c8`，dist sha256 `c07b0f832bb1ae291bff6e072052da81b147bcefd8c3610a56bd1be9029251dd`
- `tests/browser-evidence.js`：CDP（Node 22 内置 WebSocket，零 npm 依赖）驱动 Chrome headless；凭据只读 env 且全部输出经 redact
- `LICENSE`：项目 UNLICENSED 声明 + supabase-js 2.116.0 MIT attribution

## 验证命令或手工操作 + exit/status + 原始输出文件链接

### 已执行（本机自跑）
1. `node scripts/package-html.js` → exit 0；release p0-006-9fd1020e12c8；dist sha256 `c07b0f83…251dd`（原始输出见下方"原始输出摘录"）
2. `node scripts/package-html.js --check` → exit 0，`REPRODUCIBLE: PASS`（published == rebuilt）
3. `node tests/browser-evidence.js`（未注入凭据）→ exit 0，13/13 通过；原始记录 [browser-evidence.json](browser-evidence.json)：
   - A1 http 启动（`python3 -m http.server 8080 --bind 127.0.0.1`）→ 配置面板可见；storage probe：`localStorage 可用 · IndexedDB 可用`；network 9 条全部本地
   - A5 内部异常 → `kind=internal` 失败面板出现（无白屏）
   - F1 file:// 双击 dist → 配置面板可见；storage probe（file origin）可见；**远程请求 0 条**
   - S1 密钥扫描：dist/index.html、dist/release-manifest.json、index.html、config.js、transport.js 五文件无 publishable key/JWT/service_role 形态
4. `grep -o 'sb_publishable[A-Za-z0-9_]*' dist/index.html` → 仅占位前缀 5 处（`sb_publishable_` / `sb_publishable_xxx`），无真实 key

### 待凯哥执行（一次性，凭据只进 shell 内存，不落盘不入证据）
```zsh
cd /Users/wangxinkai/Documents/Morrow
read -s -r 'SUPABASE_PUBLISHABLE_KEY?粘贴 publishable key: '; echo
read -r 'MORROW_OWNER_EMAIL?owner 邮箱: '
read -s -r 'MORROW_OWNER_PASSWORD?owner 密码: '; echo
export SUPABASE_PUBLISHABLE_KEY MORROW_OWNER_EMAIL MORROW_OWNER_PASSWORD
node tests/browser-evidence.js
unset SUPABASE_PUBLISHABLE_KEY MORROW_OWNER_PASSWORD
```
覆盖：A2 query 注入 + 参数抹除 + 仅 supabase.co 远程；A3 错误密码文案；A4 断网重试文案；A6 SDK 拦截资源失败面板；A11 真实登录 + verifyOwner RPC + 登出；A12 登出草稿对话 + session 清零；F2 file:// + 配置后仅 supabase.co。

## 失败/待验证/修复项
- **BLOCKED（待凯哥执行上面命令后补登）**：A2/A3/A4/A6/A11/A12/F2 真实网络路径。当前为 SKIP（runner 标记 pass+SKIP 说明，非伪造通过）
- **NOT_RUN**：Safari 实测（file origin 下 localStorage 差异）——Safari AppleScript 需"允许 Apple 事件执行 JavaScript"授权，P0-008 双机验收补齐；Chrome 下 file:// 探针已实测可用
- 家机实测：移交 P0-008（与卡一致）

## Review作者/模型/结论
- 待 Review 方按卡分工（WorkBuddy + DeepSeek V4.1 Flash；Hy4 检查失败页面）
- 结论：____（Review 后填写）

## 涉及真实账号或网络的已脱敏说明
- 运行器只读取 env 凭据，所有捕获 URL/console 经 redact 处理（key/password 出现即替换 `<redacted>`）；证据文件 `browser-evidence.json` 仅记录 env 是否存在与长度，不记录值
- owner UUID `0c645909-ebb5-4910-ab99-4f7b238c9529` 为 P0-003 公开登记值，非秘密

## 交接下一任务
- P0-007（health 客户端、撤销、真实常驻调度）
- 待验证缺口（本卡遗留）：凯哥执行凭据命令后的真实登录证据；Safari/家机 file origin 差异（P0-008）

## 原始输出摘录
```text
$ node scripts/package-html.js
[package-html] release p0-006-9fd1020e12c8
[package-html] dist/index.html sha256 c07b0f832bb1ae291bff6e072052da81b147bcefd8c3610a56bd1be9029251dd
[package-html] manifest  -> dist/release-manifest.json

$ node scripts/package-html.js --check
[package-html --check] published c07b0f832bb1ae291bff6e072052da81b147bcefd8c3610a56bd1be9029251dd
[package-html --check] rebuilt    c07b0f832bb1ae291bff6e072052da81b147bcefd8c3610a56bd1be9029251dd
REPRODUCIBLE: PASS

$ node tests/browser-evidence.js  （未注入凭据）
PASS  A1_http_boot_config_panel  — storage probe: 本地存储探针（http origin）：localStorage 可用 · IndexedDB 可用
PASS  A1_http_network_local_only  — 仅本地请求 9 条
PASS  A2_http_query_config_login_panel  — SKIP：未注入 SUPABASE_PUBLISHABLE_KEY（env）
PASS  A3_wrong_password_mapped  — SKIP：依赖 A2
PASS  A4_offline_login_network_error  — SKIP：依赖 A2
PASS  A11_real_login_shell  — SKIP：未注入凭据
PASS  A12_logout_draft_dialog  — SKIP：未注入凭据
PASS  A5_internal_exception_panel  — kind=internal 面板出现（无白屏）
PASS  A6_resource_block_panel  — SKIP：需先存在本机配置才能触达 SDK 初始化分支
PASS  F1_file_boot_config_panel  — storage probe: 本地存储探针（file origin）：localStorage 可用 · IndexedDB 可用
PASS  F1_file_network_zero_remote  — 远程 0 条（file origin 启动零 fetch）
PASS  F2_file_remote_only_supabase  — SKIP：未注入 SUPABASE_PUBLISHABLE_KEY
PASS  S1_secret_scan_dist_and_source  — 5 个关键文件零密钥形态
== 汇总: 13/13 通过 ==
```
