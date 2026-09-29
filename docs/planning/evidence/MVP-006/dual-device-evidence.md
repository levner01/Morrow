# MVP-006 双机证据表（04-acceptance §3 模板）

> 公司机栏由施工方 2026-09-29 自跑填实；家机栏**未预填**，等凯哥回传。
> Pages 行与 push 后发版对账联动（result.md §2.3），补记前标注状态。

| 字段 | 公司机 | 家机 |
|---|---|---|
| 日期/时区 | 2026-09-29 · Asia/Shanghai | 待填写（BLOCKED-OWNER） |
| 设备/浏览器版本 | Apple M4 Max · macOS 26.3.1 · Chrome 154.0.8037.58（headless CDP E2E + file:// 探针） | 待填写（runtime-environment.md §5 回传） |
| 网络条件/代理与否 | 公司网，系统代理开启（ExceptionsList 含 localhost）；E2E `--no-proxy-server` 直连 supabase.co | 待填写 |
| 发布URL/hash | `https://levner01.github.io/Morrow/`；发行 `mvp-006-4624e4dc3237`（线上服务 hash 对账见 result.md §2.3，push 后补记） | 同 URL；待回传访问结果 |
| Pages实际UI/Auth/RPC | PENDING（发版对账时补记：UI 三态/Auth 登录/RPC revision） | NOT_RUN（BLOCKED-OWNER） |
| 本地HTML实际UI/Auth/RPC | ✅ file:// 探针：ui_shell_visible=true；auth_login ok（le***@foxmail.com）；rpc get_workspace_revision_v1 ok（data_revision=480，request_id 623a5397-0c8b-44a0-9ab0-a0c7534fa63e）——原始输出见 result.md §2.4 | NOT_RUN（BLOCKED-OWNER） |
| storage刷新恢复 | ✅ Page.reload 后 getCurrentUser 非 null（会话经 localStorage 恢复，真实 auth_check） | NOT_RUN（BLOCKED-OWNER） |
| loopback（仅需时） | NOT_RUN（本轮 file:// 直接过，无 loopback 依赖场景；P0-008 已测该路径） | NOT_RUN |
| A记B刷新 / B记A刷新 | NOT_RUN（双机配合项，等家机就位后两侧各执行一次） | NOT_RUN（BLOCKED-OWNER） |
| 原始输出/脱敏截图 | result.md §2.4 / §3 + 本目录 regression-* 存档 | 待回传（截图贴本文件下方） |

---

## 家机回传区（凯哥填写）

（浏览器打开 Pages URL 后的截图 / 浏览器版本 / 网络条件 / 验证结果，直接追加在下方）

## 真实手机回传区（凯哥填写，A22 真机位）

（手机浏览器打开 Pages URL 的截图，直接追加在下方）
