# 安全与一致性预审

日期：2026-09-15。依据：两份项目输入与下列官方资料。结论：PG 语义 RPC 统一核心可行；以下合同必须先冻结。本报告是设计审查，尚无运行验证。

## 1. 权限边界

- 业务表、凭据表、幂等账本放非暴露 schema；浏览器只获 human RPC 的 EXECUTE，撤销 anon/authenticated 对表、序列和内部函数的直接权限。公开注册关闭，另以固定 owner UUID 校验身份，防止“任何已登录用户都是主人”。
- RPC 默认执行权不是私有：迁移同事务撤销 PUBLIC/anon/authenticated 的默认与现有 EXECUTE，再逐函数授予；默认权限针对实际建对象角色设置。`SECURITY DEFINER` 固定空 search_path、全部对象写 schema、禁止动态 SQL。RLS 开启，但 definer 必须自己检查 owner/actor，不能假定 RLS 自动保护。[函数权限依据](https://supabase.com/docs/guides/database/functions)
- Agent RPC 仅服务身份执行；service_role 能绕过 RLS，因此它仍是高权受信边界。撤销其业务表直接 DML、内部 helper 执行权，只允许必要入口；不得声称 RLS 能约束泄露的管理密钥。审计表禁止外部 INSERT/UPDATE/DELETE；actor 从 JWT/凭据推导，不接受自报。[RLS 依据](https://supabase.com/docs/guides/database/postgres/row-level-security)

## 2. Token 与撤销

- 使用 CSPRNG 生成 32 字节秘密，格式含 credential UUID；DB 只存 SHA-256 摘要，原文仅创建时显示一次。摘要也是敏感认证材料，不入导出、应用日志或错误。agent_clients 仅留非敏感配置，scopes 由服务端白名单判定；Phase 0 仅 `system:health`。
- Edge 解析凭据后传摘要；DB 必须重新验证 client、摘要、enabled、revoked_at、expires_at 和所需 scope，不信任 Edge 传来的 owner/scopes。固定锁序 `client → credential → idempotency → resource`，用 FOR UPDATE 锁住 client/credential 后校验，直至事务结束；revoke/改 scope 同序锁行。低频场景接受每 client 串行，避免共享锁升级及 last_seen 更新死锁。
- 冻结撤销语义：撤销提交后，旧凭据不再有新操作提交；已持锁操作先完成，撤销等待。鉴权在重放结果之前执行。锁保证来自 PostgreSQL；该语义是本项目设计选择。[行锁依据](https://www.postgresql.org/docs/current/explicit-locking.html)
- health 做真实查库并追加去敏审计，仅回健康状态/服务时间，不回生活计数。失败鉴权写独立安全日志，不能把“INSERT 审计后 RAISE 回滚”当留痕。

## 3. 幂等与人类重试

- 所有人类写也携带 UUID 幂等键。唯一键 `(owner, actor_type, actor_id, idempotency_key)`；摘要覆盖操作名、协议版本、规范化业务输入、expected_version，排除凭据和传输元数据。同键异参返回 409。
- DB 通过唯一约束竞争插入；冲突请求等待已提交结果。首次业务变更、版本触发器、审计、终态结果同事务提交；失败回滚不存在半条账本。重放不写业务、不增版本、不追加业务成功事件。若保存业务错误结果，不能最后 RAISE 把结果回滚。
- 首版账本不清理；后续可清理结果正文，但保留键/摘要/结果定位 tombstone，过期重试返回 `IDEMPOTENCY_EXPIRED`，绝不能按新写执行。
- human LWW 定义为服务端记录锁串行的写入顺序，不采用设备时间。每条记录仅一个本地在途写，失败保留原键与原输入；禁止恢复网络后自动重新生成键。重试得到旧成功结果后刷新当前记录，避免 UI 倒退。若首次请求从未落库，延迟重试仍可能覆盖远端新值；重试前展示最新值，由人明确继续。变更输入是新意图、新键。

## 4. 删除与版本

- 唯一业务键包含软删行；普通 upsert 禁止复活 tombstone。删除/显式恢复均是带审计、版本递增的变更；M1 不开放业务删除，后续恢复仅 human。
- Agent 创建 `expected_version=0`，只允许不存在的键；更新必须正版本且行未删，条件更新失败 409，不能 fallback insert。版本在 API/JSON 用十进制字符串，规避 JS BIGINT 精度损失。新意图即使内容相同也按一次有效 UPDATE 增版；幂等重放例外。

## 5. 必须验证

执行角色权限矩阵；第二用户越权；直接表/RPC 绕行；改 client/摘要/scope；撤销与 health 并发；同键同参/异参并发；业务成功响应丢失；事务中断；旧重试不覆盖新值；软删复活；版本溢出边界；导出递归敏感键与凭据 canary 扫描。未运行前均为待验证，不能标记 PASS。

## 最终合同复审（01/02 初稿，2026-09-15）

以下最多五项为交接前应补足的施工约束；不改主文档。上文是预审建议，主文档最终选择已优先：owner 可直读列白名单导出、相同业务值 no_change 不增版，均可接受。

1. **P1｜一次性 Token 与完整收据响应尚未消歧。** 01 §4 规定只存摘要且仅显示一次，02 C-05 的 create/rotate 又走 C-04 完整 response 账本。若施工把 Token 作为 RPC 返回值，会把秘密永久或至少30天存入收据。冻结管理脚本本地产 secret 并安全暂存，RPC 仅提交 locator/hash、返回非敏感配置；响应丢失用相同 locator/hash/key 重试，脚本确认提交后再交付秘密，不把 token/hash 放通用返回值或日志。创建/轮换各做凭据 canary 扫描。

2. **P1｜未知已发送请求并未消除晚到覆盖。** 02 C-04 原 key 重试只有在旧请求已提交时才是安全重放。反例：A请求从未到DB→B写新值→A以原key重试首次执行，仍按LWW覆盖B。这是可接受的LWW取舍，但不能保证“所有迟到请求都不覆盖新值”。必须在“同步失败·重试”前读当前值并展示可能覆盖的内容，让人明确确认；即使确认后并发变化仍遵守LWW。若要强保证，则需要额外服务端重试保护协议，不能仅增加前端receipt查询。补一个该反例验收。

3. **P1｜直接导出 BIGINT 需要数据库侧字符串投影。** 02 C-08 直读表与 C-01 字符串合同之间缺实现约束；不能先用JSON解析数字再转字符串。所有 int8 投影在Data API服务端 cast text，例如 `version::text`，SQL JSON返回也先cast，再按白名单序列化；测试使用9007199254740993保证原样往返。当前PostgREST支持select列类型转换，目标Supabase版本需实测。[官方列转换](https://docs.postgrest.org/en/stable/references/api/tables_views.html#casting-columns)

4. **P2｜首次初始化没有可锁的 workspace_state 行。** 01 §3.9/02 C-04要求所有写先锁此行，但 initialize_workspace 本身可能是第一笔写。SELECT FOR UPDATE锁不到不存在的行，不能当初始化互斥。部署预置owner/state行，或在初始化事务先用唯一owner行作互斥并原子插入state，再按常规顺序执行。冻结单一方案，测试两并发initialize只能一个建出设置，且失败无半初始化。Human revoke/rotate仍必须先锁目标client/credential，不能套普通Human路径先拿workspace。

5. **P2｜只读 Context 的一致快照方法未冻结。** 02 C-06称同一事务读取一致，但默认READ COMMITTED下多个SQL语句仍可能看到不同提交；Human get_today_context尤其不拿写路径workspace锁。选一个实现：单一SQL/STABLE查询快照生成完整context（含revision），或同事务先取workspace共享锁再读且保持到结束。Agent已有client→credential→workspace锁须保留顺序。并发切日型/写锚点测试返回不能混合新计划与旧锚点。

已复核无新增缺陷：public invoker经对应EXECUTE/schema USAGE转private definer的授权链可施工；底层helper不授客户端；Agent操作与撤销的锁前缀一致；导出R0/R1判等在所有导出变化都同事务增revision、读主库无缓存的前提下成立。以上均为静态审查，未执行数据库测试。

### 修订复核与任务卡一致性

已复核01/02修订，以及P0-003/004/005/007、MVP-003/005：上述五项原问题已在设计层闭合。Token由脚本本地产生、SQL投影BIGINT、unknown只读查收据后确认、state预置、Context共享锁均有明确合同，相关任务卡也已承接。这里只代表可施工，不替代运行验收。

剩余两处必要澄清：

1. **P1｜共享行锁需要明确RPC事务模式。** 加入FOR SHARE后的Human Context在产品语义上只读，但数据库不能在READ ONLY事务执行该行锁。public入口及private实现须为VOLATILE，用POST调用RPC，禁止SDK `get:true`/HEAD和STABLE标注。外部health仍为GET，但Edge到数据库走POST/VOLATILE。将方法/volatility检查加入P0-004/005与MVP-001，防止“只读优化”导致线上调用失败。[PostgREST事务模式](https://postgrest.org/en/latest/references/transactions.html)

2. **P2｜Phase0双机读写需指定正式安全动作。** P0-005要求撤掉测试专用入口，P0-008又要求页面可控测试命令/读写，MVP锚点尚未实现。应在P0-004实现、P0-006壳接入一个正式受限动作，例如owner `record_open_v1` 写自有审计，再读取该日志；探测事件明确标test并排除真实使用证据。P0-008引用该动作，不重新启用测试DML、不借门禁提前开发锚点。也可明确在隔离测试项目完成既定探针，但必须保持生产不含测试后门。
