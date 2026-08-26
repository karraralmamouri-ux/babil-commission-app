-- الدفعة ٣ — كاتب استقبال ملفات SaaS: أحداث التفعيل ولقطة المستخدمين.
--
-- assets/js/saas-import.js يحلّل ويعاين منذ دفعات سابقة؛ هذا الملف يختبر ما
-- أُضيف فوقه فقط: الكتابة الفعلية عبر import_saas_activation_events
-- وimport_saas_user_snapshot. لا تصنيف جِدّة هنا ولا استحقاق — تلك تبقى بمعزل.
--
-- كل معرّف هنا يبدأ بـSAI- أو sai. ليستحيل اشتباكه مع ملفّات أخرى.

\set ON_ERROR_STOP on
begin;

create table if not exists public.sai_results (check_name text, result text);
truncate public.sai_results;

create or replace function pg_temp.assert_that(p_name text, p_ok boolean, p_detail text default '')
returns void language plpgsql as $fn$
begin
  insert into public.sai_results values (p_name, case when p_ok then 'pass' else 'FAIL ' || p_detail end);
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
  ('20000000-0000-0000-0000-0000000000a1', 'sai-admin@fixture.invalid'),
  ('20000000-0000-0000-0000-0000000000a2', 'sai-acct@fixture.invalid'),
  ('20000000-0000-0000-0000-0000000000a3', 'sai-viewer@fixture.invalid')
on conflict (id) do nothing;
insert into public.profiles (id, full_name, email, role, is_active) values
  ('20000000-0000-0000-0000-0000000000a1', 'SAI Admin',  'sai-admin@fixture.invalid',  'admin',      true),
  ('20000000-0000-0000-0000-0000000000a2', 'SAI Acct',   'sai-acct@fixture.invalid',   'accountant', true),
  ('20000000-0000-0000-0000-0000000000a3', 'SAI Viewer', 'sai-viewer@fixture.invalid', 'viewer',     true)
on conflict (id) do update set role = excluded.role, is_active = true;

create temporary table sai_before on commit drop as
select
  (select count(*) from public.installation_entitlements) as entitlements,
  (select count(*) from public.subscriber_classifications) as classifications,
  (select count(*) from public.installation_payment_history) as history_rows,
  (select coalesce(sum(paid), 0) from public.commission_rows) as commission_paid,
  (select count(*) from public.financial_ledger) as ledger_rows;

select '     == saas activation intake ==';

-- ---------------------------------------------------------------------------
-- 1. الصلاحية: saas.import فقط.
-- ---------------------------------------------------------------------------

do $$
declare v_role text; v_blocked int := 0;
begin
  foreach v_role in array array['accountant', 'viewer'] loop
    perform pg_temp.act_as(v_role);
    begin
      perform public.import_saas_activation_events(
        'x.xlsx', 'sai-cap-check-' || v_role, 'v1',
        jsonb_build_array(jsonb_build_object('saas_event_id', 'e1', 'username', 'u1')),
        gen_random_uuid());
    exception when others then v_blocked := v_blocked + 1;
    end;
  end loop;
  perform pg_temp.assert_that('only saas.import may write activation events',
    v_blocked = 2, v_blocked || '/2 refused');
end $$;

-- ---------------------------------------------------------------------------
-- 2. request_id إلزامي.
-- ---------------------------------------------------------------------------

do $$
declare v_failed boolean := false;
begin
  perform pg_temp.act_as('admin');
  begin
    perform public.import_saas_activation_events(
      'x.xlsx', 'sai-null-request', 'v1',
      jsonb_build_array(jsonb_build_object('saas_event_id', 'e1', 'username', 'u1')),
      null);
  exception when others then v_failed := true;
  end;
  perform pg_temp.assert_that('a null request_id is refused', v_failed);
end $$;

-- ---------------------------------------------------------------------------
-- 3. الاستيراد الحقيقي: مقبول، مكرّر على مستوى الحدث، مرفوض بسببه.
-- ---------------------------------------------------------------------------

select pg_temp.act_as('admin');
select public.import_saas_activation_events(
  'august.xlsx', 'sai-checksum-1', 'v1',
  jsonb_build_array(
    jsonb_build_object('saas_event_id', 'SAI-EV-1', 'username', 'sai-user-one',
      'activations_count', 3, 'raw_parent', 'sai.parent'),
    jsonb_build_object('saas_event_id', 'SAI-EV-1', 'username', 'sai-user-one',
      'activations_count', 3, 'raw_parent', 'sai.parent'),
    jsonb_build_object('saas_event_id', 'SAI-EV-2', 'username', 'sai-user-two'),
    jsonb_build_object('saas_event_id', '', 'username', 'sai-user-three'),
    jsonb_build_object('saas_event_id', 'SAI-EV-4', 'username', '')
  ),
  '20000000-0000-0000-0000-0000000000c1'::uuid
) as first_run \gset

select pg_temp.assert_that('the writer reports a fresh run, not a replay',
  (:'first_run'::jsonb ->> 'replayed')::boolean = false);

select pg_temp.assert_that('source rows, accepted, duplicate and rejected counts are all reported',
  (:'first_run'::jsonb -> 'batch' ->> 'source_rows')::int = 5
  and (:'first_run'::jsonb -> 'batch' ->> 'accepted')::int = 2
  and (:'first_run'::jsonb -> 'batch' ->> 'duplicates')::int = 1
  and (:'first_run'::jsonb -> 'batch' ->> 'rejected')::int = 2);

select pg_temp.assert_that('the repeated event id landed exactly once — event-level dedup, never subscriber-level',
  (select count(*) from public.saas_activation_events where saas_event_id = 'SAI-EV-1') = 1);

select pg_temp.assert_that('a distinct event id for the same username is not treated as a duplicate',
  (select count(*) from public.saas_activation_events where saas_event_id = 'SAI-EV-2') = 1);

select pg_temp.assert_that('a batch row was created with the ACTIVATION_EVENTS kind and this checksum',
  (select count(*) from public.saas_import_batches
   where source_checksum = 'sai-checksum-1' and source_kind = 'ACTIVATION_EVENTS') = 1);

-- ---------------------------------------------------------------------------
-- 4. إعادة الإرسال بنفس الطلب: إعادة، لا تكرار.
-- ---------------------------------------------------------------------------

do $$
declare v_result jsonb; v_count bigint;
begin
  perform pg_temp.act_as('admin');
  v_result := public.import_saas_activation_events(
    'august.xlsx', 'sai-checksum-1', 'v1',
    jsonb_build_array(jsonb_build_object('saas_event_id', 'SAI-EV-1', 'username', 'sai-user-one')),
    '20000000-0000-0000-0000-0000000000c1'::uuid);
  select count(*) into v_count from public.saas_activation_events where saas_event_id like 'SAI-EV-%';
  perform pg_temp.assert_that('replaying the same request_id is idempotent',
    (v_result ->> 'replayed')::boolean and v_count = 2);
end $$;

-- ---------------------------------------------------------------------------
-- 5. نفس الملف حرفياً تحت طلب جديد: يُرفض بوضوح، لا يُستورد مرّتين بصمت.
-- ---------------------------------------------------------------------------

do $$
declare v_failed boolean := false;
begin
  perform pg_temp.act_as('admin');
  begin
    perform public.import_saas_activation_events(
      'august-renamed.xlsx', 'sai-checksum-1', 'v1',
      jsonb_build_array(jsonb_build_object('saas_event_id', 'SAI-EV-9', 'username', 'sai-user-nine')),
      gen_random_uuid());
  exception when others then v_failed := true;
  end;
  perform pg_temp.assert_that('re-importing the identical file checksum under a new request is refused',
    v_failed);
end $$;

-- ---------------------------------------------------------------------------
-- 6. لقطة المستخدمين: نفس الالتزامات — قدرة، request_id، snapshot_at إلزامي.
-- ---------------------------------------------------------------------------

do $$
declare v_failed boolean := false;
begin
  perform pg_temp.act_as('admin');
  begin
    perform public.import_saas_user_snapshot(
      'users.xlsx', 'sai-users-checksum-1', 'v1', null,
      jsonb_build_array(jsonb_build_object('saas_user_id', 'SAI-U-1', 'username', 'sai-user-one')),
      gen_random_uuid());
  exception when others then v_failed := true;
  end;
  perform pg_temp.assert_that('a null snapshot_at is refused — never derived from the file', v_failed);
end $$;

select pg_temp.act_as('admin');
select public.import_saas_user_snapshot(
  'users.xlsx', 'sai-users-checksum-1', 'v1', '2026-08-01T00:00:00+03:00'::timestamptz,
  jsonb_build_array(
    jsonb_build_object('saas_user_id', 'SAI-U-1', 'username', 'sai-user-one', 'profile_name', 'P-35000'),
    jsonb_build_object('saas_user_id', 'SAI-U-1', 'username', 'sai-user-one', 'profile_name', 'P-35000'),
    jsonb_build_object('saas_user_id', 'SAI-U-2', 'username', 'sai-user-two')
  ),
  '20000000-0000-0000-0000-0000000000c2'::uuid
) as snap_run \gset

select pg_temp.assert_that('the same saas_user_id twice in one snapshot counts as duplicate, not two rows',
  (:'snap_run'::jsonb -> 'batch' ->> 'accepted')::int = 2
  and (:'snap_run'::jsonb -> 'batch' ->> 'duplicates')::int = 1
  and (select count(*) from public.saas_user_snapshots where saas_user_id = 'SAI-U-1') = 1);

select pg_temp.assert_that('a batch row was created with the USERS_SNAPSHOT kind',
  (select count(*) from public.saas_import_batches
   where source_checksum = 'sai-users-checksum-1' and source_kind = 'USERS_SNAPSHOT') = 1);

-- ---------------------------------------------------------------------------
-- 7. معاينة المطابقة في import_batch_detail — حالة اليوم، لا تصنيف جِدّة.
-- ---------------------------------------------------------------------------

insert into public.subscriber_identities (username, identity_status, match_method) values
  ('sai-idm-matched', 'MATCHED', 'EXACT_USERNAME'),
  ('sai-idm-conflict', 'CONFLICT', null),
  ('sai-idm-review', 'NEEDS_REVIEW', null)
on conflict do nothing;

select pg_temp.act_as('admin');
select public.import_saas_activation_events(
  'idm.xlsx', 'sai-idm-checksum-1', 'v1',
  jsonb_build_array(
    jsonb_build_object('saas_event_id', 'SAI-IDM-1', 'username', 'sai-idm-matched'),
    jsonb_build_object('saas_event_id', 'SAI-IDM-2', 'username', 'sai-idm-conflict'),
    jsonb_build_object('saas_event_id', 'SAI-IDM-3', 'username', 'sai-idm-review'),
    jsonb_build_object('saas_event_id', 'SAI-IDM-4', 'username', 'sai-idm-unmatched')
  ),
  gen_random_uuid()
) as idm_run \gset

select (:'idm_run'::jsonb -> 'batch' ->> 'batch_id') as idm_batch \gset
select public.import_batch_detail(:'idm_batch'::uuid) as idm_detail \gset

select pg_temp.assert_that('the identity match preview counts each status exactly once, never guessing NEW',
  (:'idm_detail'::jsonb -> 'identity_match' ->> 'matched')::int = 1
  and (:'idm_detail'::jsonb -> 'identity_match' ->> 'conflict')::int = 1
  and (:'idm_detail'::jsonb -> 'identity_match' ->> 'needs_review')::int = 1
  and (:'idm_detail'::jsonb -> 'identity_match' ->> 'unmatched')::int = 1
  and (:'idm_detail'::jsonb -> 'identity_match' ->> 'total_subscribers')::int = 4);

-- ---------------------------------------------------------------------------
-- 8. لا أثر مالي، ولا تصنيف جِدّة — الكاتب يكتب التاريخ الخام فقط.
-- ---------------------------------------------------------------------------

select pg_temp.assert_that('no installation entitlement was created',
  (select entitlements from sai_before) = (select count(*) from public.installation_entitlements));

select pg_temp.assert_that('no newness classification was produced by the intake writer',
  (select classifications from sai_before) = (select count(*) from public.subscriber_classifications));

select pg_temp.assert_that('no historical payment row was created',
  (select history_rows from sai_before) = (select count(*) from public.installation_payment_history));

select pg_temp.assert_that('no commission payment changed',
  (select commission_paid from sai_before) = (select coalesce(sum(paid), 0) from public.commission_rows));

select pg_temp.assert_that('the financial ledger was not touched',
  (select ledger_rows from sai_before) = (select count(*) from public.financial_ledger));

select check_name, result from public.sai_results order by check_name;
drop table public.sai_results;

rollback;
