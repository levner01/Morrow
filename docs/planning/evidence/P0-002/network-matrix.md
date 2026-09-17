# P0-002 网络与双机覆盖矩阵（network-matrix）

- 记录时间（UTC）：2026-09-16（公司机探针）／2026-09-17（收口）；家机回传待补
- 项目：morrow-p0（ref `umutubzcwwmmbxfjkyvj`，region ap-northeast-1，PG 17.6，ACTIVE_HEALTHY）
- 角色约定：公司机 = 本文件执行探针的机器；家机 = runner 已下发（`home-machine-runner.md`），**完整回传未归档，家机列全部 PENDING 待补**

## 一、双机覆盖矩阵

| # | 探针项 | 公司机（本机）实测 | 家机 | 备注 |
|---|---|---|---|---|
| N1 | 项目 URL 连通（非 supabase.com 主域） | ✓ 见 result.md §A1 | PENDING（待回传） | REST/auth 端点均返回项目级响应 |
| N2 | Data API 无 key 拒绝 | ✓ 401 no API key found | PENDING（待回传） | 网关层 |
| N3 | Data API 错 key 拒绝 | ✓ 401 Invalid API key | PENDING（待回传） | 网关层 |
| N4 | Data API 合法 key 读 | ✓ 404 PGRST205（key 有效证明；/rest/v1/ root 在新式 key 下要求 secret key 属预期差异） | PENDING（待回传） | |
| N5 | Auth health | ✓ 200 GoTrue v2.197.0 | PENDING（待回传） | |
| N6 | Auth signup 拒绝路径 | ✓ 400 email_address_invalid（example.com 无 MX） | —（runner 未含 signup 步骤） | 关闭公开注册 BLOCKED-1，见 result.md §F |
| N7 | Human 密码登录 + JWT 只读 | BLOCKED（probe 用户创建依赖 SQL 写权限，见 result.md BLOCKED-1） | BLOCKED（同公司机 BLOCKED-1：probe 用户从未创建，runner 第 4 节预期登录失败） | |
| N8 | Edge 三态 | 部分：部署/验证/删除已执行（另一会话，输出未捕获 NOT_CAPTURED）；删除确认 `GET /functions`→`[]` | PENDING（待回传；Edge 步骤预期 404——函数已清理，归档见 result.md §D.4） | |
| N9 | file:// Origin null CORS | ✓ 见 result.md §E | PENDING（待回传，含 file:// 原型页 r0–r4） | 最终验收在 P0-008 |
| N10 | 代理依赖 | supabase.co / api.supabase.co 直连可达；github.com 直连失败，经本地 socks5 10808 完成 CLI/Deno 下载（仅命令级 --proxy，未改全局配置，符合 §11-U6） | PENDING（待回传） | |

## 二、公司机环境快照（实测）

| 项 | 值 |
|---|---|
| OS | macOS 26.3.1 (25D771280a) arm64 |
| 浏览器 | Safari 26.3.1 / Chrome 151.0.7922.174（Edge 未安装） |
| 出口 | supabase.co、api.supabase.co 直连正常；github.com 直连超时，socks5h://127.0.0.1:10808 可用 |
| supabase CLI | 2.117.0（~/.local/bin，GitHub Releases 经 10808 下载；brew 不存在于本机，用户级官方脚本/直装替代） |
| Deno | 2.9.6（~/.local/bin，GitHub Releases 经 10808 下载） |

## 三、家机回传要求（对应 runner）

状态（2026-09-17）：runner 已下发并执行（需求方口述 Edge 步骤 404，归档见 result.md §D.4）；**完整原始输出未归档，家机列维持 PENDING**。

回传清单：

1. runner 全部命令的**原始输出**（可整段粘贴）
2. 浏览器 file:// 原型页的可见结果与 console 报错截图（截图不得含 token/session/密码）
3. 家机浏览器版本、user-agent、是否使用代理
4. 回传后由施工方在本任务下补充矩阵并核对清理归档（探针对象已清理，runner 第 4/5 节预期失败属正常，见 result.md §D.4/§F）
