# Runtime Environment｜运行环境清单

- **记录任务**：P0-001（仓库与环境基线）
- **记录方式**：2026-09-16 于本机逐一 CLI 实测，只写实测输出。工程前置包中的历史描述（gh 认证状态、代理 10808 等）不直接采信为当前事实。
- **保密规则**：本文件不含任何 token、密码、连接串；凭据只走本机安全存储（见 docs/planning/03-execution.md §7）。

## 1. 本机（Apple Silicon Mac）

> 本机在公司机/家机中的角色待凯哥确认；另一台设备见 §5 待登记。

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

## 2. 本机未安装（实测确认）

| 项 | 实测证据 | 影响与需要的任务 |
|---|---|---|
| Deno | `deno --version` → `command not found` | Supabase Edge Functions 本地开发需要；P0-002/P0-007 前安装并锁定版本 |
| Supabase CLI | `supabase --version` → `command not found` | migration/函数部署需要；P0-002 前安装 |
| Docker | `docker --version` → `command not found` | 本地 PG/RLS 集成测试可能需要；P0-003/P0-005 前确认测试路径 |
| Microsoft Edge | Info.plist 不存在 | 不影响；双机浏览器清单以实际设备为准 |

## 3. 待验证（本任务不测，按规则延后）

| 项 | 说明 |
|---|---|
| 代理 10808 可用性 | 按 03-execution.md §8：仅在真实网络失败后验证，不主动测试、不改全局配置 |
| Supabase 项目连通性/扩展可用性 | 属 P0-002 探针范围，未测 |
| pg_jsonschema 等 PG 扩展 | 属 P0-002/003 实测，未测 |

## 4. 待凯哥提供的外部输入（03-execution.md §7，非敏感部分在此登记）

| 项 | 状态 |
|---|---|
| Supabase project_ref / URL | 待提供 |
| owner 邮箱或脱敏标识 / owner UUID | 待提供 |
| GitHub 仓库与 Pages URL | 待提供（P0-001 明确不创建远端、不连接账号，须授权后再建） |
| 常驻 Hermes 调度宿主（机器/时区/可用时段） | 待指定（不能假设当前 Mac 永远开机） |
| 发行物传递方式（Pages / 本地 HTML 包） | 待定 |

## 5. 双机环境（P0-008 交付前登记）

| 设备 | 浏览器及版本 | 网络条件 | 状态 |
|---|---|---|---|
| 本机（见 §1） | Safari 26.3.1 / Chrome 151.0.7922.174 | 待实测 | 角色待确认（公司机或家机） |
| 第二台设备 | 待登记 | 待登记 | 待凯哥提供 |
