# M1-HANDOFF（草稿，04-acceptance §5 模板）

> draft：由 MVP-006 工程窄验收段生成；A26/A27 为 PENDING，状态 ENGINEERING_READY（非 M1_COMPLETE）。
> 7 天真实使用窗完成后由段二更新为最终版。

```text
状态：ENGINEERING_READY
release commit / HTML hash / Pages URL / 本地文件：
  待本段 commit（见 result.md §1 变更清单，dist 与 evidence 同一 commit 推送）
  HTML sha256 58d89c5f142208a723aea0b9a249972a276d028f6a96ea6cbf33cae2a025de7c（mvp-006-4624e4dc3237，--check ×2 REPRODUCIBLE）
  Pages https://levner01.github.io/Morrow/（workflow 模式，push dist 自动部署；发版对账 result.md §2.3）
  本地文件 /Users/wangxinkai/Documents/Morrow/dist/index.html（file:// 实测：Auth/RPC/storage 恢复全通，result.md §2.4）
migrations及目标项目引用（无密钥）：
  0001–0015（supabase/migrations/，0005 起版本化迁移；0015 为 MVP-004 返工 complete 语义 >= 统一）
  项目 ref umutubzcwwmmbxfjkyvj.supabase.co（PAT/凭据均 keychain -a morrow，不入 repo）
A01–A28状态与证据链接：
  A01–A15 P0 段全 PASS：evidence/P0-003..P0-009/ 各 result.md
  A16 PASS：evidence/MVP-006/regression-mvp004-stats.json（15/15）+ regression-mvp001-keyproofs.json（8/8）
  A17 公司机 PASS / 家机 NOT_RUN（BLOCKED-OWNER）：evidence/MVP-006/dual-device-evidence.md
  A18/A19/A20 PASS：evidence/MVP-006/regression-mvp003-fault.json（7/7 ALL PASS，含基建修复记录 result.md §4）
  A21 PASS：regression-mvp004-stats.json（15/15）+ regression-mvp004-heatmap-ui.txt（19/19）
  A22 CDP 320/375/1280 无横滚 PASS（mvp004-ui 19/19 + mvp005-ui T6 双覆盖）；真实手机 PENDING-OWNER
  A23/A24/A25 PASS：regression-mvp005-export-core.json（9/9）+ regression-mvp005-pipeline.txt（51/51）+ regression-mvp005-ui.json（41/41，counts 随真实库浮动为结构性断言）
  A26 PENDING（段二，7 天真实使用窗未开始，无冒充记录）
  A27 工程侧现状达标：最近 7 天 health 成功 4 次 ≥3（req_id 前 8 位 9d45127d/b03f1858/dea98d29/f52fd876）；完整窗 + 每日调度配置随段二
  A28 PASS：grep phase1 仅 0002 L28 注释一行（非代码）；git log 零 Phase1 commit（result.md §3）
  A13 发版后重测 PENDING（result.md §2.3 联动补记）
公司机/家机/实际手机证据：
  公司机 2026-09-29 填实（M4 Max / macOS 26.3.1 / Chrome 154.0.8037.58，双机表）
  家机/实际手机 BLOCKED-OWNER（dual-device-evidence.md 回传区已留位）
连续7天真实使用窗口与表：
  窗口未开始（PENDING）；表模板 04-acceptance §4，段二按实际日期逐日填
记录数/计划数/记录率及计算版本：
  以 Core（mvp_stats / mvp_stats_extend，0015 >= 语义）为唯一计算口径；9/21–9/29 真实使用 8 天在库（9/23 ×4 行为最早真实记录，key-proofs T00 引用）；完整记录率随 7 天窗出数
最近7天health成功时间与审计ID：
  成功 4 次（7 天窗 ≥3 达标）；审计 request_id 前 8 位 9d45127d / b03f1858 / dea98d29 / f52fd876；逐次时间戳明细为 Review 可选自查（result.md §5）
全量导出校验与脱敏样本：
  41/41 E2E：真实下载 99.7 KiB、data_sha256 b118af09…654e、revision=479 字符串、secret-scan []、多页 110 游标请求整页全等、断网零半包；脱敏样本 evidence/MVP-005/sample-export.json
独立Review人/模型/结论：
  MVP-001~005 已各自独立 Review PASS；MVP-006 停等 Review（result.md §9 签核区留白）
P0/P1未解决数（必须0）：
  0（MVP-004 返工 26628ec 已闭环：0015 四处 complete 语义统一，ARCHITECTURE ALERT 留档待签核）
P2及责任人：
  无新增 P2
回滚/恢复/凭据轮换说明：
  docs/operations/deployment-recovery.md（含 Pause/Resume、会话丢失、草稿另存、配置备份、版本回退——按 release manifest hash 回退上一发行 mvp-005-4624e4dc3237/6a23e56c）
  凭据轮换经 Dashboard + keychain 更新，PAT 不入任何文件
Phase1：LOCKED；14天/80%/本人确认各自状态：
  LOCKED（A28 举证）；14 天窗 PENDING；记录率 ≥80% 门禁 PENDING；凯哥本人确认 PENDING（三者齐备方可开工，缺一不可）
```
