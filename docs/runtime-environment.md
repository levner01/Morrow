# Runtime Environment｜运行环境清单

- **记录任务**：P0-001（仓库与环境基线）；**P0-002 增量补录**（2026-09-17，响应 P0-002 Review 条件 2，只写实测）
- **记录方式**：2026-09-16 于本机逐一 CLI 实测，只写实测输出。工程前置包中的历史描述（gh 认证状态、代理 10808 等）不直接采信为当前事实。
- **保密规则**：本文件不含任何 token、密码、连接串；凭据只走本机安全存储（见 docs/planning/03-execution.md §7）。

## 1. 本机（Apple Silicon Mac）

> 本机角色已确认（P0-002）：**公司机**（探针执行机）；另一台设备（家机）见 §5。

| 项 | 状态 | 实测命令 | 实测输出 |
|---|---|---|---|
| 操作系统 | 已安装 | `sw_vers` / `uname -m` | macOS 26.3.1 (Build 25D771280a)，arm64 |
| git | 已安装 | `git --version` | git version 2.50.1 (Apple Git-155) |
| Node.js | 已安装 | `node --version` | v22.22.3 |
| npm | 已安装 | `npm --version` | 10.9.8 |
| npx | 已安装 | `npx --version` | 10.9.8 |
| Python 3 | 已安装 | `python3 --version` | Python 3.13.12 |
| curl | 已安装 | `curl --version` | curl 8.7.1 (libcurl/8.7.1, LibreSSL/3.3.6) |
| gh CLI | 已安装 | `gh --version` | gh version 2.96.0 (2026-07-02) |
| gh 认证 | 已登录（实测） | `gh auth status` | 已登录 github.com 账号 **levner01**（GH_TOKEN active + keyring）；本任务未执行任何 gh 仓库/远端操作 |
| Safari | 已安装 | `PlistBuddy -c 'Print CFBundleShortVersionString' /Applications/Safari.app/Contents/Info.plist` | 26.3.1 |
| Chrome | 已安装 | `PlistBuddy -c 'Print CFBundleShortVersionString' '/Applications/Google Chrome.app/Contents/Info.plist'` | 151.0.7922.174 |
| Supabase CLI | 已安装（P0-002 补录） | `supabase --version` | 2.117.0（`~/.local/bin`；GitHub Releases darwin_arm64 经 socks5 代理下载，见 §3） |
| Deno | 已安装（P0-002 补录） | `deno --version` | 2.9.6（`~/.local/bin`；同上安装路径） |

## 2. 本机未安装（实测确认）

> P0-002 更新：Deno 与 Supabase CLI 已于 2026-09-16 安装（见 §1），从本表移除。

| 项 | 实测证据 | 影响与需要的任务 |
|---|---|---|
| Homebrew (brew) | `brew install ...` → `zsh:1: command not found: brew`（P0-002 实测） | 无直接阻塞；工具改走用户级安装（`~/.local/bin`） |
| Docker | `docker --version` → `command not found` | 本地 PG/RLS 集成测试可能需要；P0-003/P0-005 前确认测试路径（P0-003 DDL 走远端 Management API SQL，暂不阻塞） |
| Microsoft Edge | Info.plist 不存在 | 不影响；双机浏览器清单以实际设备为准 |

## 3. 待验证（本任务不测，按规则延后）

| 项 | 说明 |
|---|---|
| 代理 10808 | **已实测（P0-002，2026-09-16）**：`github.com` 直连超时（curl 28, port 443）；`--proxy socks5h://127.0.0.1:10808` → GitHub `HTTP/2 200`。仅命令级使用，未改全局配置（03-execution §8 合规）。`supabase.co` / `api.supabase.co` 直连正常，探针全程未用代理 |
| Supabase 项目连通性/扩展可用性 | P0-002 已实测：项目 ACTIVE_HEALTHY，PG 17.6，GoTrue v2.197.0；详见 evidence/P0-002/result.md |
| pg_jsonschema 等 PG 扩展 | pg_available_extensions 实测 0.3.3 可用未安装；安装/双案例实测随 BLOCKED-1 移交 P0-003 |

## 4. 待凯哥提供的外部输入（03-execution.md §7，非敏感部分在此登记）

| 项 | 状态 |
|---|---|
| Supabase project_ref / URL | **已提供并实测（P0-002）**：morrow-p0，ref `umutubzcwwmmbxfjkyvj`（region ap-northeast-1，与需求方口径 Singapore 不符，已登记差异） |
| owner 邮箱或脱敏标识 / owner UUID | 待提供（P0-003 owner singleton 与 RLS 需要） |
| GitHub 仓库与 Pages URL | 待提供（须授权后再建；P0-001 纪律：不创建远端、不连接账号） |
| 常驻 Hermes 调度宿主（机器/时区/可用时段） | 待指定（不能假设当前 Mac 永远开机） |
| 发行物传递方式（Pages / 本地 HTML 包） | 待定 |
| SUPABASE_ACCESS_TOKEN 轮换（P0-002 Review 条件 4） | 待确认执行：revoke 旧 morrow-p0-probe，新 token（SQL 写 + Edge 部署 scope）走 keychain——P0-003 开工硬依赖 |

## 5. 双机环境（P0-008 交付前登记）

| 设备 | 浏览器及版本 | 网络条件 | 状态 |
|---|---|---|---|
| 本机（公司机，见 §1） | Safari 26.3.1 / Chrome 151.0.7922.174 | 见 §3 代理条目 | 已登记（P0-002） |
| 家机（第二台设备） | 待回传（runner 已执行，完整输出待归档，归桶 P0-008） | 待回传 | 待凯哥提供 |
