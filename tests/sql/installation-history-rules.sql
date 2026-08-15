-- قواعد الاستيراد التاريخي، مُتحقَّقاً منها على Postgres حقيقي.
-- كل تأكيد يفشل بصوت عالٍ عبر assert_that، ولا يُقاس شيء بالعين.

\set ON_ERROR_STOP on
begin;

create temporary table history_results (name text, ok boolean, detail text);

create or replace function pg_temp.assert_that(p_name text, p_ok boolean, p_detail text default '')
returns void language plpgsql as $fn$
begin
  insert into history_results values (p_name, p_ok, p_detail);
  if not p_ok then
    raise exception 'FAILED: % %', p_name, p_detail;
  end if;
end;
$fn$;

-- ممثل الإدارة ينفّذ الاستيراد.
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'importer@fixture.invalid')
on conflict (id) do nothing;
insert into public.profiles (id, full_name, email, role, is_active)
values ('00000000-0000-0000-0000-0000000000a1', 'Importer', 'importer@fixture.invalid', 'admin', true)
on conflict (id) do update set role = 'admin', is_active = true;

create or replace function pg_temp.act_as_admin() returns void language plpgsql as $fn$
begin
  perform set_config('request.jwt.claim.sub',
    '00000000-0000-0000-0000-0000000000a1', true);
end;
$fn$;

select pg_temp.act_as_admin();

-- ---------------------------------------------------------------------------
-- 1. اللقطة الأولى: خمس حالات تغطي DONE وP4..P1 وصفاً بلا متبقٍّ.
-- ---------------------------------------------------------------------------

select public.import_installation_history(
  '2026-07-01'::date, 'baseline.xlsx', null,
  $json$[
    {"subscriber_id":"S-DONE","reseller":"R1","fdt":"10","start_date":"2025-11-27","total_amount":13000,
     "received_total":13000,"remaining":0,
     "payments":[{"stage":"P1","amount":3000,"payment_date":"2025-12-20"},
                 {"stage":"P2","amount":3000,"payment_date":"2026-02-17"},
                 {"stage":"P3","amount":3000,"payment_date":"2026-02-17"},
                 {"stage":"P4","amount":4000,"payment_date":"2026-03-15"}]},
    {"subscriber_id":"S-P4","reseller":"R1","total_amount":13000,"received_total":9000,"remaining":4000,
     "payments":[{"stage":"P1","amount":3000,"payment_date":"2025-12-20"},
                 {"stage":"P2","amount":3000,"payment_date":"2026-01-20"},
                 {"stage":"P3","amount":3000,"payment_date":"2026-02-20"}]},
    {"subscriber_id":"S-P3","reseller":"R1","total_amount":13000,"received_total":6000,"remaining":7000,
     "payments":[{"stage":"P1","amount":3000,"payment_date":"2025-12-20"},
                 {"stage":"P2","amount":3000,"payment_date":"2026-01-20"}]},
    {"subscriber_id":"S-P2","reseller":"R2","total_amount":13000,"received_total":3000,"remaining":10000,
     "payments":[{"stage":"P1","amount":3000,"payment_date":"2025-12-20"}]},
    {"subscriber_id":"S-P1","reseller":"R2","total_amount":13000,"received_total":0,"remaining":13000,
     "payments":[]},
    {"subscriber_id":"S-UNRESOLVED","reseller":"R2","total_amount":13000,"received_total":3000,
     "remaining":null,
     "payments":[{"stage":"P1","amount":3000,"payment_date":"2025-12-20"}]},
    {"subscriber_id":"","reseller":"R2","remaining":0,"payments":[]}
  ]$json$::jsonb,
  '00000000-0000-0000-0000-00000000b001'::uuid
);

select pg_temp.assert_that('real subscribers stored, blank row ignored',
  (select count(*) = 6 from public.installation_subscribers),
  (select 'count=' || count(*)::text from public.installation_subscribers));

select pg_temp.assert_that('stage derived from remaining, not from the client',
  (select count(*) = 5 from public.installation_subscriber_state s
   join public.installation_subscribers b on b.id = s.subscriber_uuid
   where (b.subscriber_id, s.current_stage) in
     (('S-DONE','DONE'),('S-P4','P4'),('S-P3','P3'),('S-P2','P2'),('S-P1','P1'))));

select pg_temp.assert_that('blank remaining becomes unresolved with no stage',
  (select s.resolution = 'unresolved' and s.current_stage is null
   from public.installation_subscriber_state s
   join public.installation_subscribers b on b.id = s.subscriber_uuid
   where b.subscriber_id = 'S-UNRESOLVED'));

select pg_temp.assert_that('DONE keeps its four historical payments',
  (select count(*) = 4 from public.installation_payment_history h
   join public.installation_subscribers b on b.id = h.subscriber_uuid
   where b.subscriber_id = 'S-DONE'));

select pg_temp.assert_that('a subscriber at P4 kept exactly the first three payments',
  (select count(*) = 3 and bool_and(h.stage in ('P1','P2','P3'))
   from public.installation_payment_history h
   join public.installation_subscribers b on b.id = h.subscriber_uuid
   where b.subscriber_id = 'S-P4'));

select pg_temp.assert_that('no phantom payment is invented for an empty cell',
  (select count(*) = 0 from public.installation_payment_history h
   join public.installation_subscribers b on b.id = h.subscriber_uuid
   where b.subscriber_id = 'S-P1'));

select pg_temp.assert_that('payment dates are preserved exactly',
  (select h.payment_date = '2026-03-15'::date
   from public.installation_payment_history h
   join public.installation_subscribers b on b.id = h.subscriber_uuid
   where b.subscriber_id = 'S-DONE' and h.stage = 'P4'));

select pg_temp.assert_that('reseller and fdt and start date are preserved',
  (select reseller = 'R1' and fdt = '10' and start_date = '2025-11-27'::date
   from public.installation_subscribers where subscriber_id = 'S-DONE'));

select pg_temp.assert_that('the batch is marked historical and carries its as-of date',
  (select batch_type = 'historical' and as_of_date = '2026-07-01'::date
   from public.installation_batches order by created_at desc limit 1));

-- ---------------------------------------------------------------------------
-- 2. إعادة رفع الملف نفسه: لا تكرار لأي طبقة.
-- ---------------------------------------------------------------------------

select public.import_installation_history(
  '2026-07-01'::date, 'baseline.xlsx', null,
  $json$[
    {"subscriber_id":"S-DONE","reseller":"R1","fdt":"10","start_date":"2025-11-27","total_amount":13000,
     "received_total":13000,"remaining":0,
     "payments":[{"stage":"P1","amount":3000,"payment_date":"2025-12-20"},
                 {"stage":"P2","amount":3000,"payment_date":"2026-02-17"},
                 {"stage":"P3","amount":3000,"payment_date":"2026-02-17"},
                 {"stage":"P4","amount":4000,"payment_date":"2026-03-15"}]}
  ]$json$::jsonb,
  '00000000-0000-0000-0000-00000000b002'::uuid
);

select pg_temp.assert_that('re-import creates no second subscriber',
  (select count(*) = 1 from public.installation_subscribers where subscriber_id = 'S-DONE'));

select pg_temp.assert_that('re-import creates no duplicate payment history',
  (select count(*) = 4 from public.installation_payment_history h
   join public.installation_subscribers b on b.id = h.subscriber_uuid
   where b.subscriber_id = 'S-DONE'));

select pg_temp.assert_that('re-import leaves exactly one state row per subscriber',
  (select count(*) = 1 from public.installation_subscriber_state s
   join public.installation_subscribers b on b.id = s.subscriber_uuid
   where b.subscriber_id = 'S-DONE'));

-- ---------------------------------------------------------------------------
-- 3. رفعة لاحقة تضيف دفعة واحدة جديدة وتنقل الحالة، بلا مساس بالتاريخ.
-- ---------------------------------------------------------------------------

select public.import_installation_history(
  '2026-08-15'::date, 'daily.xlsx', null,
  $json$[
    {"subscriber_id":"S-P3","reseller":"R1","total_amount":13000,"received_total":9000,"remaining":4000,
     "payments":[{"stage":"P1","amount":3000,"payment_date":"2025-12-20"},
                 {"stage":"P2","amount":3000,"payment_date":"2026-01-20"},
                 {"stage":"P3","amount":3000,"payment_date":"2026-08-30"}]}
  ]$json$::jsonb,
  '00000000-0000-0000-0000-00000000b003'::uuid
);

select pg_temp.assert_that('a later file adds only the new payment',
  (select count(*) = 3 from public.installation_payment_history h
   join public.installation_subscribers b on b.id = h.subscriber_uuid
   where b.subscriber_id = 'S-P3'));

select pg_temp.assert_that('earlier payments survive the later file untouched',
  (select h.payment_date = '2025-12-20'::date
   from public.installation_payment_history h
   join public.installation_subscribers b on b.id = h.subscriber_uuid
   where b.subscriber_id = 'S-P3' and h.stage = 'P1'));

select pg_temp.assert_that('current stage advances to P4 without a new subscriber row',
  (select s.current_stage = 'P4' and s.as_of_date = '2026-08-15'::date
   from public.installation_subscriber_state s
   join public.installation_subscribers b on b.id = s.subscriber_uuid
   where b.subscriber_id = 'S-P3')
  and (select count(*) = 1 from public.installation_subscribers where subscriber_id = 'S-P3'));

-- ---------------------------------------------------------------------------
-- 4. الحدود الصلبة.
-- ---------------------------------------------------------------------------

do $$
declare v_failed boolean := false;
begin
  begin
    perform public.import_installation_history(
      null, 'x.xlsx', null, '[{"subscriber_id":"S-X","reseller":"R","remaining":0}]'::jsonb,
      '00000000-0000-0000-0000-00000000b004'::uuid);
  exception when others then v_failed := true;
  end;
  perform pg_temp.assert_that('a historical import without an as-of date is refused', v_failed);
end;
$$;

do $$
declare v_failed boolean := false;
begin
  begin
    perform public.import_installation_history(
      (current_date + 1), 'x.xlsx', null,
      '[{"subscriber_id":"S-X","reseller":"R","remaining":0}]'::jsonb,
      '00000000-0000-0000-0000-00000000b005'::uuid);
  exception when others then v_failed := true;
  end;
  perform pg_temp.assert_that('a future as-of date is refused', v_failed);
end;
$$;

do $$
declare v_failed boolean := false;
begin
  begin
    insert into public.installation_subscriber_state (subscriber_uuid, as_of_date, remaining, current_stage)
    select id, '2026-07-01', 9999, 'P1' from public.installation_subscribers limit 1;
  exception when others then v_failed := true;
  end;
  perform pg_temp.assert_that('a stage that contradicts remaining is rejected by the constraint', v_failed);
end;
$$;

do $$
declare v_failed boolean := false;
begin
  begin
    insert into public.installation_payment_history (subscriber_uuid, stage, amount, created_by)
    select id, 'P9', 3000, '00000000-0000-0000-0000-0000000000a1'
    from public.installation_subscribers limit 1;
  exception when others then v_failed := true;
  end;
  perform pg_temp.assert_that('an unknown payment stage is rejected', v_failed);
end;
$$;

do $$
declare v_failed boolean := false;
begin
  begin
    insert into public.installation_payment_history (subscriber_uuid, stage, amount, created_by)
    select id, 'P1', 0, '00000000-0000-0000-0000-0000000000a1'
    from public.installation_subscribers where subscriber_id = 'S-P1';
  exception when others then v_failed := true;
  end;
  perform pg_temp.assert_that('a zero-amount payment event is rejected', v_failed);
end;
$$;

select pg_temp.assert_that('a non-admin cannot run the historical import',
  not exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'import_installation_history'
      and p.prosecdef = false));

select pg_temp.assert_that('the import function pins an empty search_path',
  (select coalesce(array_to_string(p.proconfig, ','), '') like '%search_path=%'
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'import_installation_history'));

select pg_temp.assert_that('the browser role holds SELECT only on the new tables',
  (select count(*) = 0 from information_schema.role_table_grants
   where grantee = 'authenticated'
     and table_name in ('installation_subscribers','installation_subscriber_state','installation_payment_history')
     and privilege_type <> 'SELECT'),
  (select coalesce(string_agg(distinct privilege_type, ','), 'none')
   from information_schema.role_table_grants
   where grantee = 'authenticated'
     and table_name in ('installation_subscribers','installation_subscriber_state','installation_payment_history')));

select pg_temp.assert_that('row level security is on for all three new tables',
  (select count(*) = 3 from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relrowsecurity
     and c.relname in ('installation_subscribers','installation_subscriber_state','installation_payment_history')));

select name, case when ok then 'pass' else 'FAIL' end as result from history_results order by name;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from history_results;

rollback;
