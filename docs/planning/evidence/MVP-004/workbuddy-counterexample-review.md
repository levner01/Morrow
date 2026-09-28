# WorkBuddy 反例初审记录 — MVP-004 返工（0015 complete 语义「多记不罚」）

**初审模型**：DeepSeek V4.1 Flash —— 异于执行方 Trae+GLM-5.3 ✓、异于深审方 Hermes GLM-5.3 ✓
**初审方法**：任务 A（零漂移）自行从 git 提取 15121c9 原文与 0015 逐行归一化比对；任务 B 的 W1–W10 全部由初审方**自行构造并实测**（Supabase Management API SQL 端点，`do $$ … $$` 单事务 + 末尾 `RAISE EXCEPTION 'WB_PROOF <json>'` 回滚）。不采信施工收据文字，不采信 Hermes 结论——只认自跑输出。
**凭据纪律**：PAT 仅经 keychain（`-a morrow -s MORROW_SUPABASE_ACCESS_TOKEN`）注入**进程环境变量**，不落盘、不打印、不进命令行参数。本记录不含任何 token/key/密码；owner uuid 仅保留前 8 位指纹 `0c645909…`。
**探针纪律**：每条反例 = 一个 `do $$ … $$` 块，块内改 `tracking_started_on` / `schedule_history` / INSERT `life_data`，末尾 `RAISE EXCEPTION` 强制回滚 → 真实库零持久写（残留自查见 §5）。DML 前均 `perform private.cmd_set_actor('human', <owner>)`；铺行 `entity_key` 前缀 `wb-erl:`；payload 含 `payload_v` 数字键。
**环境**：Project ref `umutubzcwwmmbxfjkyvj`，PostgreSQL 17.6；测试时 `v_today = 2026-09-28`（Asia/Shanghai）；真库 `tracking_started_on = 2026-09-21`，`schedule_history` 单段 `effective_from = 2026-09-21`（mon/wed/fri=workout_workday→den 3；tue/thu/sat/sun→den 2）。

## 0. 结论

> **PASS** —— 任务 A 零漂移实测成立（**仅 4 处 `=` → `>=`**，无其它漂移）；W1–W10 反例**全部实测符合期望**；未发现 P0/P1 缺陷。

- **NEW-FINDING：1 条**，判 **P2 / 非阻断**（0015 未引入，属 0013 既有设计的耦合点，M1 不可达）——见 §4。
- W7 真库雷实测：`p0test:anchor-f1` **未被删除且仍在预期状态**；单天窗口 `streak = 1`；**反事实严格等号 walk = 0**（实测双向对照）。

| 项 | 反例 | 期望 | 实测 | 判定 |
|---|---|---|---|---|
| A1 | 零漂移 | 仅 4 处 `=`→`>=` | 4 处，L102/L217/L296/L314，无其它漂移 | ✅ |
| W1 | den=2 铺 3 条 | streak=1；格 provisional=false | den=2 rec=3 streak=**1** provisional=**false** | ✅ |
| W2 | den=2 铺 1 条 | streak=0 | den=2 rec=1 streak=**0** | ✅ |
| W3 | den=2 恰好 2 条 | streak=1 | den=2 rec=2 streak=**1** | ✅ |
| W4 | 今日 den+1 条 | complete=true / provisional=false | den=3 rec=4 complete=**true** provisional=**false** | ✅ |
| W5 | 45 天连续、30 天窗口 | streak=45 不被裁 | ext_streak=**45**（base 窗口裁剪=30） | ✅ |
| W6 | 8 天连续+断链墙+今日空 | streak=8；today_provisional=true | streak=**8** provisional=**true** | ✅ |
| W7 | 真库雷不删+起日回拨 | streak=1（等号语义=0） | streak=**1**；严格等号反事实=**0** | ✅ |
| W8 | 静态审计两件 | 无残留等号 + grants 正确 | 0 残留；grants 全符合 | ✅ |
| W9 | get_today_context_v1 全链路 | ok=true；形状与 0013 一致 | ok=**true**；9 顶部键 / stats 9 键（无 extend 字段） | ✅ |
| W10 | 未开始日 | den=0/not_started；不进统计 | den=**0** not_started=**true**；planned/recorded=0 | ✅ |

## 1. 任务 A：零漂移独立复核

### 1.1 基线一致性（先证可比）

```
20260923150000_0013_mvp_business_core.sql   HEAD == 15121c9 : True
20260928100000_0014_heatmap_stats.sql       HEAD == 15121c9 : True
```

两个被 replace 的源 migration 工作区版本与基线提交**逐字节相同** → 以 15121c9 为基线做 diff 是有效比较（不会被后续改动污染）。

### 1.2 归一化逐行比对（去 `--` 注释、折叠空白、去空行）

`python3 difflib.SequenceMatcher`，三个函数分别比对：

```
--- private.mvp_stats ---        old=97 lines  new=97 lines
  [replace] old L76: v_complete := coalesce(v_rec_cnt, 0) = v_need;
        new L76: v_complete := coalesce(v_rec_cnt, 0) >= v_need;
--- private.mvp_heatmap_30 ---   old=107 lines new=107 lines
  [replace] old L82: v_complete := coalesce(v_rec, 0) = v_need;
        new L82: v_complete := coalesce(v_rec, 0) >= v_need;
--- private.mvp_stats_extend --- old=74 lines  new=74 lines
  [replace] old L43: v_today_complete := coalesce(v_rec, 0) = v_need;
        new L43: v_today_complete := coalesce(v_rec, 0) >= v_need;
  [replace] old L57: v_complete := coalesce(v_rec, 0) = v_need;
        new L57: v_complete := coalesce(v_rec, 0) >= v_need;

=== TOTAL changed line positions (normalized) = 4 ===
```

**行数两侧完全相等（97/97、107/107、74/74），仅 4 处 replace。**

### 1.3 与提示词声称的落点核对（原始行号，非归一化）

```
$ grep -n "v_need" supabase/migrations/20260928113000_0015_complete_semantics.sql
102:    v_complete := coalesce(v_rec_cnt, 0) >= v_need;
217:      v_complete := coalesce(v_rec, 0) >= v_need;
296:    v_today_complete := coalesce(v_rec, 0) >= v_need;
314:    v_complete := coalesce(v_rec, 0) >= v_need;
```

**L102 / L217 / L296 / L314 —— 与提示词声称的 4 处落点逐一吻合。**

### 1.4 无「多改/漏改」的结构性核对

0015 全部**顶层语句**（函数体外）扫描：

```
L20   TOPLEVEL  begin;
L124  FUNC_END  $$;      (mvp_stats 结束)
L244  FUNC_END  $$;      (mvp_heatmap_30 结束)
L332  FUNC_END  $$;      (mvp_stats_extend 结束)
L335  TOPLEVEL  revoke all on function private.mvp_stats(...) from public, anon, authenticated, service_role;
L336  TOPLEVEL  revoke all on function private.mvp_heatmap_30(...) from ...;
L337  TOPLEVEL  revoke all on function private.mvp_stats_extend(...) from ...;
L339  TOPLEVEL  commit;
```

- **无新增 grant、无 schema/表改动、无其它函数**（对比 P0-004 反例 14 的手法）。
- 3 条尾部 `revoke all` 为幂等保险（`create or replace` 同签名保留 ACL），**方向与 W8-2 的 grants 期望一致**，且未新增任何授权。
- 签名未变：三处 `create or replace function` 的头行在 diff 中**未出现**（证明参数列表逐字相同，符合「同签名 replace」）。

### 1.5 部署体 vs 文件体（证明 0015 真已应用且无带外漂移）

从 `pg_get_functiondef` 取**已部署**定义，与 0015 文件体归一化比对：

```
=== BODY-ONLY: deployed(pg_proc) vs 0015 file ===
  mvp_stats         body dep=92   file=92   diff_ops=0  deployed'>='=1  bare'='=0
  mvp_heatmap_30    body dep=102  file=102  diff_ops=0  deployed'>='=1  bare'='=0
  mvp_stats_extend  body dep=69   file=69   diff_ops=0  deployed'>='=2  bare'='=0

  deployed total '>= v_need' = 4 (expect 4)
  === DEPLOYED BODY LOGIC == 0015 FILE LOGIC : True ===
```

- 已部署三函数体与 0015 文件体**逐行一致（diff_ops = 0）**；`>= v_need` 共 4 处、**裸 `=` 0 处**。
- 额外用正则 `(?<!>)=\s*v_need` 在部署体上精确扫描：`bare_eq = 0 / 0 / 0`。

**A1 判定：零漂移成立，且部署态与文件态一致。无 NEW-FINDING。**

## 2. 任务 B：W1–W10 反例实测

### W1 — 分母 2 的日子铺 3 条（单天窗口，2026-09-27 周日）

```
{"den": 2, "independent_rec": 3, "hm_recorded_count": 3,
 "hm_settled": true, "hm_provisional": false, "ext_streak": 1, "ext_today_complete": false}
```
**判定 ✅**：`rec=3 >= den=2` 穿过 → `streak=1`；heatmap 该格 `provisional=false`。函数输出与初审方独立计数的 `rec=3` 一致。

### W2 — 分母 2 只铺 1 条（部分记录）

```
{"den": 2, "independent_rec": 1, "hm_provisional": false, "ext_streak": 0}
```
**判定 ✅**：`1 >= 2` 为假 → 已结算日断链 `streak=0`。**`>=` 未放水**（这是本次返工最需要守住的边界）。

### W3 — 分母 2 恰好铺 2 条

```
{"den": 2, "independent_rec": 2, "hm_provisional": false, "ext_streak": 1}
```
**判定 ✅**：等号场景行为不变 → `streak=1`（回归无损）。

### W4 — 今日铺 den+1 条（2026-09-28 周一，den=3）

```
{"den_today": 3, "independent_rec_today": 4, "hm_is_today": true,
 "ext_today_complete": true, "ext_today_provisional": false, "hm_provisional": false}
```
**判定 ✅**：今日多记不算在途 → `today_complete=true` / `today_provisional=false`（文案不再说谎）。

### W5 — 45 天连续全记录，窗口仅 30 天（F09 回归）

设置：`tracking_started_on = 2026-08-15` 且 `schedule_history.effective_from = 2026-08-15`；铺满 2026-08-15…2026-09-28 共 45 天；窗口 `2026-08-30 … 2026-09-28`。

```
{"tso": "2026-08-15", "window": "2026-08-30..2026-09-28",
 "ext_streak": 45, "base_streak_window_clipped": 30,
 "ext_planned": 73, "ext_recorded": 74}
```
**判定 ✅**：`mvp_stats_extend` 的 walk 下界是 `tracking_started_on` 而非 `p_from` → **streak=45 不被 30 天窗口裁**；同一份数据下 `mvp_stats`（下界 `p_from`）给出 30，**两个数字并存恰好证明下界语义正确**。另外 `recorded=74 > planned=73`（差 1 = 真库雷行）——**recorded 如实输出不 cap**，与 0015 裁决第 3 条一致。

### W6 — 昨日连续 8 天 + 断链墙 + 今日无记录（F12 回归）

设置：`tracking_started_on = 2026-09-19`、`effective_from = 2026-09-01`；铺满 2026-09-20…2026-09-27（8 天）；2026-09-19 留空；今日 2026-09-28 留空。

```
{"tso": "2026-09-19", "ext_streak": 8, "ext_today_complete": false,
 "ext_today_provisional": true, "gap_day_2026_09_19_rec": 0}
```
**判定 ✅**：断链墙日（已结算、无记录）确实断链 → **streak=8**；今日未记录 → `today_provisional=true`（**不提前断链**）。

### W7 — 真库雷 `p0test:anchor-f1`（不删除）

先断言雷在预期状态（防「清雷假绿」），再补 2 条正常行 → 该日 `rec = 2 + 1(雷) = 3`，`den = 2`（周四 ordinary_workday）。

```
{"landmine_assert_ok": true, "landmine_rows_live_counted": 1, "day_dow": "Thu",
 "den": 2, "independent_rec": 3,
 "strict_eq_predicate___rec_eq_den": false, "ge_predicate___rec_ge_den": true,
 "hm_provisional": false, "hm_settled": true, "ext_streak": 1}
```

**反事实双向对照**（同数据、测试内联复刻 walk，不改任何已部署函数）：

```
{"day_2026_09_17_den": 2, "day_2026_09_17_rec_live": 3,
 "COUNTERFACTUAL_strict_eq_streak": 0,     ← 旧语义 `= v_need`
 "ACTUAL_ge_streak": 1,                    ← 新语义 `>= v_need`
 "deployed_fn_streak": 1}                  ← 已部署 mvp_stats_extend 实测
```

**判定 ✅**：雷日 `rec=3 > den=2`，旧严格等号下 `3 = 2` 为假 → **streak=0**；新 `>=` 下 → **streak=1**。已部署函数实测与内联 `>=` 复刻一致（1），与内联 `=` 复刻相反（0）——**语义翻转实锤，且雷行未被删除**（`p0test:anchor-f1` 仍在原位，见 §5）。

> 方法说明：反事实用**内联复刻**而非改函数，因为「不改已应用 migration/不自行修复」是本卡的硬边界；复刻的 walk 逐字对应 0015 L302–L322 的分支结构（`v_complete := …` → `if v_complete then streak+1 else 已结算则 exit`）。

### W8 — 静态审计两件

**① 无残留等号（文件侧）**

```
'>= v_need' 行: [102, 217, 296, 314]
残留 '= v_need'（非>=）: NONE ✅
赋值 v_need := 行: [54, 55, 94, 174, 288, 306]   ← 均为 den 计算（3/2），非 complete 判定
```

全仓 grep 另发现 `20260923150000_0013_...sql:219`、`20260928100000_0014_...sql:104/182/199` 仍含 `= v_need`——**这是预期的**：0013/0014 按铁律**不得修改**，其文本保留旧等号；生效定义由后者 0015 replace 决定。**权威判据是部署体**，已由 §1.5 证明为 4×`>=` / 0×裸`=`。

**② grants 终态**

```
  cmd_get_anchor_history_v1    private   anon=False  auth=True   svc=False  pub=False
  mvp_heatmap_30               private   anon=False  auth=False  svc=False  pub=False
  mvp_stats                    private   anon=False  auth=False  svc=False  pub=False
  mvp_stats_extend             private   anon=False  auth=False  svc=False  pub=False
  get_anchor_history_v1        public    anon=False  auth=True   svc=False  pub=False
```

**判定 ✅**：三个 `private.mvp_*` 对 public/anon/authenticated/service_role **全 false**（`create or replace` 未泄漏 ACL，尾部 revoke 亦生效）；`public.get_anchor_history_v1` 与 `private.cmd_get_anchor_history_v1` **仅 authenticated 可执行**。

### W9 — `get_today_context_v1` 全链路（事务内 `set_config('role')` + owner claims）

```
{"ok": true,
 "top_keys": ["anchors","biz_date","data_revision","day_type","next_action",
              "stats","timezone","today","tracking_started_on"],
 "stats_keys": ["interval_met_count","interval_not_met_count","interval_unknown_count",
                "met_count","planned_count","recorded_count","recording_rate","scope","streak_days"],
 "stats_scope_keys": ["from","to"], "anchors_len": 3,
 "data_revision_is_string": true,
 "envelope_keys": ["ok","request_id","result","server_time"]}
```

**判定 ✅**：
- `ok=true`，`anchors_len=3`（固定三锚点）。
- 顶部 **9 键**，与 0013 `cmd_get_today_context_v1` 的 `jsonb_build_object` 逐字对应；**无新增顶部字段**。
- `stats` **9 键 = 0013 `mvp_stats` 的字段集**，**不含** `mvp_stats_extend` 专有字段（`met_rate` / `recorded_late_count` / `today_complete` / `today_provisional`）→ 证明 replace 未改变 `get_today_context_v1` 的 stats 投影面（0013 L1021 调用的就是 `mvp_stats`）。
- `data_revision` 为**字符串**（BIGINT 服务端转字符串纪律）。
- 提示词列举的形状里含 `versions`/`server_time`，实测**顶部不含**这两键（`server_time` 在信封层，`versions` 不存在于本函数）；以实测 9 键为准，属提示词列举的近似表述，非缺陷。

### W10 — 未开始日（2026-09-15，早于 `effective_from=2026-09-21`）

```
{"plan_is_null": true, "hm_not_started": true, "hm_denominator": 0, "hm_has_data": false,
 "hm_provisional": false, "stats_planned": 0, "stats_recorded": 0,
 "stats_recording_rate_is_null": true, "stats_streak": 0}
```

**判定 ✅**：`denominator=0` / `not_started=true`；**不进** planned/recorded 统计；`recording_rate=null`；`provisional=false`（**不涂失败色**）。

## 3. 附加独立确认（超出清单）

- **前端与 Core 语义已一致**：`assets/js/heatmap.js:52` → `if (den > 0 && rec >= den) return met >= den ? 'full-met' : 'full-unmet';`。即 UI 侧本就是 `>=`，本次把 Core 的 walk/今日判定**对齐到 UI**，方向正确（而非把 UI 改窄）。三方（heatmap 格 / extend walk / today 判定）现已同一语义。
- **`recorded_count > planned_count` 如实输出**（W5: 74 > 73）——无 cap、无隐藏。
- **部署体与 0015 文件体逐行一致**（§1.5）——0015 确已落库，且不存在「文件改了但库没变」或反之的情形。

## 4. NEW-FINDING

### NEW-FINDING-1（P2 / 非阻断 / M1 不可达）— 「跟踪起日」有两个事实源：`tracking_started_on` 与 `schedule_history[].effective_from`，二者若分歧，streak walk 会静默提前退出

**实测**（只回拨 `tracking_started_on`，保持 `effective_from=2026-09-21`）：

```
{"tso_backdated_to": "2026-08-15",
 "schedule_effective_from": "2026-09-21",
 "plan_2026_08_20_is_null": true,        ← 08-20 落在 tracking 起日之后，但无计划
 "plan_2026_09_24_is_null": false,
 "streak_with_divergent_settings": 7}
```

`private.resolve_day_plan` 的门控条件是 `schedule_history[].effective_from <= p_date`（0013 L66），**不是** `tracking_started_on`。因此当 `tracking_started_on` 早于最早 `effective_from` 时：
- 中间那段日期被判为「未开始日」（`mvp_heatmap_30` 的 `v_plan is null` 分支）；
- `mvp_stats_extend` 的 walk 在 `exit when v_plan is null`（0015 L305）处**提前退出**，streak 被静默截短（上例实测 7，而非按 `tracking_started_on=08-15` 一路回走）。

上例注释亦印证设计意图与实现对不齐：0013 L53 注释写「**tracking_started_on 后每一天**都有默认计划…起日前返回 null」，而实现读的是 `effective_from`。

**为什么判 P2 非阻断**：
1. **0015 未引入**该耦合——它是 0013 `resolve_day_plan` 的既有设计；0015 只改了 4 处比较符（§1.5 证明）。
2. **M1 不可达**：`tracking_started_on` 与 `effective_from` 由 `0008 cmd_initialize_workspace_v1` **同源写入**（`'effective_from', v_date`，其中 `v_date := (v_input ->> 'tracking_started_on')::date`，0008 L472/L482），初始化后二者恒等；M1 没有修改 `tracking_started_on`/`schedule_history` 的命令（全仓 grep 无第二处写入），故不存在分歧路径。
3. 后果为**统计口径偏短**（streak 少算），非数据损坏、非越权、非静默丢写。

**建议（随未来「改日型计划 / 改起日」类命令一并处理，非本卡返工项）**：该命令落地时须保证 `schedule_history` 至少一段 `effective_from <= tracking_started_on`；或把 walk 的下界判据统一为「计划存在性」并把 `tracking_started_on` 降级为展示字段。**本卡无需改动。**

**不构成 ARCHITECTURE ALERT**：未触发对已批准分支的偏离，也无需 apply 新 migration。

## 5. 边界纪律与残留自查

### 5.1 零持久写（时间维度正证）

所有探针均在 `do $$ … $$` 内以 `RAISE EXCEPTION` 结束 → 隐式事务整体回滚。会话内**没有任何一行**在后端落库：

```
now_utc                2026-09-28 09:01:04
act_max_created        2026-09-28 07:27:10   ← 早于初审会话（约 08:53 UTC 起）
rcpt_max_created       2026-09-28 07:27:10
life_max_created       2026-09-23 10:57:50
life_max_updated       2026-09-23 13:46:15
act_rows_last40m       0
rcpt_rows_last40m      0
life_rows_last40m      0
```

最近 40 分钟（覆盖整个初审窗口）三张表**新增 0 行**；`activity_log` / `request_receipts` 的全局最大 `created_at` 停在会话开始**之前**（07:27:10 UTC）。

### 5.2 提示词要求的显式残留自查

```
wb_erl_rows          0        ← 要求为 0 ✅
life_data_total      8        ← 会话开始基线同为 8 ✅
tracking_started_on  2026-09-21  ← 要求为 2026-09-21 ✅
sched_segments       1        ← 基线 1 ✅
settings_version     1
data_revision        457
activity_rows        188
receipt_rows         113
clients              6
```

**ZERO RESIDUE = true。**

### 5.3 真库雷未被清除

```
[{"entity_key":"p0test:anchor-f1","biz_date":"2026-09-17","planned":"true",
  "actual":"2026-09-17T06:47:00+08:00","tomb":false}]
```

### 5.4 仓库纪律

```
$ git status --short
（空）
```

- **未改**任何代码 / migration / 测试 / `result.md` 正文；本卡产出仅为**新建**的本文件。
- **未碰** `task-index`（PASS 翻牌归 Hermes 最终签核）。
- 未 apply 任何 migration；未执行超出已批准分支的动作 → **无 ARCHITECTURE ALERT 需上报**。

## 6. 初审方自身纠错（诚实记录）

初审过程中修掉 **2 处自身工具缺陷**，均已定位且**不作为缺陷申报**：

1. **函数体切片 bug**：首版比对脚本用 `rfind(同一 start 分隔符)` 取结束位置，导致「文件体」切片为空（`file=0`），误报 diff。改为 start/end 双分隔符后，实测 **diff_ops=0**（§1.5）。**此前的「不一致」是脚本 bug，不是漂移。**
2. **W5/W6/W7 最初只回拨 `tracking_started_on`**，`resolve_day_plan` 仍返回 `null`，会让「未开始日」污染 streak（W6 会得 7 而非 8）。补回拨 `schedule_history.effective_from` 后符合期望——这一发现即 NEW-FINDING-1 的实证来源。

## 7. 初审结论

**MVP-004 返工（0015）：PASS**

- **任务 A**：变更**恰为 4 处 `=` → `>=`**（L102/L217/L296/L314），行数两侧全等、签名未变、无新增 grant/无 schema 改动；**部署体与文件体逐行一致**，无多改、无漏改、无顺序变化。
- **任务 B**：W1–W10 **全部实测符合期望**，含 W2「`>=` 不得放水」与 W7「真库雷日穿过」这一对**互斥边界的双向验证**；W5/W6 回归 F09/F12 成立。
- **NEW-FINDING 1 条（P2 / 非阻断）**：`tracking_started_on` 与 `effective_from` 双事实源耦合，M1 因同源写入而不可达，建议随未来「改计划/改起日」命令处理。
- **零持久写**已按时间维度与本卡要求的显式自查双重证明；真库雷未被清除。

**初审方提交物**：本文件（新建，唯一产出）。

---

# Hy4 视觉复核（MVP-004 热力图）

- 复核模型：Hy4 · 日期：2026-09-28 09:04 UTC
- 判定对象：heatmap-1280/375/320.png（第一轮截图，heatmap.js 返工未改动）
- 复核方式：三张截图整体判读 + 热力图区域裁剪放大 + 图例色块像素采样（只读，未改任何代码；未重拍截图）

| # | 检查项 | 判定 | 理由 |
|---|---|---|---|
| 1 | 五态区分可辨 | FAIL | 网格内实际出现的 3 态（未开始虚格 / 未记录灰底 / 今日蓝框）在 1280/375/320 均清晰可辨，320 下网格折为 6 列、格约 40px、日期数字仍可读；但图例中「记全·有未达标」与「未开始」两个色块被渲染为几乎相同的「白底浅灰实线边框方块」（像素采样证实：两块边框均为灰 `(217,217,222)`~`(223,223,227)` 系、顶边均为连续实线），六态中这两态在图上不可区分，且均不代表其真实格子的色态。另注：部分记录 / 记全·有未达标 / 全记录且达标三态未出现在本轮真实数据里，仅图例可见，其格内区分度无法由本组截图验证。 |
| 2 | 文字补充齐全 | FAIL | 图例 6 项齐全，文案与五态语义表一一对应；但「记全·有未达标」色块缺失暖色描边（应为 2px 橙，实渲染 1px 灰），「未开始」色块缺失虚线（应为 dashed，实渲染 solid）。根因为 `app.css` 声明顺序：`.hm-swatch`（409 行）的 `border` 简写同优先级覆盖了先声明的 `.hm-s-full-unmet` / `.hm-s-notstarted`（394/390 行）。后果：一旦真实数据出现「记全·有未达标」格子（2px 橙描边），用户无法与图例匹配，图例与色态不再一一对应。死角记录：格子层面「全记录且达标 vs 未记录」（橙实底 vs 灰实底）、「记全·有未达标 vs 今日/在途」（橙描边 vs 蓝描边）仅靠色相区分，格子内文字只有日期数字，状态文字仅在 aria-label/title（屏幕阅读器可读，视觉静默场景不可读）。 |
| 3 | 不抢主区 | PASS | 热力图位于三锚点卡片之下独立成卡；「近 30 天」标题（0.95rem muted）与统计行（0.9rem）明显弱于主区卡片标题与打卡按钮的层级；网格低饱和浅色、密度低，视觉权重正确让位。1280 图上半部分三锚点主区地位明确。 |
| 4 | 无横向滚动 | PASS | 375 与 320 截图内容均完整收在一屏宽内，右缘无截断（含页脚探针文字，仅换行不溢出）；网格 auto-fill 自适应换行（320 下 6 列），图例换行为多行不溢出。 |
| 5 | 色弱可读性 | PASS（带保留） | 橙实底（实测约 `rgb(217,123,43)`）与浅灰底：明度+彩度双通道差异，蓝黄轴在 deuteranopia/protanopia 下保留，可区分；部分记录为 135° 对角半填（图案通道独立于颜色）；暖描边 vs 蓝框走蓝/橙对比轴，为 CVD 最安全色对。保留项（仅凭颜色/去色会产生歧义的两组组合，记为发现交 Hermes）：①「全记录且达标(橙实底) vs 未记录(灰实底)」去色后同为实底；②「记全·有未达标(橙描边) vs 今日/在途(蓝描边)」去色后同为描边。去色场景下格子内仅日期数字，状态信息不完整——基础可读达标，但上述两组建议后续增加形状/符号冗余。 |

## 结论

> **FAIL**（第 1、2 项 FAIL，第 3/4/5 项 PASS）
>
> - FAIL 根因同一、**非阻断**：`assets/css/app.css` 中 `.hm-swatch` 定义在状态类之后，`border` 简写覆盖了图例色块的 `2px 暖色描边`（记全·有未达标）与 `dashed`（未开始），导致图例两个色块失真且彼此近乎相同。当前真实数据（记录率 0%）不出现「记全·有未达标」态，暂未造成实际误读；一旦出现达标/未达标数据即会影响判读，建议 Hermes 尽快转修复任务（将状态类移到 `.hm-swatch` 之后、或提升状态类优先级，一处小改）。
> - 附带发现（非判定项）：本轮数据只覆盖 6 态中的 3 态，「部分记录 / 记全·有未达标 / 全记录且达标」的格内表现无真实截图佐证，建议 Hermes 安排一次含全态 fixture 的验证截图；本组截图本身仍有效，无需重拍。
> - 按边界纪律：以上均为记录，未改任何代码/CSS/测试，未重拍截图。
