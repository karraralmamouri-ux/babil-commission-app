-- الدفعة ٢ — غلاف تشغيل المطابقة، وقراءتها المُصفَّحة.
--
-- bootstrap_subscriber_identities() نفسها مُختبَرة في identity-bootstrap.sql.
-- هذا الملف يختبر ما أُضيف فوقها: القدرة، وإعادة التنفيذ الآمنة عبر
-- request_id، وأن القراءة المُصفَّحة لا تُنشئ سلطةً ثانية على البيانات.
--
-- كل معرّف هنا يبدأ بـIO- أو io. ليستحيل اشتباكه مع ملفّات أخرى.

\set ON_ERROR_STOP on
begin;

create table if not exists public.io_results (check_name text, result text);
truncate public.io_results;

create or replace function pg_temp.assert_that(p_name text, p_ok boolean, p_detail text default '')
returns void language plpgsql as $fn$
begin
  insert into public.io_results values (p_name, case when p_ok then 'pass' else 'FAIL ' || p_detail end);
  if not p_ok then
    raise exception 'FAILED: % %', p_name, p_detail;
  end if;
end;
$fn$;

create or replace function pg_temp.act_as(p_role text) returns void language plpgsql as $fn$
declare v_uid uuid;
begin
  select id into v_uid from public.profiles where role = p_role limit 1;
  perform set_config('request.jwt.claim.sub', v_uid::text, true);
end;
$fn$;

-- ------------------------------------------------------------------ fixtures --
insert into auth.users (id, email) values
  ('10000000-0000-0000-0000-0000000000a1', 'io-admin@fixture.invalid'),
  ('10000000-0000-0000-0000-0000000000a2', 'io-acct@fixture.invalid'),
  ('10000000-0000-0000-0000-0000000000a3', 'io-viewer@fixture.invalid')
on conflict (id) do nothing;
insert into public.profiles (id, full_name, email, role, is_active) values
  ('10000000-0000-0000-0000-0000000000a1', 'IO Admin',  'io-admin@fixture.invalid',  'admin',      true),
  ('10000000-0000-0000-0000-0000000000a2', 'IO Acct',   'io-acct@fixture.invalid',   'accountant', true),
  ('10000000-0000-0000-0000-0000000000a3', 'IO Viewer', 'io-viewer@fixture.invalid', 'viewer',     true)
on conflict (id) do update set role = excluded.role, is_active = true;

insert into public.saas_import_batches
  (id, source_kind, source_filename, source_checksum, parser_version, imported_by)
values ('10000000-0000-0000-0000-0000000000b1', 'USERS_SNAPSHOT', 'io.xlsx',
        'io-checksum-unique', 'v1', '10000000-0000-0000-0000-0000000000a1')
on conflict do nothing;

insert into public.saas_user_snapshots
  (import_batch_id, snapshot_at, saas_user_id, username, parent_name, fdt_code)
values
  ('10000000-0000-0000-0000-0000000000b1', now(), 'IO-SAAS-1', 'io-subscriber-one', 'io.some.parent', '21')
on conflict do nothing;

create temporary table io_before on commit drop as
select
  (select count(*) from public.installation_entitlements) as entitlements,
  (select count(*) from public.installation_payment_history) as history_rows,
  (select count(*) from public.installation_payments) as installation_payments,
  (select coalesce(sum(paid), 0) from public.commission_rows) as commission_paid,
  (select count(*) from public.financial_ledger) as ledger_rows;

select '     == identity operations ==';

-- ---------------------------------------------------------------------------
-- 1. الصلاحية: subscriber.match فقط — وهي اليوم للمدير وحده.
-- ---------------------------------------------------------------------------

do $$
declare v_role text; v_blocked int := 0;
begin
  foreach v_role in array array['accountant', 'viewer'] loop
    perform pg_temp.act_as(v_role);
    begin
      perform public.run_identity_bootstrap(gen_random_uuid());
    exception when others then v_blocked := v_blocked + 1;
    end;
    begin
      perform public.page_subscriber_identities();
    exception when others then v_blocked := v_blocked + 1;
    end;
  end loop;
  perform pg_temp.assert_that('only subscriber.match may run or browse identity matching',
    v_blocked = 4, v_blocked || '/4 refused');
end $$;

-- ---------------------------------------------------------------------------
-- 2. request_id إلزامي.
-- ---------------------------------------------------------------------------

do $$
declare v_failed boolean := false;
begin
  perform pg_temp.act_as('admin');
  begin
    perform public.run_identity_bootstrap(null);
  exception when others then v_failed := true;
  end;
  perform pg_temp.assert_that('a null request_id is refused', v_failed);
end $$;

-- ---------------------------------------------------------------------------
-- 3. التشغيل الحقيقي عبر الغلاف.
-- ---------------------------------------------------------------------------

select pg_temp.act_as('admin');
select public.run_identity_bootstrap('10000000-0000-0000-0000-0000000000c1'::uuid) as first_run \gset

select pg_temp.assert_that('the wrapper reports a fresh run, not a replay',
  (:'first_run'::jsonb ->> 'replayed')::boolean = false);

select pg_temp.assert_that('the wrapper result mirrors the engine''s own counters',
  (:'first_run'::jsonb -> 'result') ? 'identities_created'
  and (:'first_run'::jsonb -> 'result') ? 'identities_total'
  and (:'first_run'::jsonb -> 'result') ? 'conflicts'
  and (:'first_run'::jsonb -> 'result') ? 'unmatched');

select pg_temp.assert_that('the fixture snapshot was actually matched or recorded',
  (select count(*) from public.subscriber_identities where saas_user_id = 'IO-SAAS-1') = 1);

select pg_temp.assert_that('the run is audited under its own action name',
  (select count(*) = 1 from public.audit_logs
   where action = 'identity.bootstrap.run' and request_id = '10000000-0000-0000-0000-0000000000c1'));

-- ---------------------------------------------------------------------------
-- 4. إعادة الإرسال بنفس الطلب: إعادة، لا تكرار.
-- ---------------------------------------------------------------------------

do $$
declare v_result jsonb; v_count bigint;
begin
  perform pg_temp.act_as('admin');
  v_result := public.run_identity_bootstrap('10000000-0000-0000-0000-0000000000c1'::uuid);
  select count(*) into v_count from public.subscriber_identities where saas_user_id = 'IO-SAAS-1';
  perform pg_temp.assert_that('replaying the same request_id is idempotent',
    (v_result ->> 'replayed')::boolean and v_count = 1);
end $$;

do $$
declare v_count bigint;
begin
  select count(*) into v_count from public.audit_logs
  where action = 'identity.bootstrap.run' and request_id = '10000000-0000-0000-0000-0000000000c1';
  perform pg_temp.assert_that('a replayed run adds no second audit row', v_count = 1);
end $$;

-- ---------------------------------------------------------------------------
-- 5. القراءة المُصفَّحة: تعرض ما أنتجه التشغيل، لا تحكم على شيء بنفسها.
-- ---------------------------------------------------------------------------

select pg_temp.act_as('admin');
select public.page_subscriber_identities(p_search := 'IO-SAAS-1') as page_one \gset

select pg_temp.assert_that('the page contract returns the matched fixture identity',
  (:'page_one'::jsonb -> 'rows' -> 0 ->> 'saas_user_id') = 'IO-SAAS-1');

select public.page_subscriber_identities(p_status := 'CONFLICT', p_limit := 1) as conflict_page \gset

select pg_temp.assert_that('filtering by status never returns another status',
  coalesce((:'conflict_page'::jsonb -> 'rows' -> 0 ->> 'identity_status'), 'CONFLICT') = 'CONFLICT');

-- ---------------------------------------------------------------------------
-- 6. مركز القرار: مسار تعارض الهوية يفتح المراجعة، لا سجلّ المشتركين العام.
-- ---------------------------------------------------------------------------

select pg_temp.act_as('admin');
select public.action_center() as center \gset

select pg_temp.assert_that('the identity conflict decision now opens the review screen',
  (select g ->> 'path' from jsonb_array_elements(:'center'::jsonb -> 'groups') g
   where g ->> 'key' = 'IDENTITY_CONFLICT') = '/system/identities?status=CONFLICT');

select pg_temp.assert_that('the source-incomplete decision opens the import center, not the retired legacy workspace',
  (select g ->> 'path' from jsonb_array_elements(:'center'::jsonb -> 'groups') g
   where g ->> 'key' = 'SOURCE_INCOMPLETE') = '/system/imports');

-- ---------------------------------------------------------------------------
-- 7. لا أثر مالي — الغلاف لا يفتح باباً جانبياً إلى المال.
-- ---------------------------------------------------------------------------

select pg_temp.assert_that('no installation entitlement was created',
  (select entitlements from io_before) = (select count(*) from public.installation_entitlements));

select pg_temp.assert_that('no historical payment row was created',
  (select history_rows from io_before) = (select count(*) from public.installation_payment_history));

select pg_temp.assert_that('no installation payment was created',
  (select installation_payments from io_before) = (select count(*) from public.installation_payments));

select pg_temp.assert_that('no commission payment changed',
  (select commission_paid from io_before) = (select coalesce(sum(paid), 0) from public.commission_rows));

select pg_temp.assert_that('the financial ledger was not touched',
  (select ledger_rows from io_before) = (select count(*) from public.financial_ledger));

-- ---------------------------------------------------------------------------
-- 8. لا مشترك جديد يُخترَع — «مطابقة الهوية» ليست «مشتركاً جديداً».
-- ---------------------------------------------------------------------------

select pg_temp.assert_that('bootstrap never invents an installation_subscribers row',
  (select count(*) from public.installation_subscribers
   where subscriber_id = 'io-subscriber-one') = 0,
  'no registry row exists for this fixture — the identity must stay UNMATCHED, not gain one');

select pg_temp.assert_that('the unmatched fixture carries no installation_subscriber_id',
  (select installation_subscriber_id from public.subscriber_identities
   where saas_user_id = 'IO-SAAS-1') is null);

select check_name, result from public.io_results order by check_name;
drop table public.io_results;

rollback;
