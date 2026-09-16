# Morrow施工指引

## 当前授权范围

- 本仓库M1为Phase0+MVP+连续7天真实使用，用户已确认。M1前Codex不介入，按docs/planning任务分工执行。
- 原始产品V2 > 工程前置包 > docs/planning工程裁决。不要重开已确认产品讨论。
- 先读当前Task卡及其明确引用章节，不要求每个Agent重读全部材料。入口：docs/planning/05-first-15-tasks.md。
- 当前task-index全部PLANNED不代表已有实现。推进状态必须有真实证据与独立Review。

## 架构硬约束

- Supabase固定；静态HTML/CSS/JS；唯一权威业务Core为private PostgreSQL语义函数。
- Human通过自己JWT调用RPC，记录级LWW；Agent只能业务语义HTTP/MCP，不直连数据库。M1仅health Agent开放。
- DB trigger原子version；所有JSON BIGINT服务端转字符串；Human写也用幂等键，Agent额外expected_version。
- RLS/default grants/owner检查齐全；业务、audit、receipt、revision在同事务。
- 前端/导出/git/日志不含service_role、token、password、session；token明文不进request_receipts。
- 断网保留明确草稿；unknown请求不自动重放；使用原key确认后重试，不悄悄覆盖新数据。
- 固定三锚点；健身是结束时间，22:15关灯对应19:15结束目标；实际间隔另算。日型计划保历史、记录率与达标率分离。
- 不提前建设Inbox/习惯/完整健身/业务Agent/MCP/PWA/Mobile/规则/通知。

## 执行与Review

- 15步按依赖执行；失败在原Task闭环，不能跳Gate。高风险由异模型深审，作者不能作为唯一最终审查者。
- 适合独立安全/产品/视觉/数据评审时按用户分工并行分派，有明确边界，不重复修改同一文件。
- 不请求Codex回场批准；受限局部选择按03-execution处理，超出已批准分支报有证据的ARCHITECTURE ALERT给凯哥。
- 真实账号/设备/公开发布授权缺口，向凯哥请求具体动作；不从文档假设已登录、已部署或常驻机器在线。
- 不覆盖已有配置/源文件；不改已应用migration；不把真实生活导出提交git。

## 完成标准

- 每Task在docs/planning/evidence/<ID>/result.md留commit、diff、实际测试、原始输出、Review、待验证及下一步。
- 未运行标NOT_RUN，缺真实设备标BLOCKED，7天未满标USAGE_PENDING；禁止把规划静态检查叫产品验收。
- Phase0→MVP不加14天；MVP→Phase1及以后须上一阶段14天真实使用、记录率≥80%、凯哥本人确认，任一缺失不得开工。
