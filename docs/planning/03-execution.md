# Morrow — Phase 0 / MVP 施工与自治交接

## 1. M1授权范围和交接规则

凯哥已确认M1=Phase0+MVP。当前产物仅架构、合同、任务、验收和运维计划；不在本次提前写产品实现、migration或部署。首个开发任务从P0-001开始。

**Codex在M1完成前退出日常施工链路。** 原始分工中“高风险→Codex”在本轮改为：Codex现在冻结架构与测试约束，高风险实现由Trae+Kimi K3负责，Hermes+GLM-5.3深审，WorkBuddy+DeepSeek V4.1 Flash做独立反例初审。作者与最终审查者不得是同一模型；廉价初审不能代替Hermes的GLM-5.3深度签核。可改用WorkBuddy+Hy4做辅助交互复核，但不能替代安全审计。

**不存在M1之前“等Codex批准才继续”的节点。** 阻塞时按下文处理，不能以降低安全验收标准替代架构决策。M1完成后，Codex可按一个证据索引快速复核，无需重新读全部施工对话。

## 2. Agent分工与模型路由

模型可用性依据凯哥提供的资源清单；本次未登录验证各环境，没有模型性能基准结论。

| 工作 | 执行 | Review | 理由 |
|---|---|---|---|
| 架构冻结/范围裁决 | Codex（本次） | 独立产品与安全预审 | 消除施工歧义后离场 |
| DB/权限/事务/凭据 | Trae + Kimi K3 | Hermes + GLM-5.3；WorkBuddy再审高风险证据 | 高风险集中，跨模型签核 |
| 普通JS与页面 | Trae + Kimi K2.7 Code | WorkBuddy + DeepSeek V4.1 Flash | 小上下文单任务施工 |
| 统计/较复杂导出 | Trae + GLM-5.3 | Hermes + DeepSeek V4 Pro | 不由同模型自审 |
| 简单脚本/说明/清单 | Trae + GLM-5.3 Flash | WorkBuddy + DeepSeek V4.1 Flash | 降低成本 |
| 调度/长程验证 | Hermes + Kimi K3 | WorkBuddy + GLM-5.3 | 独立运行证据 |
| UI验收 | WorkBuddy + Hy4 | Hermes + GLM-5.3复核功能遗漏 | 视觉与行为都检查 |
| M1联合签核 | Hermes + GLM-5.3主审；WorkBuddy + Hy4做UI见证 | 作者修复后由非作者重新验 | M1无Codex等待节点 |

若指定模型不可用，只从凯哥列出的模型中替换，遵循“安全/复杂任务Kimi K3或GLM-5.3、简单任务Flash、审查异模型”的级别；把替换写入任务收据。不能仅凭模型名字当作质量保证。

## 3. 最低上下文交接协议

每个任务已拆成独立文件，含目标、输入、依赖、范围、禁止项、验收、执行/Review和风险。复制完整任务卡给执行Agent，卡内指向精确合同章节；不要求它重读两份产品全文。Review拿任务卡、diff、测试输出、相关合同，不喂整个施工聊天。

每个Task建立 `docs/planning/evidence/<TASK-ID>/result.md`，必须填写：

```text
任务/commit/执行环境/模型/UTC时间
前置依赖及其证据路径
变更文件与行为摘要
验证命令或手工操作 + exit/status + 原始输出文件链接
失败/待验证/修复项
Review作者/模型/结论(PASS 或 BLOCKED)/证据
涉及真实账号或网络的已脱敏说明
交接下一任务
```

严禁把未跑测试写PASS；只写“代码看起来对”不足签核。平台不可达、家机未测、实际使用天数未满都填BLOCKED/PENDING，不写N/A绕过DoD。fixture、mock、真实生产分别标明。

提交粒度一个任务一个可review逻辑提交，修复可加提交；不自动squash用户历史。P0-001先判断是否有git与现有远端，不能覆盖已有配置。无需现在创建GitHub仓库、连接账号或推送。写migration任务使用唯一集成者；同一阶段不并行改同一migration。严格15步是最低风险关键路径，独立Review可并行，但不能跳过前置门禁提交后续阶段功能。

## 4. Phase 0 Work Breakdown

| 顺序 | Task | 目标 | 风险 | 依赖 |
|---|---|---|---|---|
| 01 | [P0-001](tasks/P0-001.md) | 仓库、环境、状态与证据约定 | Low | 本施工包 |
| 02 | [P0-002](tasks/P0-002.md) | 真实Supabase/Auth/网络可行性探针 | High | P0-001 |
| 03 | [P0-003](tasks/P0-003.md) | Schema、JSON合同与migration基础 | High | P0-002 |
| 04 | [P0-004](tasks/P0-004.md) | 权威Core事务/身份/授权/审计骨架 | High | P0-003 |
| 05 | [P0-005](tasks/P0-005.md) | 安全与并发反例测试、修复闭环 | High | P0-004 |
| 06 | [P0-006](tasks/P0-006.md) | 静态登录/失败壳与单HTML发行 | Medium | P0-005 |
| 07 | [P0-007](tasks/P0-007.md) | health客户端、撤销、真实常驻调度 | High | P0-006 |
| 08 | [P0-008](tasks/P0-008.md) | 双机Pages/HTML实测与恢复runbook | Medium | P0-007 |
| 09 | [P0-009](tasks/P0-009.md) | Phase0证据汇总与门禁 | High | P0-008 |

## 5. MVP Work Breakdown

| 顺序 | Task | 目标 | 风险 | 依赖 |
|---|---|---|---|---|
| 10 | [MVP-001](tasks/MVP-001.md) | 锚点/日型计划与语义业务实现 | High | P0-009 |
| 11 | [MVP-002](tasks/MVP-002.md) | 今日行动页、记录和配置交互 | Medium | MVP-001 |
| 12 | [MVP-003](tasks/MVP-003.md) | 三态同步、断网草稿、重试竞态 | High | MVP-002 |
| 13 | [MVP-004](tasks/MVP-004.md) | 30天热力图、准确连续与指标 | Medium | MVP-003 |
| 14 | [MVP-005](tasks/MVP-005.md) | 全量无凭据JSON导出 | High | MVP-004 |
| 15 | [MVP-006](tasks/MVP-006.md) | 集成发布、7天真实使用、M1验收 | High | MVP-005 |

每个完整Task卡在tasks目录。不得把一个表格行当全部执行指令。

## 6. Gate与失败处理

### Gate-P0：P0-009才能批准

- 完成唯一owner/Auth；anon与非owner数据不可见；direct DML/private凭据/伪造actor拒绝。
- 两个设备有实际可用路径；Supabase失败页面不白屏。
- version并发、audit/receipt事务、human幂等、Agent OCC内部框架测试有真实PG证据。
- schema/业务协议V1冻结；未来业务Agent路由未开放。
- 至少一个常驻health Agent已注册，实际调度执行有数据库审计；配置每日运行，最低每周≥3次。Phase0不凭空要求等一整周才可进入MVP；至少一个**由调度触发**的成功+持续日程证明成立，运行一周的频率在M1验收补齐。
- 暂停识别/人工Resume和token轮换runbook齐全。Keepalive不能保证永不暂停。

### Gate-M1：MVP-006才能批准

- Gate-P0全部仍有效；发布后A记B刷新及B记A刷新成功。
- 三个锚点、今日、日型基础、30天图、三态同步、手机响应式、全量JSON导出全部通过。
- 断网/刷新/恢复不静默丢草稿，LWW和重试均按合同，手机无横向滚动。
- **连续真实使用≥7天**。工具生成的测试数据不算；记录哪天实际使用、哪个发布版本、缺陷影响和凯哥反馈。若中断或核心流程不可用，连续窗口重新计算；普通不影响记录的小bug注明即可。
- 滚动7天health成功≥3次、至少一次实际定时执行、凭据无泄漏。
- 高风险项异模型独立审查PASS；没有未解决P0/P1缺陷。缺陷优先级：P0安全/数据丢失/错误放行；P1核心流程失败或统计错误；P2不阻断的交互细节，需明确owner和后续任务。

Gate-M1通过后状态 `M1_COMPLETE / PHASE1_LOCKED`，停止扩功能。可形成给Codex的可选事后复核包，不能在此前留待Codex签核。

### Gate-Phase1：单独产品门禁

上一阶段连续真实使用至少14天（可包含前7天），同窗口锚点记录率至少80%，凯哥本人明确确认阶段成立。未收到本人确认即LOCKED；审计Agent不能替人决定。规则在以后每个Phase入口继续执行。

### 不需回到架构师的局部决策

可以：修bug、补验证、调整间距/字重、固定依赖补丁版、适配项目当前CLI、优化已测索引、使用HTML失败后的loopback分支、修正任务产物路径。

不可以：迁移后端、去掉RLS/OCC/幂等/日志、给Agent开放SQL、上新模块、自动重放离线草稿、将动态模板回写历史、跳过真实双机/7天证据、借M1提前实现PWA/通知/业务MCP。

发现不可行按 `ARCHITECTURE ALERT` 写证据、影响、已排除方案、最小可逆建议。Trae施工负责人和Hermes审计者先按已批准fallback处理；需账号/设备/公开发布授权时仅请凯哥完成具体动作，不要求重新讨论产品。超出主方案且无已批准分支时冻结受影响任务，提交明确决策题给凯哥；不能为了“无人值守”擅自越过硬约束。M1未真正完成就保持BLOCKED，不伪造完成。

## 7. 首次开工所需外部输入（不把秘密写进表）

在P0-001/002填写 `docs/runtime-environment.md` 的**非敏感**信息：目标Supabase project_ref/URL、owner邮箱或脱敏标识、owner UUID、GitHub仓库与Pages URL、公司/家机浏览器版本、常驻Hermes运行宿主/时区/可用时段、发行物传递方式。

密码、access/refresh token、service_role、DB连接密码和Agent原始token只走各平台secret store/安全登录。调度宿主不在线就不满足“常驻”；让凯哥指定真实宿主，不能假设当前Mac永远开机。平台收费升级、公网隧道、新外部消息渠道须按用户授权另处理；本施工包不自动创建这些外部副作用。

## 8. 发布、恢复与运行指引（施工填写真实值）

- P0-002核对当前CLI/SDK/PG扩展版本，锁在manifest/lockfile。不要凭本规划日期猜版本。
- P0-006固定源HTML+资源清单；单文件发行包包含public配置和SDK，不含secret；hash与git commit对应。Pages与本地包均从同一源产出。
- P0-008在公司机、家机分别测试真实发布URL和下载HTML：壳→登录→查RPC→Human health客户端管理RPC创建/停用临时客户端并读取配置→断网错误→重试→草稿存储probe。curl只证明网络，不证明UI/Auth。
- 浏览器测试必须看console/network和可见页面，记录user-agent、路径、时间、网络条件、发布hash，输出脱敏；截图不能含token/session/password。
- 生产写失败先保留草稿与trace，查供应商状态和项目状态。若Dashboard明确暂停，选项目→Resume project→Confirm（以当前UI为准），再跑health和Human登录读写；不要为演练主动暂停生产。
- 回滚前先导出当前数据；失败migration在隔离库验证前向修复；禁止为“回滚”删除历史记录。HTML可回退到兼容schema的前版，旧客户端不兼容时只读/导出。
- Keepalive每日本地固定时间07:00 Asia/Shanghai，设总体timeout30s，失败最多3次尝试（1/3/10s退避，总deadline）；宿主记录退出码和trace。只在有意义失败/恢复/过期需操作时通知，成功不刷消息。未经授权不向第三方发消息；通知可在任务状态显示。
- 本地file存储按浏览器和文件路径隔离，发行更新前先导出未同步草稿；新文件未核验草稿前不删旧文件。loopback路径作为已批准备用，使用固定127.0.0.1端口与同一发行HTML，P0-008登记实际值。

## 9. M1返回包（给凯哥及事后Codex）

`docs/planning/evidence/M1-HANDOFF.md` 包含：release commit/hash、Pages链接/本地HTML、执行的migration清单、8项关键能力结果、真实双机证据、7天表、记录率计算明细、定时运行记录、导出样本校验结果、所有独立Review、未解决P2、回滚方式、Phase1门禁当前状态。不要附token或整段开发聊天。

## 10. 原始要求追踪

| 原要求 | 架构/合同 | 施工/验收 |
|---|---|---|
| V2 §1.1/1.2锚点与行动页 | AD07、C02/03、前端§8 | MVP001/002/004；F01–F14；UI证据 |
| V2 §2 Schema/version | 架构§3、C01/02/04 | P0003/004/005；T03/04 |
| V2 §3 Human/Agent一致性 | AD06、C04/07 | P0005、MVP003；T01–T10/T13/14 |
| V2 §4/5 Agent Native/权限 | 架构§4/5/7、C06 | P0004/005/007基础；业务Phase2 |
| V2 §6 Web/降级/keepalive | AD02/04、失败矩阵 | P0002/006/007/008；GateP0/M1 |
| V2 §8 MVP export | AD08、C08/09 | MVP005；分页/密钥扫描/校验 |
| V2 Phase门禁 | 本文§6 | P0009、MVP006及后续本人确认 |
| 工程包U1–U7/D1–D9/压力点 | AD01–09、架构§11 | 对应任务与待验证，不继承错误阶段门禁 |
