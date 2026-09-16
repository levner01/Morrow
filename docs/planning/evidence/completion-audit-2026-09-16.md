# 开工前职责完成审计 · 2026-09-16

## 审计范围

原始目标是完成M1之前的产品技术架构、合同、施工分工与交接；凯哥已确认M1=Phase0+MVP，且明确Codex在施工期间不介入。因此，本审计的完成对象是**开工前职责**。15项开发任务由后续施工Agent执行，本报告不将它们标为完成，也不以架构文档替代产品验收。

审计依据：原始任务附件、产品V2、工程前置分析包、2026-09-16当前项目文件。两份原文逐字节SHA256与2026-09-15快照一致；现场无git仓库、无产品代码、无migration、无产品测试结果。未启动外部账号、部署或调度。

## 原附件逐项验收

| 原要求 | 当前实质内容及证据 | 结论 |
|---|---|---|
| 一：文档优先级 | 01开头、AGENTS；V2优先；纠正工程包将14天门禁前移的冲突 | 完成 |
| 二：产品架构/Core/Repository | 01 AD01/02、§1/2/5；唯一SQL Core，多入口复用，原生静态源与单HTML发行 | 完成 |
| 二：Schema/RLS/Auth/凭据 | 01 §3/4；公开业务/私有凭据、owner、grants、锁序、撤销；02 C05.1补全管理参数 | 完成 |
| 二：MCP/HTTP/同步冲突 | 01 AD06/09、§6/7；02 C04/06/07；业务Agent Phase2才开放 | 完成 |
| 二：Web/PWA/Mobile演进 | 01 §1/2/8，PWA和原生端口延Phase3，不重写业务Core | 完成 |
| 二：导入导出/Activity/Test | 01 AD08、§3.6/10；02 C08/09；04验收矩阵；Restore只冻合同 | 完成 |
| 二：拆解/分工/后续预留 | 03、15张Task卡、05序列；高风险异模型深审，无Codex等待节点 | 完成 |
| 三：已确认硬约束 | Supabase、三锚点、单用户、双协议、Agent语义入口、LWW/OCC、DB trigger、RLS/log/export均在01/02；本轮无违约实现 | 完成 |
| 三：阶段/视觉/不提前实现 | 01分期矩阵/前端§8；03 Gate；仅规划文件，无未来功能代码 | 完成 |
| 四：Architecture Decisions格式 | AD01–AD09每项含Decision/Why/Rejected/Impact，裁决未决问题而不重做产品 | 完成 |
| 五.1 Target Architecture | 01 §1图涵盖所有指定组件；实线/虚线和分期表区分建设与预留 | 完成 |
| 五.2 Repository Architecture | 01 §2目录和职责；contract单源、migration快照/hash与增量管理 | 完成 |
| 五.3 Database Architecture | 01 §3含五张指定表及基础表字段/类型/键/索引/校验/trigger/delete；RLS在§4；版本在AD05/C09 | 完成 |
| 五.4 Identity & Security | 01 §4及02 C05.1/C06；Human/Agent分别说明，最小权限；成功/重放也按read scope | 完成 |
| 五.5 Application Core | 01 §5职责表和调用边界；事务/规则唯一实现位置已选定 | 完成 |
| 五.6 Sync & Consistency | 01 §6、02 C04/07覆盖首次加载、optimistic、debounce、LWW/OCC、trigger、幂等、重试、离线、删除、多端刷新 | 完成 |
| 五.7 Agent Interface | 02 C06最小8工具、HTTP映射、Context授权与错误；01 AD09明确Local到Remote | 完成 |
| 五.8 Frontend | 01 §8包含今日/锚点/热力图/日型/三态/设置导出、Component/State/DataAccess/响应式 | 完成 |
| 五.9 Failure & Recovery | 01 §9四列表覆盖9个必需故障，并补scope/storage/tombstone/版本不兼容 | 完成 |
| 五.10 Test Architecture | 01 §10的Unit/Integration/RLS/Sync/Conflict/Agent API/E2E分M1与后续；04给可观察结果 | 完成 |
| 六：Phase0与MVP任务 | 9张Phase0+6张MVP，所有卡有目标/依赖/输入/范围/不做/验收/执行/Review/风险 | 完成 |
| 六：单卡可独立施工 | 15张卡自带最低上下文、精确引用、产物/回执；P0-003引用缺口与record_open归属已修 | 完成 |
| 七：四环境分工 | 03分工表与每卡，使用凯哥提供模型清单，注明未实测性能；异模型Review | 完成 |
| 八：严格First15 | 05按01–15逐项给目标/执行/Review/下一步；task-index顺序一致，链接到完整卡 | 完成 |
| 九：表达及交付边界 | 中文工程文档；有理由、单主方案、失败fallback、待验证标记；无完整UI或migration代码 | 完成 |
| 补充：M1前无需Codex持续介入 | 03 §1/3/6规定独立签核、局部决策、阻塞处理和M1返回包；不移交架构未决题给施工者猜 | 完成 |

以上“完成”指已给出可执行设计/责任/验收合同；不是后续施工测试PASS。

## 工程包未决问题映射

| 原项 | 裁决与后续责任 |
|---|---|
| D1 Core部署 | AD01：私有PG语义Core，Human RPC，Edge Agent适配 |
| D2 Credential | AD03、§4、C05.1：独立opaque token+private hash，生命周期已定 |
| D3 Local MCP | AD09：官方TS SDK+Node stdio，Phase2验证锁版 |
| D4 HTTP Host | AD04/§7：Supabase Edge；仅实际失败启用受信host fallback |
| D5 Payload | AD05、C01/02：M1严格schema，未来模块按阶段冻结 |
| D6 连续计算 | §5/C03：Core SQL，超过30天不截断 |
| D7 Restore | AD08/C08：格式与dry-run语义先定，M1不实现导入 |
| D8 PWA离线 | AD08/§8/C07：离线壳+明确草稿，无自动离线写同步 |
| D9 语言Runtime | AD01/02/09、§2：PG Core，前端JS、Edge TS/Deno、MCP Node |
| U1 Pages家机 | P0-002初探，P0-008真实发行物双机验证 |
| U2 PWA能力 | 01 §11：不在P0提前实现PWA；Phase3验证安装/通知，M1保留模块边界 |
| U3 Edge | P0-002真实project探针；失败进入已批准host分支，不虚报可用 |
| U4 entity_key | C01逐module模板，P0-003固化schema/fixtures |
| U5 导出容量 | C08及MVP-005：500行分页、1001行/10000日志、25MiB保护和一致性检测 |
| U6 家机代理 | P0-008，仅失败后验证，不改全局代理；本地HTML/loopback为fallback |
| U7 Activity UI | M1只日志与导出，Timeline UI Phase1 |

## 12个Architecture Pressure Points

1. 无构建链与Mobile：分层源+统一发行物+Core远程复用，AD02/§2/8。
2. JSONB查询：date/module/key真正列化、针对访问模式索引，§3.1。
3. payload_version：C02/C09模块独立payload_v。
4. Web与Agent语义分裂：共用私有PG Core，§5。
5. Local→Remote MCP：仅换传输，AD09/C06。
6. LWW与OCC：统一事务，不同策略由可信身份决定，C04。
7. Token生命周期：C05.1+§4，撤销串行，P0-004/005/007。
8. RLS：grants、owner、definer权限矩阵，P0-005；不拿200空数组当泄漏。
9. 全局schema_version：文件/模块/API/migration独立版本，不冗余逐行结构版，AD05/C09。
10. Timeline增长：分页cursor，未来按实际负载演进；不提前partition，C06/§3.6。
11. Export/Restore不对称：C08完整格式、逻辑引用、禁恢复凭据，实施延期清楚。
12. Keepalive真查询：AD04/P0-007真实数据库查询+审计，免费层无绝对防暂停承诺。

## 本轮补完内容

- health管理参数、启用/撤销/轮换与创建幂等锁序。
- read:advice声明；成功/重放按当前read scope裁剪，新增S09。
- P0-003补足命令/响应合同引用。
- MVP-001明确record_open_v1实现与跨请求key的每日device去重。
- First15段落排版与planning_version=1.1。

## 待执行产品工作（没有被本报告伪装成完成）

全部P0/MVP任务仍PLANNED。真实Supabase、账号/凭据、双机可达性、PG权限与并发、发行HTML、Keepalive实际执行、MVP功能、7天使用证据都由任务卡继续执行。它们属于已交接施工职责；没有这些证据，M1状态不能为COMPLETE，Phase1保持LOCKED。

## 当前静态校验

68 项当前静态检查，68 项通过；44 个本地Markdown链接均检查。全部15项产品任务仍PLANNED。

| 检查 | 结果 |
|---|---|
| 15项任务及9/6阶段分配 | PASS |
| 规划1.1且施工未开始 | PASS |
| P0-001字段齐全 | PASS |
| P0-001依赖准确 | PASS |
| P0-001状态真实 | PASS |
| P0-002字段齐全 | PASS |
| P0-002依赖准确 | PASS |
| P0-002状态真实 | PASS |
| P0-003字段齐全 | PASS |
| P0-003依赖准确 | PASS |
| P0-003状态真实 | PASS |
| P0-004字段齐全 | PASS |
| P0-004依赖准确 | PASS |
| P0-004状态真实 | PASS |
| P0-005字段齐全 | PASS |
| P0-005依赖准确 | PASS |
| P0-005状态真实 | PASS |
| P0-006字段齐全 | PASS |
| P0-006依赖准确 | PASS |
| P0-006状态真实 | PASS |
| P0-007字段齐全 | PASS |
| P0-007依赖准确 | PASS |
| P0-007状态真实 | PASS |
| P0-008字段齐全 | PASS |
| P0-008依赖准确 | PASS |
| P0-008状态真实 | PASS |
| P0-009字段齐全 | PASS |
| P0-009依赖准确 | PASS |
| P0-009状态真实 | PASS |
| MVP-001字段齐全 | PASS |
| MVP-001依赖准确 | PASS |
| MVP-001状态真实 | PASS |
| MVP-002字段齐全 | PASS |
| MVP-002依赖准确 | PASS |
| MVP-002状态真实 | PASS |
| MVP-003字段齐全 | PASS |
| MVP-003依赖准确 | PASS |
| MVP-003状态真实 | PASS |
| MVP-004字段齐全 | PASS |
| MVP-004依赖准确 | PASS |
| MVP-004状态真实 | PASS |
| MVP-005字段齐全 | PASS |
| MVP-005依赖准确 | PASS |
| MVP-005状态真实 | PASS |
| MVP-006字段齐全 | PASS |
| MVP-006依赖准确 | PASS |
| MVP-006状态真实 | PASS |
| First15顺序一致 | PASS |
| 9项裁决有Decision/Why/Rejected/Impact | PASS |
| 蓝图章节Target Architecture | PASS |
| 蓝图章节Repository Architecture | PASS |
| 蓝图章节Database Architecture | PASS |
| 蓝图章节Identity & Security Architecture | PASS |
| 蓝图章节Application Core | PASS |
| 蓝图章节Sync & Consistency | PASS |
| 蓝图章节Agent Interface Architecture | PASS |
| 蓝图章节Frontend Architecture | PASS |
| 蓝图章节Failure & Recovery Matrix | PASS |
| 蓝图章节Test Architecture | PASS |
| health管理参数三个分支齐全 | PASS |
| read scope覆盖成功与重放 | PASS |
| P0-003命令合同引用齐全 | PASS |
| record_open施工与测试有归属 | PASS |
| S09有测试责任 | PASS |
| 原文未改:Morrow-Codex工程前置分析包.md | PASS |
| 原文未改:个人生活工作台 · 产品深度规划 V2.md | PASS |
| 没有产品源代码/migration/假施工收据 | PASS |
| 所有本地Markdown链接存在 | PASS |


独立复核：产品代理完成原附件覆盖审计，两个责任/引用遗漏已补；安全代理确认C05.1管理锁序与成功/重放权限投影自洽。这里没有把文档检查计作RLS、并发或产品运行测试。
