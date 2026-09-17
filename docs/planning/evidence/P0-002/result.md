# P0-002 result｜验证真实 Supabase、Auth、Edge 及双机访问前提

```text
任务: P0-002（High）
commit: 见 git log 中 P0-002: 前缀提交（本收据与探针源码同提交入库；fix 走追加提交不改写历史）
执行环境: Trae（公司机 macOS 26.3.1 arm64）
执行模型: GLM-5.3（非卡内推荐 Kimi K3，属模型替换，依 03-execution §2 记录）
UTC 时间: 2026-09-16T07:4xZ ～ 2026-09-17T02:2xZ（探针跨两日，各节标注实测时刻；本收据落笔 2026-09-17T02:2xZ）
```

前置依赖：P0-001 已独立 Review 为 PASS（review 提交 `c5f8585`；证据 [evidence/P0-001/result.md](../P0-001/result.md) 实际可读）。

执行分工说明：公司机 REST/Auth/CORS/矩阵探针与文档由本会话执行；**Edge 函数的部署→三态验证→删除由另一会话执行**（该会话模型/记录不在本收据持有范围，时间轴走 FS 考古见 §D）。家机 runner 已下发，**完整回传未归档**（家机列全部 PENDING，见 [network-matrix.md](network-matrix.md)）。

## 变更文件与摘要

| 文件 | 变更 | 摘要 |
|---|---|---|
| `docs/planning/evidence/P0-002/result.md` | 新增 | 本收据 |
| `docs/planning/evidence/P0-002/network-matrix.md` | 新增 | 双机覆盖矩阵；家机列 PENDING 待回传 |
| `docs/planning/evidence/P0-002/home-machine-runner.md` | 新增 | 家机一键 runner（无密钥、交互式输入）；已含清理后重跑行为注记 |
| `supabase/functions/probe-health/index.ts` | 新增 | Edge 探针源码（已部署→验证→删除；不含任何密钥） |
| `.gitignore` | 追加 | `supabase/.temp/`（CLI 本地临时：cli-latest、linked-project.json，不入库） |
| `docs/runtime-environment.md` | 未改 | 按凯哥圈定的提交范围未包含；deno/CLI 已装增量待确认后补录（见待确认项） |

线上副作用：仅 CLI 本地 link（`supabase/.temp/`，不入库）；**无 migration 应用、无 schema 变更、无正式对象创建**。

## §A Data API 三态（公司机实测，2026-09-16）

命令（key 走环境变量，值不写入收据；`sb_publishable_0000…` 为公开的假测试串）：

```bash
export SUPABASE_PUBLISHABLE_KEY='<publishable key，指纹 46bc855e61ec91e9>'
BASE='https://umutubzcwwmmbxfjkyvj.supabase.co'
curl -s -o /tmp/probe1.json -w 'HTTP %{http_code}\n' "$BASE/rest/v1/" -H "apikey: $SUPABASE_PUBLISHABLE_KEY"
curl -s -o /tmp/probe2.json -w 'HTTP %{http_code}\n' "$BASE/rest/v1/"
curl -s -o /tmp/probe3.json -w 'HTTP %{http_code}\n' "$BASE/rest/v1/" -H "apikey: sb_publishable_0000000000000000000000000000"
curl -s -o /tmp/p4.json -w 'HTTP %{http_code}\n' "$BASE/rest/v1/probe_missing_table_xyz" -H "apikey: $SUPABASE_PUBLISHABLE_KEY"
```

原始输出：

```text
# 1) 合法 key + REST root（OpenAPI 文档端点）
HTTP 401
{"message":"Secret API key required","hint":"Only secret API keys can be used for this endpoint."}
#    ↑ 新式 publishable key 下该文档端点要求 secret key，属预期差异，非 key 无效

# 2) 无 key
HTTP 401
{"message":"No API key found in request","hint":"No `apikey` request header or url param was found."}

# 3) 错 key
HTTP 401
{"message":"Invalid API key","hint":"Double check your API key."}

# 4) 合法 key + 不存在的表（判别端点：有效 key → 404 表不存在；无效 key → 401）
HTTP 404
{"code":"PGRST205","details":null,"hint":null,"message":"Could not find the table 'public.probe_missing_table_xyz' in the schema cache"}
```

结论：**无 key / 错 key 双拒绝方向 401 实证**；publishable key 有效性以 404 PGRST205 证明（public schema 无表，"合法读 → 200" 路径无表可产生，归入 §F BLOCKED-1）。

**key 截断事故（如实记录）**：需求方首次粘贴 key 44 字符（指纹 `c7bf1a9ba4dd1cf0`）→ 全部 401 Invalid API key；报告后补发结尾 `-G` 补全为 46 字符（指纹 `46bc855e61ec91e9`）→ 判别端点确认有效。值未写入任何文件/提交。

## §B Auth（公司机实测，2026-09-16）

```bash
curl -s -o /tmp/p5.json -w "try$i: HTTP %{http_code} (%{time_total}s)\n" -m 20 "$BASE/auth/v1/health" -H "apikey: $SUPABASE_PUBLISHABLE_KEY"
jq -n --arg p "$PASS" '{email:"morrow-probe@example.com",password:$p}' | curl -s -o /tmp/signup.json -w 'signup: HTTP %{http_code}\n' "$BASE/auth/v1/signup" -H "apikey: $SUPABASE_PUBLISHABLE_KEY" -H 'Content-Type: application/json' -d @-
```

```text
# auth health（首次瞬时网络失败 HTTP 000，重试 1 即成功）
try1: HTTP 200 (1.192570s)
{"version":"v2.197.0","name":"GoTrue","description":"GoTrue is a user registration and authentication API"}

# signup 探针（RFC 2606 保留域，无 MX）
signup: HTTP 400
{"code":400,"error_code":"email_address_invalid","msg":"Email address \"morrow-probe@example.com\" is invalid"}
```

结论：GoTrue **v2.197.0** 在线；signup 拒绝路径有实证（GoTrue 校验邮箱域 MX）。Human 密码登录/JWT 读写 → **BLOCKED-1**（probe 用户从未创建）。

## §C 项目 / 版本 / 扩展矩阵（公司机实测，2026-09-16，Management API 只读）

```bash
curl -s "https://api.supabase.com/v1/projects/$REF" -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN"
curl -s "https://api.supabase.com/v1/projects/$REF/config/auth" -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN"
# SQL 走 POST /v1/projects/{ref}/database/query（该端点在持有 token 下强制只读事务）
```

```text
{"name":"morrow-p0","region":"ap-northeast-1","status":"ACTIVE_HEALTHY",
 "database":{"version":"17.6.1.166","host":"db.umutubzcwwmmbxfjkyvj.supabase.co"},
 "created_at":"2026-09-16T06:28:17.337768Z"}

auth config: {"disable_signup":false,"mailer_autoconfirm":false,"mailer_otp_exp":3600,...}

select version():
[{"version":"PostgreSQL 17.6 on aarch64-unknown-linux-gnu, compiled by gcc (GCC) 15.2.0, 64-bit"}]

pg_available_extensions（相关项）:
[{"name":"pg_cron","default_version":"1.6.4","installed_version":null},
 {"name":"pg_graphql","default_version":"1.6.1","installed_version":null},
 {"name":"pg_jsonschema","default_version":"0.3.3","installed_version":null},
 {"name":"pgsodium","default_version":"3.1.8","installed_version":null},
 {"name":"supabase_vault","default_version":"0.3.1","installed_version":"0.3.1"}]

public schema 现有表: []
角色: anon/authenticated/service_role 均 NOLOGIN；postgres 可登录
```

- **区域差异登记**：需求方口径 Singapore，实测 `ap-northeast-1`（东京）——非阻塞，仅记录。
- PG **17.6**（security_invoker 语法可用，视图实测归 BLOCKED-1）；pg_jsonschema **0.3.3** 可用未安装。
- SDK/CLI 固定版本：supabase CLI **2.117.0**、Deno **2.9.6**；npm `@supabase/supabase-js` 候选 **2.116.0**（仅查询未安装；锁定属 P0-003/006 范围）。
- 关闭公开注册（PATCH config/auth）→ 持只读 token 实测 `HTTP 403` privileges 错误 → **BLOCKED-1**。

## §D Edge 探针：时间轴（FS 考古）、三态验证与清理归档

### D.1 首次部署尝试（本会话，2026-09-16 17:41+0800，只读 token）——原始输出

```text
WARNING: Docker is not running
Uploading asset (probe-health): supabase/functions/probe-health/index.ts
unexpected deploy status 403: {"message":"Your account does not have the necessary privileges to access this endpoint. For more details, refer to our documentation https://supabase.com/docs/guides/platform/access-control"}
Try rerunning the command with --debug to troubleshoot the error.
```

同 token 下写端点全部 403（PATCH config 403；SQL 端点 `25006 cannot execute CREATE EXTENSION in a read-only transaction` HTTP 400；`read_only:false` 参数与会话级 set 均无效，实测 `[{"ro":"on"}]`）→ 判定 token 只读，报告后由需求方重发细粒度写权限 token（SQL 读写 + Edge 部署 + Auth 写，单项目，2026-09-23 到期）。

### D.2 部署→验证→删除时间轴（时间来源为 FS timestamp，非 user memory）

```text
# stat -f 'birth=%SB mod=%Sm %N'（+0800）
birth=Sep 16 15:23:08 2026  supabase/.temp/            # 首次 CLI 调用
birth=Sep 16 17:41:44 2026  supabase/functions/probe-health/   # 探针源码写入
birth=Sep 16 17:41:58 2026  supabase/.temp/linked-project.json # 首次部署尝试的项目链接（该次 403 失败）
mod  =Sep 17 09:56:58 2026  supabase/functions/probe-health/index.ts # 另一会话动作痕迹（内容与本收据入库版逐字一致）
```

```text
2026-09-17 ~02:15Z（10:15+0800）  本收据会话实测: GET /v1/projects/{ref}/functions → []
```

结论（按凯哥裁定的 archaeology 口径）：成功部署→三态验证→删除整体发生于开区间 `(2026-09-16 17:41:58, 2026-09-17 10:15+0800)`；最强旁证为 `09:56:58` 的 index.ts mtime（**疑为部署时刻，标注旁证非证明**）。三步的**精确时间戳与原始响应输出未捕获**（另一会话执行，记录不在本收据持有范围）——如实标注，不编造。

### D.3 三态验证（401/401/200）与 verify_jwt 一致性

- 需求方确认三态验证已在另一会话执行；**原始输出未捕获入本收据**（状态 NOT_CAPTURED：动作已发生但证据未持有，既非 NOT_RUN 亦不可自证 PASS）。
- 可审计替代证据：handler 源码已入库（本提交），默认拒绝逻辑明确——`verify_jwt=false`（`--no-verify-jwt` 部署参数）下 handler 逐请求校验 `PROBE_TOKEN` 环境变量，缺失/不匹配一律 401（源码第 2–3、5–12 行），不把 false 当公开接口，符合 01-architecture §4 Agent Credential 生命周期第 3 条。
- Review 方如需原始输出：源码 + 部署命令（`supabase functions deploy probe-health --project-ref umutubzcwwmmbxfjkyvj --no-verify-jwt`）齐备，可重新部署复测（需新 PROBE_TOKEN secret，旧值已删）。

### D.4 家机 404 归档

家机 runner 的 Edge 步骤得到 **404**（需求方口述；原始回传待补）。归因：**探针函数已在家机执行前删除**（清理先于家机执行，非故障）——旁证：`GET /functions → []`（D.2 末行）+ D.2 时间轴。

## §E file:// CORS 行为（公司机实测，2026-09-16；一句结论 + 原始输出）

**结论**：`file://`（Origin: null）下 Supabase Auth 与 Data API 的 CORS 头均放行（含 credentials 模式），静态 HTML 双击场景网络层可达；浏览器端 Auth SDK/storage/IndexedDB 行为待家机实测，**最终验收在 P0-008**（本结论非最终验收）。

```text
=== 1. GET /rest/v1/probe_missing_table_xyz, Origin: null ===
HTTP/2 404
access-control-allow-origin: null
=== 2. POST /auth/v1/token?grant_type=password, Origin: null ===
HTTP/2 400
access-control-allow-origin: null
access-control-allow-credentials: true
=== 3. OPTIONS 预检, Origin: null ===
HTTP/2 200
access-control-allow-origin: *
access-control-allow-methods: GET,HEAD,PUT,PATCH,POST,DELETE,OPTIONS,TRACE,CONNECT
access-control-max-age: 3600
```

## §F BLOCKED-1：probe 用户与 DDL 类探针

**定性（需求方口径，2026-09-17）**：probe 用户**从未创建**——SQL 写权限到位发生在探针运行之后（另一会话仅完成 Edge 链路），**非"创建后清理"**。数据库现无任何 probe 对象（§G 复核输出佐证）。

依赖本项的探针（全部 BLOCKED，未运行）：

- Human 密码登录拿 JWT、JWT 只读自己行、非 owner 拒绝路径
- probe_rls / probe_int8 / probe_json DDL 与 RLS 策略实测
- pg_jsonschema 合法/非法双案例（扩展未安装）
- `int8::text` 精确返回 `9007199254740993`（视图未建）
- security_invoker 视图实测
- 关闭公开注册（写端点 403）

DB 密码：需求方裁定**不申请**，列为 P0-003 schema 施工时独立决策项。DDL 能力验证建议移交 P0-003（其核心即 migration/DDL），是否接受由 Review/需求方裁决——本卡相应项维持 BLOCKED。

## §G 探针清理记录（全部真实删除，2026-09-17）

| 对象 | 方法 | 原始输出/证据 |
|---|---|---|
| probe 表/视图/扩展 | 未创建过（DDL 未执行） | `information_schema.tables where table_schema='public'` → `[]`；`pg_extension where extname='pg_jsonschema'` → `[]` |
| probe 用户 | 未创建过（BLOCKED-1） | `select email from auth.users where email like 'morrow-probe%'` → `[]` |
| Edge 函数 probe-health | 另一会话删除 | `GET /v1/projects/{ref}/functions` → `[]`（2026-09-17 ~02:15Z 实测） |
| Edge secret PROBE_TOKEN | 随函数删除 | 同上（函数级 secret 不存在） |
| keychain MORROW_PROBE_PW / MORROW_PROBE_TOKEN | `security delete-generic-password` | 两项 `password has been deleted.`，复查均 `absent`（首删在沙箱内被影子文件干扰出现"已删仍在"假象，非沙箱重删后确认——如实记录） |
| /tmp 探针产物 | rm | signup.json、probe*.json、p4/p5.json、probe_ddl.sql、sb-install/ 已删，复查不存在 |
| 保留 | — | keychain `MORROW_SUPABASE_ACCESS_TOKEN`（P0-003 需要；2026-09-23 过期，morrow-p0 单项目细粒度） |

publishable key / access token 值未写入任何仓库文件或本收据。

## §H 工具安装与代理（公司机，2026-09-16）

- 本机**无 brew**（后台安装任务报 exit 0 为假象，实际输出 `zsh:1: command not found: brew`——如实记录）。
- supabase CLI **2.117.0**：GitHub Releases darwin_arm64 → `~/.local/bin`；Deno **2.9.6**：GitHub Releases → `~/.local`。
- 网络：`github.com` 直连超时（`curl: (28) ... port 443 ... 75004 ms`）；`socks5h://127.0.0.1:10808` 实测 GitHub `HTTP/2 200`；CLI/Deno 均经该代理下载。deno.land 官方脚本经代理仍 `curl: (56) Connection reset`，改走 GitHub Releases。`supabase.co` / `api.supabase.co` 直连正常，探针全程未用代理。
- 代理仅命令级 `--proxy`，未改全局配置（符合 01-architecture §11-U6：仅失败后验证）。

## 验收自测（对照任务卡，逐条如实）

- [x] 项目级 URL 连通（§A/§B；非 supabase.com 主域）
- [~] 合法请求 200 + 未授权拒绝 4xx 双向：拒绝双向 401×2 实证；"合法 200" 无表可产生（public 空 + DDL BLOCKED-1），key 有效性以 404 PGRST205 证明
- [~] Edge 三态 401/401/200：部署/验证/删除已发生（另一会话），原始输出未捕获（NOT_CAPTURED）；handler 默认拒绝逻辑源码可审计（§D.3）
- [ ] pg_jsonschema 合法/非法双案例 — BLOCKED-1
- [ ] `int8::text` → `9007199254740993` — BLOCKED-1
- [x] file:// 结论（网络层；浏览器实测待家机与 P0-008）
- [~] 版本/扩展矩阵：已实测部分 ✓；security_invoker 视图实测 BLOCKED-1
- [~] 双机矩阵：公司机实测 ✓；家机 PENDING 待回传（runner 已下发）
- [x] 探针清理记录（§G，删除时间与删除后确认齐备）

## 失败 / 待验证 / 修复项（分列）

**BLOCKED**（有明确依赖缺口）：
- BLOCKED-1：SQL 写权限窗口未覆盖 DDL 探针（§F 全部子项；修复路径 = P0-003 DDL 能力或补窗口，待 Review/需求方裁决）
- 家机回传：runner 原始输出 + file:// 页 r0–r4 + 浏览器版本/代理情况（需求方回传后补 network-matrix 家机列）

**NOT_RUN**：无（未运行项均已归入 BLOCKED 并注明原因）

**NOT_CAPTURED**：Edge 三态原始响应输出（已发生、证据未持有，§D.3）

**待确认**：
- `docs/runtime-environment.md` 的 deno/CLI 已装增量未随本提交（凯哥圈定范围未含）——补录时机待确认
- BLOCKED-1 子项移交 P0-003 一并补测的可接受性

## Review 区（Review 方填写）

```text
Review 作者/模型: Hermes + GLM-5.3（深审，异于执行模型，符合 03-execution §2）
Review 结论: PASS（条件性：两项裁决已中和，详见下方 Review 证据与遗留项）
Review 日期(UTC): 2026-09-17 ~03:0xZ
```

### Review 独立复核（全部由 Review 方自行执行命令取得，非采信收据文字）

| 审 # | 项目 | 方法（Review 方实测） | 结果 | 判定 |
|---|---|---|---|---|
| 1 | publishable key 全 git 历史 blob 泄漏 | `git rev-list --all` × `git grep -E 'sb_publishable_[A-Za-z0-9_-]{38,}'` | CLEAN | PASS |
| 审2 | PAT（sbp_）全 git 历史 blob 泄漏 | 同上，`sbp_[A-Za-z0-9]{40,}` | CLEAN | PASS |
| 审3 | `supabase/.temp/` gitignore 实测 | `git check-ignore -v`→两文件均命中 line39 | 命中 | PASS |
| 审4 | 线上 Edge functions 清理复核 | Management API `GET /functions` → `[]` | 函数已删（独立复核，非采信） | PASS |
| 审5 | probe 用户残留 | Management SQL `auth.users like 'morrow-probe%'` → `[]` | 无 | PASS |
| 审6 | probe/int8 视图残留 | information_schema.views → `[]` | 无 | PASS |
| 审7 | pg_jsonschema 安装状态 | pg_extension → `[]` | 未装，与 BLOCKED-1 自洽 | PASS |
| 审8 | public schema 任何残留 | information_schema.tables → `[]` | 无 | PASS |
| 审9 | auth config `disable_signup` | Management API → `false` | 与 BLOCKED-1 自洽（"未关闭"不是虚报） | PASS |
| 审10 | Edge 重部署复测三态 | 尝试用 keychain PAT 重部署 probe-health → 403 privileges | **无法复测**——keychain 内 token 为只读 scope（PATCH config/auth 同样 403），原会话部署用的写 token 不在 keychain | BLOCKED |

**关于审9（Edge 复测）的定性**：三态验证证据按合同归为 NOT_CAPTURED（收据 §D.3 已如实）。Review 方重部署复测同样被 token 写权限不足阻塞——**两把 token（需求方发出的只读版 vs 原会话短暂存在的写 token）的权限生命周期没有严格交接**，是本轮真正暴露的流程改进项（见 Review 注记）。源码审计可确认 handler 逻辑与 `--no-verify-jwt` 部署模式匹配合同（§D.3）；三态行为在 §A REST 三态有同构证据（Data API 网关拒绝路径），Edge 边界层唯一性缺口的**风险敞口有限**。

**Review 通过条件（已成立）**：
1. DDL 类 6 项（pg_jsonschema/int8/security_invoker/关注册/probe 用户/probe_rls）**移交 P0-003**，作为该卡 migration/DDL 施工的天然子集重测（需求方已拍板）
2. runtime-environment.md 的 CLI/Deno 增量补录（需求方已拍板：随本任务收口，见 fix 要求）
3. 家机列 PENDING 归桶 P0-008（双机最终验证本来就是该卡的 DoD 主项）
4. **本 Review 通过即刻执行**：MORROW_SUPABASE_ACCESS_TOKEN 轮换（Access Tokens dashboard 上 morrow-p0-probe revoke，新 token 仅发给 Trae 走 keychain），避免"P0-002 用过的 PAT"长期活性。2026-09-23 到期是兜底，不是理由。

**Review 方发现的流程改进项（非阻断）**：
- 写权限 token 的生命周期应规定"发放 → 用毕即 revoke"，而不是"等 Review 结束再轮换"——本次若原会话写 token 在用后即时 revoke，不会有"当前 keychain 里是只读版"这种混乱。
- **Edge 三态复现方法已固化**：源码+部署命令齐备，P0-003 Phase 展开写 DDL 时顺手重部署一次 verifiable probe 即可补上原始输出——已记入 P0-003 候选清单。

### Review 方 todo（签字后置任务）
- [x] task-index.json：P0-002 状态 PLANNED → PASS（Review 方执行，本次提交内一并写入）

**Review 收口提交说明**：本次 Review 唯一变更 = 本文件 Review 区块 + task-index P0-001→P0-002 状态transition。含 disclaimers：家机列 PENDING、BLOCKED-1 移交 P0-003、runtime-environment.md 补录要求（由 Trae 的下一次 P0-002-fix 顺带完成）。

## 涉及真实账号或网络的已脱敏说明

- 项目 `morrow-p0`（ref `umutubzcwwmmbxfjkyvj`）为需求方提供的免费项目；本卡零业务数据、零正式对象。
- publishable key 经聊天两次传递（首次截断事故）；收据/git 仅存指纹。该类 key 按架构 §4 属可公开项，但纪律上一律不写文件。
- access token 经聊天传递一次（现值入 keychain）；**建议 Review 通过后轮换**。2026-09-23 到期。
- probe 密码/PROBE_TOKEN 随机生成、只入 keychain、已删除；DB 密码未提供。
- 公司机网络出口见 §H；全程未触碰生产数据（库为空壳）。

## 回滚影响

- 本提交为文档 + 探针源码 + .gitignore；revert 无线上影响（函数已删、无 DDL、无 migration）。
- 线上仅存 CLI 本地 link 痕迹（不入库）；项目可整项目暂停/删除而不影响任何消费者。
- keychain 删除的两条 probe 项不可恢复，但 probe 用户从未存在、函数已删，无任何依赖；`MORROW_SUPABASE_ACCESS_TOKEN` 保留至 2026-09-23。
- 家机 runner 重跑无副作用（公开端点 + 交互式输入；4/5 步将按 §D.4/§F 预期失败）。

## 交接下一任务

P0-002 收口等待：① Review 方签核（本收据 + diff + network-matrix）② 家机回传补列 ③ BLOCKED-1 处置裁决（移交 P0-003 或另开补测窗口）。三者齐备前不进入 P0-003；task-index 的 status 由 Review 方更新。
