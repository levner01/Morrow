-- MVP-005 导出 Core SQL 证明（Management API postgres 角色驱动；单 DO 块整体回滚零残留）
-- 运行方式：整个 DO 块作为一条语句提交；末尾 RAISE EXCEPTION 携带 MVP005_PROOF JSON，
--   全部写入随事务回滚 → 真实库零变化（MVP-001/MVP-004 同款测试模式）。
-- 隔离：不删任何真实数据；synthetic 行 entity_key 前缀 'mvp005test:%'，断言全部带该过滤。
-- 覆盖：
--   T-E1a  keyset 分页语义（视图上 order+limit+id.gt 两页拼合无重叠无丢失）
--   T-E2a  BIGINT 保真（version=9007199254740993 经视图 ::text；payload jsonb 大数字 ->> 保真）
--   T11    任何写入 bump data_revision（life_data 双 bump / activity_log 单 bump 动态对账；
--          agent_clients 仅 last_seen 变化 bump 且不写配置日志）
--   白名单 视图列固定（敏感列不存在 → 42703）
--   封闭   export_agent_advice_v1 / export_automation_rules_v1 对 authenticated 42501（0004 决策）
--   RLS    security_invoker 继承（NONOWNER 经视图读 synthetic 行 = 0）
-- 注意：BIGINT 行需临时 disable trg_life_data_bi（BEFORE trigger 强制 version=1），
--   事务内 disable/enable，回滚后恢复。

do $$
declare
  v_owner uuid;
  v_nonowner uuid := '11111111-2222-4333-8444-555555555555';
  v_proof jsonb := '[]'::jsonb;
  v_rev_before bigint;
  v_rev_after bigint;
  v_delta bigint;
  v_expected bigint;
  v_audit_rows int;
  v_cnt int;
  v_cnt2 int;
  v_p_total int;
  v_p_distinct int;
  v_big text;
  v_type text;
  v_rev_text text;
begin
  select o.user_id into v_owner from private.workspace_owner o limit 1;
  if not found then
    raise exception 'SETUP_FAIL: workspace_owner 为空';
  end if;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner::text, 'role', 'authenticated')::text, true);
  perform private.cmd_set_actor('human', v_owner);

  -- ========== [1] T11 基线：植入前 revision ==========
  select data_revision into v_rev_before from public.workspace_state where user_id = v_owner;

  -- ========== [2] fixture 植入（postgres 直插 + actor 上下文；全部 mvp005test:% 标记） ==========
  -- 1001 行 life_data（BEFORE trigger 强制 version=1）
  insert into public.life_data (id, user_id, module, entity_key, biz_date, payload, source_type, source_id)
  select gen_random_uuid(), v_owner, 'anchor', 'mvp005test:row:' || g,
         (now() at time zone 'Asia/Shanghai')::date,
         jsonb_build_object('payload_v', 1, 'note', 'row ' || g),
         'human', v_owner
    from generate_series(1, 1001) g;

  -- BIGINT 行：绕过 BEFORE trigger 的 version:=1（事务内 disable/enable）
  alter table public.life_data disable trigger trg_life_data_bi;
  insert into public.life_data (id, user_id, module, entity_key, biz_date, payload, version, source_type, source_id)
  values (gen_random_uuid(), v_owner, 'anchor', 'mvp005test:bigint',
          (now() at time zone 'Asia/Shanghai')::date,
          jsonb_build_object('payload_v', 1, 'big', 9007199254740993),
          9007199254740993, 'system', v_owner);
  alter table public.life_data enable trigger trg_life_data_bi;

  -- 10000 行 activity_log（trg_activity_ai 每行 bump 1；无 audit 递归）
  insert into public.activity_log (id, user_id, actor_type, actor_id, agent_id, action, resource, resource_id, request_id, metadata)
  select gen_random_uuid(), v_owner, 'human', v_owner, null, 'mvp005test.synthetic', 'life_data', null, null,
         jsonb_build_object('n', g)
    from generate_series(1, 10000) g;

  -- ========== [3] T11 revision 对账（动态，不硬编码 trigger 实现细节） ==========
  select data_revision into v_rev_after from public.workspace_state where user_id = v_owner;
  v_delta := v_rev_after - v_rev_before;
  select count(*) into v_audit_rows from public.activity_log
   where user_id = v_owner and action = 'life_data.insert'
     and metadata ->> 'entity_key' like 'mvp005test:%';
  -- 每行 life_data insert：trg_after_write_audit 直接 bump 1 + audit 行进 activity_log 再触发 trg_activity_ai bump 1
  -- activity_log 直插：每行 1。expected = audit_rows*2 + 10000
  v_expected := v_audit_rows * 2 + 10000;
  if v_audit_rows <> 1002 then
    raise exception 'ASSERT T11 audit 行数异常：期望 1002（1001+bigint），实际 %', v_audit_rows;
  end if;
  if v_delta <> v_expected then
    raise exception 'ASSERT T11 revision delta 失败：got % expected %', v_delta, v_expected;
  end if;
  v_proof := v_proof || jsonb_build_object('T11_revision_bump', 'pass',
    'delta', v_delta, 'audit_rows', v_audit_rows);

  -- ========== [4] T11 补充：agent_clients 仅 last_seen 变化 → bump 且无配置日志 ==========
  select count(*) into v_cnt from public.agent_clients where user_id = v_owner;
  if v_cnt > 0 then
    select data_revision into v_rev_before from public.workspace_state where user_id = v_owner;
    select count(*) into v_cnt2 from public.activity_log
     where user_id = v_owner and action = 'agent_clients.update';
    update public.agent_clients set last_seen_at = now()
     where user_id = v_owner
       and id = (select id from public.agent_clients where user_id = v_owner order by created_at limit 1);
    select data_revision into v_rev_after from public.workspace_state where user_id = v_owner;
    if v_rev_after - v_rev_before <> 1 then
      raise exception 'ASSERT T11 last_seen bump 失败：期望 +1，实际 +%', v_rev_after - v_rev_before;
    end if;
    select count(*) into v_cnt from public.activity_log
     where user_id = v_owner and action = 'agent_clients.update';
    if v_cnt <> v_cnt2 then
      raise exception 'ASSERT T11 last_seen 不应写配置日志：% → %', v_cnt2, v_cnt;
    end if;
    v_proof := v_proof || jsonb_build_object('T11_last_seen_bump', 'pass', 'clients', v_cnt);
  else
    v_proof := v_proof || jsonb_build_object('T11_last_seen_bump', 'skipped_no_clients');
  end if;

  -- ========== [5] 切 authenticated（owner JWT）→ 全部经 export_* 视图断言 ==========
  perform set_config('role', 'authenticated', true);

  -- [5a] synthetic 可见性
  select count(*) into v_cnt from public.export_life_data_v1
   where entity_key like 'mvp005test:%';
  if v_cnt <> 1002 then
    raise exception 'ASSERT 5a synthetic life_data 期望 1002，实际 %', v_cnt;
  end if;
  select count(*) into v_cnt from public.export_activity_log_v1
   where action = 'mvp005test.synthetic';
  if v_cnt <> 10000 then
    raise exception 'ASSERT 5a synthetic activity_log 期望 10000，实际 %', v_cnt;
  end if;

  -- [5b] T-E1a keyset：两页（500 + id.gt）拼合 = 1000，distinct = 1000（无重叠无丢失）
  with p1 as (
    select id from public.export_life_data_v1
     where entity_key like 'mvp005test:%' order by id asc limit 500
  ), p2 as (
    select id from public.export_life_data_v1
     where entity_key like 'mvp005test:%'
       and id > (select id from p1 order by id desc limit 1)
     order by id asc limit 500
  ), allp as (
    select id from p1 union all select id from p2
  )
  select count(*), count(distinct id) into v_p_total, v_p_distinct from allp;
  if v_p_total <> 1000 or v_p_distinct <> 1000 then
    raise exception 'ASSERT T-E1a keyset 失败：total % distinct %', v_p_total, v_p_distinct;
  end if;
  v_proof := v_proof || jsonb_build_object('T-E1a_keyset', 'pass',
    'page1', 500, 'page2', 500, 'distinct', v_p_distinct);

  -- [5c] T-E2a BIGINT：视图 version 为 text '9007199254740993'
  select version, pg_typeof(version)::text into v_big, v_type
    from public.export_life_data_v1 where entity_key = 'mvp005test:bigint';
  if v_big <> '9007199254740993' or v_type <> 'text' then
    raise exception 'ASSERT T-E2a version 失败：value=% type=%', v_big, v_type;
  end if;
  -- payload 内大数字经 jsonb ->> 保真（PostgREST 序列化裸数字，前端 lossless 解析兜底）
  select (payload ->> 'big') into v_big
    from public.export_life_data_v1 where entity_key = 'mvp005test:bigint';
  if v_big <> '9007199254740993' then
    raise exception 'ASSERT T-E2a payload big 失败：%', v_big;
  end if;
  v_proof := v_proof || jsonb_build_object('T-E2a_bigint', 'pass',
    'version_text', '9007199254740993', 'payload_big', v_big);

  -- [5d] settings 恰 1 行；state revision 文本 = 植入后值
  select count(*) into v_cnt from public.export_workspace_settings_v1;
  if v_cnt <> 1 then
    raise exception 'ASSERT 5d settings 期望 1 行，实际 %', v_cnt;
  end if;
  select data_revision into v_rev_text from public.export_workspace_state_v1;
  if v_rev_text <> v_rev_after::text then
    raise exception 'ASSERT 5d state revision 不一致：view=% base=%', v_rev_text, v_rev_after;
  end if;
  v_proof := v_proof || jsonb_build_object('state_revision_text', 'pass', 'revision', v_rev_text);

  -- [5e] 白名单：敏感列在视图上不存在（42703）
  begin
    perform credentials_hash from public.export_agent_clients_v1 limit 1;
    raise exception 'ASSERT 白名单失败：credentials_hash 列不应存在';
  exception
    when undefined_column then
      v_proof := v_proof || jsonb_build_object('WHITELIST_col_absent', 'pass');
  end;

  -- [5f] 封闭视图：authenticated 42501（0004 决策：底表封闭暂不授予）
  begin
    perform count(*) from public.export_agent_advice_v1;
    raise exception 'ASSERT 封闭视图失败：export_agent_advice_v1 应 42501';
  exception
    when insufficient_privilege then
      v_proof := v_proof || jsonb_build_object('CLOSED_agent_advice_42501', 'pass');
  end;
  begin
    perform count(*) from public.export_automation_rules_v1;
    raise exception 'ASSERT 封闭视图失败：export_automation_rules_v1 应 42501';
  exception
    when insufficient_privilege then
      v_proof := v_proof || jsonb_build_object('CLOSED_automation_rules_42501', 'pass');
  end;

  -- ========== [6] RLS 继承：NONOWNER 经视图读 synthetic = 0 行 ==========
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_nonowner::text, 'role', 'authenticated')::text, true);
  select count(*) into v_cnt from public.export_life_data_v1
   where entity_key like 'mvp005test:%';
  if v_cnt <> 0 then
    raise exception 'ASSERT RLS 继承失败：NONOWNER 应见 0 行，实际 %', v_cnt;
  end if;
  v_proof := v_proof || jsonb_build_object('RLS_nonowner_zero_rows', 'pass');

  -- ========== [7] 收尾：RAISE 携带 proof → 整体回滚（真实库零残留） ==========
  raise exception 'MVP005_PROOF: %', v_proof::text;
end $$;
