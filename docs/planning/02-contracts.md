# Morrow — M1 合同与验收样例 V1

本文件为施工规范，不是已经实现/验证的 API。架构解释见 `01-architecture.md`。M1=Phase0+MVP；所有未来字段标为预留，不因此获得施工授权。

## C-01 公共标识与日期

- 所有 UUID 规范小写；日期 `YYYY-MM-DD`；时间戳 ISO 8601 带时区偏移，DB 存 timestamptz UTC。
- `version`、`expected_version`、`data_revision` 在 JSON 中统一为十进制**字符串**。读不存在资源的创建前态 version=`"0"`；真实记录从 `"1"` 起。禁止 JS Number 转换 BIGINT。
- `biz_date` 表达工作区生活日，不从 UTC 日期截断、不信任设备时区。M1 `Asia/Shanghai`。后续时区变更必须分生效段，不能重解释历史。
- wake 与 workout_end 的 actual_at 属 biz_date 当天；lights_off 可在当日12:00到次日12:00之前，UI 跨午夜明确“次日”，不能悄悄挪动日期。这个12:00边界是可审计的工程归属规则，非医学结论。
- MVP 允许修正 tracking_started_on 起至今日的事实，禁止未来 actual_at（容忍设备时差不以设备时钟为准，服务器未来上限60秒）；超出日期归属返回422。特殊生活日可记 note，后续有真实需要再演进版本。
- entity_key 由 Core 生成，API 不让 Agent 自填任意 module/payload；id/owner/module/key/created_at 不可修改。

| module | entity_key | M1状态 |
|---|---|---|
| anchor | `wake:2026-09-15` / `workout_end:2026-09-15` / `lights_off:2026-09-15` | 实现 |
| day_type | `2026-09-15`（每日计划快照） | 实现 |
| day_type_definition | `default:ordinary_workday` 或 `custom:<uuid>` | Phase1；M1默认模板放版本化合同 |
| habit_definition | `habit:<uuid>` | Phase1预留标识 |
| habit_log | `<habit_uuid>:2026-09-15`（每日汇总；count通过语义增量命令） | Phase1预留 |
| workout | `workout:<uuid>`（允许一天多次） | Phase1预留 |
| inbox | `inbox:<uuid>` | Phase1预留 |
| shopping | `shopping:<uuid>` | Phase2最小增加待买 |
| goal | `goal:<uuid>` | 后续预留 |

幂等创建类（Inbox/workout/shopping）由事务第一次执行生成id，重放回同id，不用易变内容做唯一键。

## C-02 Payload V1（M1严格验证）

所有 schema 顶层 `additionalProperties:false`。以下是字段规格，P0-003据此生成正式 JSON Schema 文件；不允许把本节当作无需验证的随意 JSON。

### anchor

| 字段 | 类型/规则 |
|---|---|
| payload_v | integer const 1 |
| anchor_type | enum wake/workout_end/lights_off，与key对应 |
| timezone | string `Asia/Shanghai`（该日快照） |
| target_at | 带偏移时间戳；无训练计划的workout可为null |
| actual_at | 时间戳或null |
| status | pending/recorded/not_applicable；由Core从事实与计划导出后写入 |
| planned | boolean，来源每日计划 |
| note | string 0..2000，按纯文本处理 |
| plan_version | decimal string；关联每日计划快照版本 |

`recorded ⇔ actual_at != null`，`not_applicable ⇒ planned=false && actual_at=null`；recorded 不等于达标。禁止客户端提交 status/source/version/target，命令只收 actual_at、note 等允许字段。没有计划的训练要先明确把当日日型设为训练日（即使已起床打卡也允许当日单向增加训练计划），不暗改计划分母。

### day_type（每日快照）

`payload_v:1`；`code` MVP enum ordinary_workday/workout_workday/weekend/weekend_workout；`name`冻结中文名称；`timezone`；`template_version` decimal string；`workout_expected:boolean`；`sleep_target:"22:15"`；`anchors`为固定3元素数组（type、required、target_local_time，其中训练日workout_end=`19:15`、非训练日null）；`plan_locked:boolean`。

Phase1 再加入休息工作日/出差/旅行/自定义、default_tasks和game_window等完整字段，不提前做模板编辑器。M1 schedule初始周配置明确7个weekday映射，可由用户选择哪些训练日；日型配置与锚点数据分离。

### 计划落地与分母

1. settings 的 schedule_history 为有生效起日的默认周计划，包含每个 weekday 的 day_type code；tracking_started_on 后每一天都可被纯函数解析出计划，不因没打开页面而消失。
2. `get_today_context_v1` 是只读，可返回尚未落库的计划和 version=0 的锚点占位，标记 `materialized:false`。不把占位当实际记录。
3. 当日首次 `set_day_type` 或锚点命令在一个事务内物化每日计划与3条锚点初态，然后应用目标命令；insert后同事务是否update必须保证返回正确版本。首次完成可以直接insert version1事实，不为凑步骤无意义加版。
4. 记录首个actual_at后锁定既有计划目标与分母下限；set_day_type仍允许当日单向追加训练计划（例如起床后决定健身，ordinary_workday→workout_workday），显示“增加今日训练计划并纳入记录率”后确认；既有锚点目标保持快照。减少已锁计划或修改历史日返回DAY_PLAN_LOCKED。清空全部记录不会自动解锁。
5. 未锁计划的当日切换可更新全部pending锚点目标/适用性及plan_version；已锁计划只增加原n/a训练项的required/target并更新每日计划版本，保留已有锚点target和原plan_version作为provenance。同一事务完成；目标不是由UI自行拼接。
6. 历史缺失记录的补记依据历史默认计划或已有快照；默认模板未来更新只影响生效日之后，旧快照不变。M1不提供历史计划重算。
7. 归属例外或初始化数据修复使用独立审计的维护动作，不能在MVP普通编辑中绕过锁；任何改变门禁历史分母的修复使原门禁证据作废、重新计算并由凯哥确认。

## C-03 达标、统计与今日下一步

### 三个锚点

- wake：actual_at ≤ target_at 为达标；早起也算记录。偏差分钟=(actual-target)/60，保留有符号数，UI取整显示但不以取整结果判断边界。
- lights_off：actual_at ≤ 该日22:15为目标达标，次日00:30记前日则偏差+135分钟。
- workout_end：目标19:15（训练日）。同时显示“结束较目标偏差”和“距实际关灯间隔”。未记录关灯时，实际≥3h约束 `unknown`；两者都有时使用实际时间差判断。晚睡不能把已超19:15的结束目标改判为目标达标。
- 非训练日该行显示“今日无计划”，不伪造completed，不计分母。未记录关灯绝不声称实际训练睡眠间隔已满足。
- 不新增训练模块，MVP该行只记结束时间。今日下一步由Core按计划中尚未记录的锚点给一个行动；过时提示补记/调整，不发医学建议。完成后显示当天记录已完成；建议区无真实建议就隐藏。

### 指标

`recording_rate = recorded_planned_anchors / planned_anchors`。recorded指有效actual_at，无论达标与否；not_applicable、仅计划占位、未完成按钮、重复写均不计分子。每个日期/类型最多1条。计划分母由跟踪起日之后的历史计划决定，包含从未打开页面的日期。若分母0，rate=null而非100%。

“连续记录天数”指每个过去已结束生活日的所有适用锚点都有记录的连续长度。今日尚未完成时显示截至昨日的连续值，今日完成后加1，不在早上先断链。每锚点连续记录：只统计该锚点适用日，非适用日跳过，训练项标“连续N个计划日”，不冒充自然日。达标连续是另一个命名指标，M1默认显示记录连续，不混用。

met_count只计actual_at≤target_at的目标达标数，不把实际训练→关灯间隔并入它；间隔另列interval_met/interval_unknown_count，避免F05的目标与间隔混淆。

统计生活日的结算点为该日次日12:00；尚未到结算点且未全记录的日期为provisional，不提前断链，也不增加已完成连续数。今日页面仍在00:00切至新日，提供补记昨日入口；该规则使凌晨关灯仍有明确前日归属。门禁以已结算连续日期计算，历史补记/修正立即重算统计；如改变验收窗口，旧计算证据失效须重新生成。

30天热力图是含今日的30个工作区日期，返回每格planned_count/recorded_count/met_count/interval_unknown_count，UI用记录完成比例着色并提供文字。tracking_started_on之前为未开始，不涂失败色。连续统计范围从断点或跟踪起点开始，不能固定LIMIT30。

“连续真实使用≥7/14天”需每个日历日有至少一次真实 Human主动打开或记录证据；纯Keepalive、Agent、fixture不算。MVP app首次有效展示当日页面可以提交幂等 `human.opened`（每device每天至多一次）作为辅助证据；SDK测试数据标识并排除，最后仍需真实使用记录与凯哥确认。主动打开率的产品分母尚无正式冻结定义，M1仅保留open事件，不编造转化指标。

### 必过固定样例

| ID | 输入 | 期望 |
|---|---|---|
| F01 | 06:47起床，目标06:50 | recorded，达标，偏差-3 |
| F02 | 07:10起床 | recorded，未达标，计入记录率 |
| F03 | 健身结束19:15、关灯22:15 | 目标达标，实际间隔180，间隔达标 |
| F04 | 结束19:30、关灯22:15 | 目标晚15，间隔165，不达标 |
| F05 | 结束19:30、关灯23:00 | 训练目标仍晚15，实际间隔210达标；关灯目标未达标 |
| F06 | 结束19:00、尚无关灯 | 已记录；实际间隔unknown |
| F07 | 非训练日、两项完成 | 分母2分子2，训练n/a |
| F08 | 前日关灯次日00:30 | 归前日，偏差+135 |
| F09 | 连续45天全记录 | 总连续45，不裁到30 |
| F10 | 从未打开的计划日缺2项 | 当期分母含2，不能跳过 |
| F11 | 已起床后增加训练/取消已计划训练/clear | 增加允许分母+1；减少拒绝；clear不改变分母 |
| F12 | 今天未完成，昨天连续8天 | 显示截至昨日8天，今天补全后9 |
| F13 | UTC 16:10、工作区北京时间次日00:10 | 今日按上海日期，不按UTC |
| F14 | 实际记录迟到全数完成 | recording_rate=100%，达标率单独计算 |

## C-04 统一命令事务

HTTP/JS规范请求形状（示意，不是产品代码）：

```json
{"api_version":"1","idempotency_key":"<uuid>","expected_version":"7","input":{"biz_date":"2026-09-15","anchor_type":"wake","actual_at":"2026-09-15T06:47:00+08:00","note":""}}
```

Human 不传 expected_version，服务端身份决定 LWW；传入强制模式/actor/user_id/任意payload返回422，不能通过参数假扮 Human 绕过 OCC。Human `idempotency_key` 必填。Create-only Agent expected_version=`"0"`，已存在或tombstone均不能变成update。

事务步骤：

0. owner部署时先预置workspace_state零值；initialize_workspace锁这条既有行并检查settings不存在，再建立配置。所有导出变更共用此锁。
1. 验证入口可执行角色、身份、owner及scope。Agent用 client→credential FOR UPDATE 固定锁序，以低频串行换清晰撤销语义；Human不获取不相关Agent锁。
2. 锁workspace_state（所有导出对象写/系统日志写遵循相同顺序），锁/插receipt唯一键。相同key不同hash→409 IDEMPOTENCY_KEY_REUSED。已完成相同hash→返回原收据，不再写业务。
3. 参数、schema、目标owner、计划适用性、softdelete检查；业务错误保存结构化 rejection及必要审计后正常结束事务，不能被未捕获异常回滚掉失败证据。
4. 锁定目标行；Human按当前记录覆盖允许字段构造完整新记录，Agent update条件同时含id、owner和expected_version；创建类用唯一键解决并发。无更改返回no_change。
5. 变更触发version、可信来源、日志、revision。全部成功后写receipt完整结果并提交。
6. Human owner返回实际record+version+server_time+request_id；Agent成功与重放均按下述当前read scope重新投影，无读取权不返回payload。数据库/审计技术错误全部回滚，返回可重试503，允许原key重试。禁止客户端逐请求执行“写记录→再写日志→再存receipt”。

通用Agent OCC框架在P0以数据库测试验证，业务入口直到Phase2仍不可执行。

### 幂等与迟到请求

收据namespace `(owner,actor_type,actor_id,key)` 跨操作唯一，operation包含在hash。凭据轮换不改变client namespace；撤销token后即使是历史receipt查询也先认证，不泄露旧结果。相同请求并发以DB唯一约束等待提交后重放；首个事务崩溃全部回滚，下个请求可执行一次。

M1不安排收据清理任务。未来清理只去响应体、保留key墓碑；超期请求返回409并要求重新读取，绝不能重跑。

“已发送、未收到响应”可能已提交：先调用只读get_command_result_v1并读取当前记录。已知成功收据只展示结果并刷新。收据未找到并不证明原请求永不会提交，须显示当前值、可能覆盖风险，让用户确认后才以原key重试；绝不自动重放unknown。若DB确认没有receipt且原请求不能确认结束（网关超时/取消不代表DB已取消），不得凭空宣称未提交；用原key完成序列化后展示最终当前状态。若旧请求首次从未提交，确认后的原key重试仍可按LWW覆盖期间另一端的新值，这是Human新确认意图的已接受语义，幂等不能阻止该分支。新Human意图只有在旧in-flight已落定且用户确认后提交。离线从未发送的草稿恢复时先读最新再确认。

## C-05 Human RPC 表面（M1）

| RPC | 输入 | 权限/结果 |
|---|---|---|
| get_today_context_v1 | 可选biz_date（默认server计算today） | Human owner；只读计划+3锚点+next_action+versions/server_time/data_revision |
| get_anchor_history_v1 | from,to；最多366天一次，cursor可续 | owner；30天图及准确连续投影由Core产生，不让UI另算 |
| set_day_type_v1 | biz_date,code,idempotency_key | 仅今日；未锁可改，已锁只允许追加训练；同事务计划+适用性 |
| check_anchor_v1 | biz_date,type,actual_at,note,key | Human LWW；immutable/actor字段不接收 |
| clear_anchor_v1 | biz_date,type,key | 清事实不清计划，不物理删除 |
| update_anchor_note_v1 | record_id,note,key | 同一记录LWW，通过Core保留其他当前字段，不允许任意JSON patch |
| initialize_workspace_v1 | timezone,tracking_started_on,weekday_codes,key | 锁预置state行，仅首次；不任意重置owner历史 |
| record_open_v1 | device_id,biz_date,key | 一日device幂等，人类主动打开证据；重复不刷日志 |
| get_command_result_v1 | idempotency_key | Human只读自己收据；不执行未见请求，不泄漏token，未找到不是取消证明 |
| get_workspace_revision_v1 | 无 | owner；decimal revision，只读 |
| manage_health_client_v1 | create/revoke/rotate、命令严格schema/key | Human owner；Phase0仅system:health，无自由scope |

Human Context多语句读须先对workspace_state FOR SHARE，public/private调用链必须声明VOLATILE且用POST RPC（禁止get:true/STABLE/read-only事务），Agent Context按统一FOR UPDATE流程（读后审计），直到事务结束，保证与写同一锁边界；不能把同一READ COMMITTED事务误认为单快照（[PostgreSQL隔离级别](https://www.postgresql.org/docs/current/transaction-iso.html)）；导出视图权限按[security_invoker语义](https://www.postgresql.org/docs/current/sql-createview.html)验收。

基础表owner SELECT用于精确取记录；export使用固定列security_invoker视图将BIGINT在服务端cast text，再分页读取；写入只能RPC。export直接SELECT必须用列白名单，禁止select('*')以免未来字段自动流入文件。原始直读页面也只能展示，不绕开Core业务计算。

### C-05.1 health客户端管理命令（M1冻结）

`manage_health_client_v1` 仅限已校验的Human owner，所有分支都带UUID `idempotency_key`；拒绝请求自报user_id/actor/scopes/token明文。token由本机管理脚本预生成并安全保存，SQL只收到32字节摘要。管理命令hash包含locator与token_hash，收据不存token原文；回执仅含下列非敏感字段。返回的credential元数据不能因此进入全量export。

| action | 允许输入（除key） | 明确行为与非敏感结果 |
|---|---|---|
| create | name(1..80), type(local/remote/scheduled), credential_id(UUID locator), token_hash(64位hex), expires_at(带时区) | DB生成client_id；owner从auth.uid派生，scopes固定[system:health]；此次明确创建操作把enabled设true，revoked_at=null，原表默认false仍保留。创建首凭据；结果为client_id/credential_id/enabled/scopes/expires_at/version，不回hash或秘密。 |
| rotate | client_id, credential_id(新UUID), token_hash, expires_at | 锁已有client及旧凭据（多凭据按id升序），拒绝已撤销/disabled客户端；新增凭据，保留旧凭据供宿主切换，不复活旧凭据。旧凭据有效期收紧为原到期与现在+24h的较早值；新token试通后，脚本调用revoke撤旧。返回新credential_id/expires_at和client配置version。 |
| revoke | client_id, target(client/credential), credential_id(仅target=credential时必填) | client分支原子设enabled=false/revoked_at并使全部token失效；credential分支仅撤指定且属于该client的凭据。重复撤销为no_change；不能通过rotate或create参数恢复相同已撤client。结果为client_id/target/credential_id?/revoked_at/no_change/version。 |

expires_at必须在server_now之后且不超过90天；省略时脚本填默认90天，API始终收显式值。credential_id及token_hash唯一；跨owner、复用locator或hash拒绝，不透露其他主体状态。client配置version仅配置变更时由触发器递增，单纯添加/撤销凭据不伪造client配置变更，但必须记录安全事件。

create没有既有client或credential可锁，固定为owner认证→锁既有workspace_state→receipt去重→校验locator/hash未占用→插入全新的client和首凭据；完全相同请求先返回收据，不重复插入。这个分支不得修改或锁定既有client/credential；发现locator/hash已存在即返回冲突，不借create执行upsert。rotate/revoke仍按既有client→credentials→state→receipt，新增凭据必须在取得state之后，禁止先插后锁。部署P0-004测试同key并发create只有一个client/凭据，以及create与rotate/revoke并发无反向锁等待。

已有client的rotate/revoke遵循client→按id排序credentials→workspace_state→receipt；不能套普通Human命令先锁state再反向锁client。认证/归属不通过不写他人的activity。可识别owner的业务拒绝与成功均由Core记录审计，不在浏览器拼日志。

P0-008双机探针固定走create（本机保存但不向外部分发token）→owner读取自己的配置→revoke(target=client)；此时尚无锚点写接口，也不开放测试DML。

## C-06 Agent HTTP + MCP（Phase2合同，M1不实现业务端点）

health虽是外部GET，Edge内部调用有审计写和行锁的RPC必须POST且VOLATILE；只返回status/db/server_time/request_id，不回生活计数。

Base URL：`https://<project-ref>.supabase.co/functions/v1/agent-api/v1`（待真实项目确定）。health独立函数为 `https://<project-ref>.supabase.co/functions/v1/health`，只接受GET，M1不发布MCP。

| 最小业务能力 | HTTP | scope | 核心输入 |
|---|---|---|---|
| get_today_context | GET /today-context | read:context；附加领域需各自read | date?，默认工作区today |
| get_anchor_status | GET /anchors | read:anchor | from,to，最大366天/分页 |
| get_recent_records | GET /recent-records | 对应read:inbox/workout/shopping/activity等 | 已支持kind枚举、cursor、limit≤100；非任意module查库 |
| check_anchor | POST /anchors/check | write:anchor | type,date,actual_at,note,expected_version,key |
| capture_inbox | POST /inbox/captures | write:inbox | text 1..4000,expected_version="0",key |
| record_workout | POST /workouts | write:workout | Phase1冻结的语义字段,expected_version/key |
| add_shopping_item | POST /shopping-items | write:shopping | name 1..200,quantity?,expected_version="0",key |
| submit_advice | POST /advice | advice:create | topic/title/content/reason/evidence/priority/expires_at,expected_version="0",key |

health是系统能力，不计8个业务工具；get_system_status为未来MCP对应工具。常用原文tool名保持。更多habit/weekly_summary等按Phase1真实能力添加，M1不先设计几十个Tool。

`today_context` 基础含date/timezone/server_time/day_type/anchors/next_action及每记录version。Inbox计数仅在已实现且具有read:inbox时添加；建议仅在已实现且具有read:advice时添加，响应 `omitted_sections` 明确因未实现或无授权省略；不能用read:context绕读全部隐私。只读查询不物化业务数据，但Agent读取必须追加操作审计；返回context在workspace_state锁保护下读取，不能以多个不一致缓存拼包。

HTTP和MCP共享operations manifest与request/response Schema。API major在URL和schema namespace；新增可选输出向后兼容，改字段语义/必填项新增major。MCP tool名称不硬绑DB列，初始化说明api_version，破坏变更可并存v1/v2工具注册，不能静默改变旧tool语义。JSON Schema版本与MCP传输协议版本独立。

### 错误模型

```json
{"ok":false,"error":{"code":"VERSION_CONFLICT","message":"记录已更新，请重新读取","retryable":false,"request_id":"<uuid>","details":{"resource_id":"<uuid>","current_version":"8"}}}
```

| HTTP | code | 调用方行为 |
|---|---|---|
| 400 | INVALID_REQUEST | 修正形状 |
| 401 | UNAUTHENTICATED | 重配/刷新身份，不猜token |
| 403 | SCOPE_DENIED / OWNER_DENIED | 停止，不自动升权 |
| 404 | RESOURCE_NOT_FOUND / ROUTE_NOT_ENABLED | 不泄露别的owner资源存在 |
| 409 | VERSION_CONFLICT / ALREADY_EXISTS / IDEMPOTENCY_KEY_REUSED / DAY_PLAN_LOCKED / IDEMPOTENCY_RESULT_EXPIRED | 重读后重决策；新意图新key |
| 410 | RESOURCE_DELETED | 不能普通upsert复活 |
| 422 | PAYLOAD_UNSUPPORTED / VALIDATION_FAILED | 不裁剪未知字段后强写 |
| 429 | RATE_LIMITED | Retry-After，同key |
| 503 | STORAGE_UNAVAILABLE / AUDIT_UNAVAILABLE | 有界退避，同key |

幂等重放复用内部原语义result，当前调用重新包装request_id及replayed:true，原command key保持；对外响应必须重新按当前权限投影，不直接发送保存的完整响应。Agent每次可识别调用（含重放）额外记轻量request.replayed/查询审计，不重复资源变更日志。receipt不得保存token明文，技术日志不自递归。

成功响应同样受读取权限约束：write不隐含read。Agent具备该资源对应的read:anchor/read:inbox/read:workout/read:shopping/read:advice时才可返回完整record；read:context只授权其固定Context投影，不替代其他资源完整读取scope。无对应read时，命令仍可成功，但只回resource_id/version/result(no_change或changed)/server_time/request_id，不回payload、note、title、content等字段。幂等收据内部可保存原结果，重放必须在本次认证与当前scope检查后再次裁剪；历史有read、现在已撤read也不例外。已撤write时该写命令的重放同样先被拒绝，不把receipt做成旁路查询。Human只读收据接口也必须限定本owner/actor。

MCP业务错误使用isError和相同结构化内容；协议错误由SDK表达。SQL业务RPC允许返回相同envelope，Human transport统一解释；Phase2 HTTP adapter负责状态码映射，不要求每个SQL分支抛HTTP异常。错误details按read scope过滤，message不含SQL、token、密码或他人记录。

M1 health每client每分钟≤5次（可通过数据库窗口计数/受限状态实现，固定上限；token失败由边缘平台限制并脱敏记录），HTTP请求体上限16KiB；业务API Phase2初值每client 60req/min、写20req/min，按实测调整不放开无限制。拒绝未声明方法/路由/字段，正文纯文本输出防XSS。

## C-07 页面状态机与草稿

```text
boot → auth_check → loading → synced
loading失败 → failed（可重试，旧快照有时间戳）
synced → 本地写意图保存成功 → sending → synced
sending → 连接丢失/超时 → unknown → 只读查收据/当前值 → 确认后原key重试 → synced或failed
离线新输入 → draft_saved → online_review → 用户确认 → sending
任何状态 → session失效 → auth_required（不丢草稿）
```

用户可见同步状态保持三态“已同步 / 同步中 / 同步失败·重试”；auth、缓存时间、本地草稿是辅助说明，不能用第四个“离线已同步”模糊事实。

草稿持久化字段：owner_uid、record business key、command input、idempotency key（若已发送）、last_known_version、created_at、sent_at、state。只有存储成功后提示“草稿已保存”。localStorage作为M1小草稿存储，写前probe并catch配额/权限失败；不强依赖file origin稳定性。已确认存储不可靠时让使用者下载无凭据草稿JSON，或切loopback访问；不得承诺关闭浏览器后内存仍在。文件名更换/浏览器换profile可能隔离本地存储，runbook必须说明。

多tab使用BroadcastChannel（可用时）通知失效，不依赖其实现锁；锁与去重权威仍是数据库。跨端不传播未同步草稿。发出成功响应后版本比当前cache小则丢弃其payload并刷新，不回滚UI。

## C-08 Export V1 与未来 Restore

文件名 `life-workspace_YYYY-MM-DD_schema-v1.json`，日期取工作区导出日期。

```json
{
  "schema_version":1,
  "exported_at":"2026-09-15T12:00:00.000Z",
  "app_version":"<release>",
  "workspace":{"owner_id":"<uuid>","timezone":"Asia/Shanghai","data_revision":"42"},
  "data":{"life_data":[],"agent_advice":[],"activity_log":[],"automation_rules":[],"agent_clients":[],"workspace_settings":[]},
  "counts":{"life_data":0,"agent_advice":0,"activity_log":0,"automation_rules":0,"agent_clients":0,"workspace_settings":0},
  "integrity":{"algorithm":"SHA-256","canonicalization":"RFC8785","data_sha256":"<hex>"}
}
```

字段白名单取01各公开表明确字段；agent_clients仅id/user_id/name/type/scopes/enabled/created_at/updated_at/last_seen_at/revoked_at/version。禁止credentials（含hash/locator列表）、access/refresh token、session、API secret、receipt hash/response。private.owner允许配置不导出，只用workspace.owner_id说明归属。workspace_settings必含以重建计划分母，不能只导事实而丢日型历史。

步骤：

1. 读字符串revision R0；逐表从固定列security_invoker=true导出视图keyset分页（所有BIGINT必须SQL cast text，不能先被JSON.parse读成数字），固定`ORDER BY id ASC`、每页500（settings单行），直到不足一页；含deleted_at行。显式owner RLS与列白名单。
2. 每表验证唯一ID、合法字段与schema，记录row count；版本字段保持字符串。未知未来payload可以原样备份并标兼容警告，不能把“不能解释”变成丢弃数据。
3. 读R1。R0≠R1说明期间有写/审计/last_seen变化，丢弃本次内存包并最多重试2次；不得静默下载混合快照。revision在写事务中递增，读取必须走主库正常Data API，无缓存代理。
4. 相同revision后做完整schema/计数/引用校验和RFC8785 canonical data hash，下载Blob。保存成功需浏览器下载操作实际完成/用户可拿到文件，不只console.log。
5. M1至少用1001行和10000日志验证分页与内存；25MiB作为显式保护上限，超过返回EXPORT_TOO_LARGE不输出部分文件。不是声称已支持无限量；后续超过实测上限再实现流式分块一致快照。

RFC8785只用于统一对象键序/数字表示（[官方规范](https://www.rfc-editor.org/rfc/rfc8785)）；BIGINT已字符串化。P0-003锁定一个已验证实现或小型严格实现并用已知向量测试，不自创与工具不兼容的“sorted JSON”。hash覆盖data，不自指包含hash自身。

未来Restore合同：先验证版本/hash/count/引用→dry-run→映射owner_uid→按记录id及logical key检查冲突→分事务受控导入→audit import来源。不覆盖当前更高版本，不恢复旧认证凭据；agent_clients只能恢复为disabled，重新发token。跨供应商导入可重新映射version，旧version留import provenance，不假装恢复PG内部并发状态。M1只做离线解析/序列化round-trip与引用校验，**不执行真实Restore、不承诺已可一键迁移**。

## C-09 迁移与版本兼容

- migration ID记录数据库结构；export.schema_version描述文件容器；payload_v按module升级；api_version描述语义协议。
- Schema增量先支持读旧+新→部署兼容客户端→受控数据迁移→最后撤旧写。新客户端不能把未知payload剥字段写回。
- 明确server minimum supported client/API版本；发行HTML启动检查，不兼容时停止写且保留导出/诊断能力。
- 变更合同必须更新fixtures/hash/验收映射；不可只改前端常量。

## C-10 安全与一致性验收向量

S01 anon所有数据无可见性；S02非owner无法读写；S03owner直DML拒绝但语义RPC成功；S04伪造actor/source/owner失败；S05credentials无法SELECT/export；S06默认PUBLIC EXECUTE无泄漏；S07无scope/过期/撤销health拒绝；S08 revoke与health并发无撤销后提交。

T01不同锚点并发互不影响；T02同Human新意图按提交后写覆盖；T03 20个有效更新版本唯一并最终+20；T04两Agent同expected仅1成功；T05响应丢失原key重试只一个变更和一个资源审计；T06相同key不同参数409；T07事务任一步失败不留下半业务/半receipt；T08已删键不可create/普通upsert；T09过期receipt不重新执行；T10重放旧结果不会把新UI回滚；T11日志或客户端配置变化触发export revision；T12导出期间新增/更新/删除导致重试，最终包无漏页；T13断网→刷新浏览器→草稿可恢复且联网不自动写；T14未发送草稿重连先对比当前值。

补充权限向量 S09：write无read时成功仅返回ID/version等最小收据；先有read完成写、撤read后同key重放也不得泄漏原payload。Phase0验证内部投影与receipt框架，Phase2验证真实HTTP/MCP同样裁剪。
