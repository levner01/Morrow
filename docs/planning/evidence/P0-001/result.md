# P0-001 任务收据｜仓库与环境基线

| 项 | 值 |
|---|---|
| 任务 ID | P0-001 |
| 主交付 commit | `f881dedda58b73dcf56512a5cc55d725658af91b`（root-commit, main） |
| 证据 commit | 本文件所在提交（紧随主交付） |
| 执行环境 | Trae + GLM-5.3 Flash（任务卡推荐执行组合） |
| 执行时间（UTC） | 2026-09-16T01:46:26Z |
| 本地时区 | Asia/Shanghai（2026-09-16 09:46 本地） |

## 前置依赖及证据

- 输入文档已读：`docs/planning/tasks/P0-001.md`、`docs/planning/03-execution.md` §1–3/§7、`docs/planning/01-architecture.md` §2。
- 施工前现场：目录无 `.git`（`git status` → `fatal: not a git repository`），无任何远端；已有文件为两份输入文档、README.md、AGENTS.md、docs/planning 全部规划文档。

## 保护现场验证（验收第 1 条：hash 未变）

施工前基线与主交付 commit 后复查，SHA256 完全一致：

| 文件 | SHA256（施工前 = 施工后） |
|---|---|
| 个人生活工作台 · 产品深度规划 V2.md | `c1dd596552929d60ad7c6997d60dff1253eee9d6d4b79230b17525e4c6e32882` |
| Morrow-Codex工程前置分析包.md | `39e2518221beff8db0509a66fd58784e56335e15955b4300744f642ffc74a0a3` |
| docs/planning/01-architecture.md | `e1efbf5eaca7584ff58e9d81b8a4a877ce58151e2400b595f2da76a27c12c916` |
| docs/planning/03-execution.md | `d1535121833cb402fd68f87a0c979dc54f265182a2bee22e4f46bb862917693b` |
| docs/planning/task-index.json | `ce307d5eb7a5dd4ceb4476f335beb86156910556c8f3a6f1251625fddd73a97c` |
| docs/planning/tasks/P0-001.md | `bdd71be1c239778fd65a603d29847c220020e45d43be71057768cbf255f5e400` |

其余 docs/planning 文件（02/04/05、reviews/、evidence/ 既有两份、tasks/ 其余 14 张卡）同样原样入库，完整基线 hash 清单见本任务执行过程记录（本收据只列关键项；可用 `git show f881ded --stat` 核对全部 38 文件）。README.md 为唯一被修改的既有文件：仅在末尾追加"施工提交与证据约定"一节，原有 26 行内容未动。

## 变更文件与摘要

| 文件 | 动作 | 摘要 |
|---|---|---|
| `.gitignore` | 新增 | secrets/.env/token（含 `mrw_v1.*`）/service_role/真实导出 exports/本地草稿/node_modules/dist//.DS_Store |
| `package.json` | 新增 | 仅元信息（name/version/private/description/engines node>=22/UNLICENSED），零依赖零脚本 |
| `assets/` `contracts/v1/` `supabase/migrations/` `scripts/` `tests/` | 新增骨架 | 各含 `.gitkeep` 占位；未建 adapters/、dist/、.github/、supabase/functions/、assets/js/* 等未来工程目录 |
| `docs/runtime-environment.md` | 新增 | 本机工具清单：全部 CLI 实测，区分已安装/未安装/待验证/待凯哥提供 |
| `README.md` | 追加一节 | 分支/提交/证据约定（一任务一逻辑提交、`<TASK-ID>:` 前缀、修复另加提交不 squash、task-index 由 Review 方更新） |
| 其余 32 文件 | 原样首次入库 | 两份输入文档 + docs/planning 全部 + AGENTS.md（内容未改） |

## 实际执行的验证命令与原始输出（节选）

**1. 无 git/远端（施工前）**：`git status` → `fatal: not a git repository (or any of the parent directories): .git`；`git remote -v` → 无输出。

**2. git init**：`git init -b main` → `Initialized empty Git repository in /Users/wangxinkai/Documents/Morrow/.git/`；提交后 `git remote -v` 仍为空（无远端、无推送、未连接 GitHub 账号）。

**3. 工具实测（2026-09-16，本机 macOS 26.3.1 arm64）**：

```text
git --version      → git version 2.50.1 (Apple Git-155)
node --version     → v22.22.3
npm --version      → 10.9.8
npx --version      → 10.9.8
deno --version     → command not found（未安装）
python3 --version  → Python 3.13.12
curl --version     → curl 8.7.1 (x86_64-apple-darwin25.0) LibreSSL/3.3.6
gh --version       → gh version 2.96.0 (2026-07-02)
gh auth status     → ✓ Logged in to github.com account levner01（GH_TOKEN active + keyring；本任务未做任何 gh 仓库操作）
supabase --version → command not found（未安装）
docker --version   → command not found（未安装）
Safari Info.plist  → 26.3.1；Chrome Info.plist → 151.0.7922.174；Edge → 未安装
sw_vers            → macOS 26.3.1 (25D771280a)；uname -m → arm64
```

**4. .gitignore 有效性（`git check-ignore -v`，10/10 命中）**：

```text
node_modules/ .env .env.local secrets/apprise.token mrw_v1.abc.def
exports/2026-09-16.export.json drafts-local/x.local-draft.json
node_modules_test_dir_marker.tmp .DS_Store dist/index.html service_role.json
→ 全部命中对应 .gitignore 规则行
```

**5. 暂存区秘密扫描**：`git diff --cached --name-only | grep -iE '\.env|token|secret|password|credential|service_role|mrw_v1'` → `CLEAN: 暂存区无秘密匹配文件`。

**6. 主提交**：`git commit` → `[main (root-commit) f881ded] P0-001: 建立仓库与环境基线`，38 files changed, 4283 insertions(+)。

## 验收自测清单

- [x] 两份输入文档内容 hash 未变（上表，基线与复查一致）
- [x] 环境清单区分已安装（附实测命令与输出）/未安装/待验证，无凭空事实（docs/runtime-environment.md）
- [x] `.gitignore` 覆盖秘密与导出；仓库暂存区与提交无任何 token/密码（check-ignore 10/10 + 暂存扫描 CLEAN）
- [x] task-index.json 保持 15 任务 PLANNED（hash `ce307d5e...` 未变，施工者未改 status）

## 未验证项（如实标注）

| 项 | 状态 | 说明 |
|---|---|---|
| Deno / Supabase CLI / Docker 安装 | NOT_RUN（未安装，安装属后续任务范围） | 分别影响 P0-002（Supabase CLI、Deno）与 P0-003/005（本地 PG 测试路径） |
| 代理 10808 | NOT_RUN | 按 03-execution §8 仅真实失败后验证 |
| Supabase 项目连通性、owner、GitHub 仓库/Pages、常驻调度宿主 | BLOCKED（待凯哥提供外部输入） | 见 docs/runtime-environment.md §4；不阻塞 P0-001 本身 |
| 真实双机浏览器环境 | BLOCKED（第二台设备待登记） | P0-008 前补齐 |

## 回滚影响

- 本任务为 root-commit，无历史可破坏。回滚 = 删除 `.git` 目录即可完全撤销仓库（文件层面新增的 .gitignore/package.json/骨架/runtime-environment.md 手工删除即还原现场）。
- 若仅需撤销提交保留文件：`git update-ref -d HEAD`（本收据如实记录，不代执行）。
- 不存在远端副作用，无数据迁移，无生产影响。

## Review（由 Review 方填写，施工者不填）

- Review 人 / 模型：＿＿＿
- 结论：☐ PASS ☐ BLOCKED
- 证据与意见：＿＿＿
- task-index.json 更新：签核 PASS 后由 Review 方将 P0-001 标记完成（施工者未动）

## 交接下一任务

P0-001 完成签核后进入 **P0-002**（真实 Supabase/Auth/网络可行性探针）。前置缺口：Supabase CLI 与 Deno 未安装、Supabase 项目信息待凯哥提供（见 runtime-environment §4）。
