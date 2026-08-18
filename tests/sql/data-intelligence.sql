-- ضمانات طبقة البيانات الأساسية على قاعدة حقيقية.
-- كل تجربة تُثبت منعاً، لا نجاحاً فقط. القيم كلها مُختلَقة.

\set ON_ERROR_STOP on
\pset tuples_only on

create or replace function pg_temp.must_fail(p_sql text, p_label text)
returns text language plpgsql as $$
begin
  execute p_sql;
  return 'FAIL  ' || p_label || ' — مرّ وكان يجب أن يُرفض';
exception when others then
  return 'ok    ' || p_label;
end;
$$;

begin;

insert into auth.users (id, email) values
  ('22222222-2222-2222-2222-222222222222', 'tester@fixture.invalid')
on conflict do nothing;

insert into public.agents (code, official_name) values ('T-AG', 'وكيل تجربة')
on conflict (code) do nothing;

insert into public.saas_import_batches (
  source_kind, source_filename, source_checksum, parser_version, imported_by
) values (
  'ACTIVATION_EVENTS', 'fixture.xlsx', 'checksum-fixture-1', 'v1',
  '22222222-2222-2222-2222-222222222222'
) on conflict do nothing;

-- 1. اكتمال المصدر يبدأ UNKNOWN دائماً.
select case when completeness_status = 'UNKNOWN'
  then 'ok    الاكتمال الافتراضي UNKNOWN'
  else 'FAIL  الاكتمال الافتراضي ' || completeness_status end
from public.saas_import_batches where source_checksum = 'checksum-fixture-1';

-- 2. الملف نفسه لا يُستورد مرتين ولو بدلّ اسمه.
select pg_temp.must_fail($$
  insert into public.saas_import_batches (
    source_kind, source_filename, source_checksum, parser_version, imported_by
  ) values ('ACTIVATION_EVENTS', 'renamed.xlsx', 'checksum-fixture-1', 'v1',
            '22222222-2222-2222-2222-222222222222')
$$, 'البصمة المكررة مرفوضة ولو تغيّر الاسم');

-- 3. الحدث الواحد لا يدخل مرتين.
insert into public.saas_activation_events (import_batch_id, saas_event_id, username)
select id, 'EVT-1', 'u-fixture' from public.saas_import_batches
where source_checksum = 'checksum-fixture-1';

select pg_temp.must_fail($$
  insert into public.saas_activation_events (import_batch_id, saas_event_id, username)
  select id, 'EVT-1', 'u-fixture-other' from public.saas_import_batches
  where source_checksum = 'checksum-fixture-1'
$$, 'معرّف الحدث المكرر مرفوض');

-- 4. مشتركان بالاسم نفسه وحدثان مختلفان: مسموح. هذا جوهر منع الإزالة بالمشترك.
insert into public.saas_activation_events (import_batch_id, saas_event_id, username)
select id, 'EVT-2', 'u-fixture' from public.saas_import_batches
where source_checksum = 'checksum-fixture-1';

select case when count(*) = 2 then 'ok    حدثان لمشترك واحد محفوظان'
  else 'FAIL  حدثا المشترك الواحد ' || count(*) end
from public.saas_activation_events where username = 'u-fixture';

-- 5. التاريخ الخام لا يُعدَّل ولا يُحذف.
select pg_temp.must_fail(
  $$update public.saas_activation_events set username = 'x' where saas_event_id = 'EVT-1'$$,
  'تعديل حدث خام ممنوع');
select pg_temp.must_fail(
  $$delete from public.saas_activation_events where saas_event_id = 'EVT-1'$$,
  'حذف حدث خام ممنوع');

-- 6. الاسم البديل المربوط يلزمه وكيل؛ والمراجعة لا وكيل لها.
select pg_temp.must_fail($$
  insert into public.agent_aliases (agent_id, alias, resolution)
  values (null, 'alias-no-agent', 'mapped')
$$, 'ربط مؤكد بلا وكيل مرفوض');

select pg_temp.must_fail($$
  insert into public.agent_aliases (agent_id, alias, resolution)
  select id, 'alias-review', 'needs_review' from public.agents where code = 'T-AG'
$$, 'مراجعة تحمل وكيلاً مرفوضة');

insert into public.agent_aliases (agent_id, alias, resolution)
values (null, 'office.99', 'needs_review');
select case when (select agent_id from public.resolve_parent_alias('office.99')) is null
       and (select resolution from public.resolve_parent_alias('office.99')) = 'needs_review'
  then 'ok    الأب المجهول للمراجعة بلا وكيل'
  else 'FAIL  الأب المجهول' end;

-- 7. الاسم البديل لا يخدم وكيلين.
select pg_temp.must_fail($$
  insert into public.agent_aliases (agent_id, alias, resolution)
  select id, 'OFFICE.99', 'mapped' from public.agents where code = 'T-AG'
$$, 'الاسم البديل المكرر مرفوض بغض النظر عن حالة الأحرف');

-- 8. الحارس الجوهري: NEW تستلزم مصدراً مكتملاً مُثبتاً.
select pg_temp.must_fail($$
  insert into public.subscriber_classifications
    (username_key, classification, reason_code, source_completeness)
  values ('u-guard', 'NEW', 'COMPLETE_LIFETIME_HISTORY_OBSERVED', 'UNKNOWN')
$$, 'NEW من مصدر مجهول الاكتمال مرفوضة');

select pg_temp.must_fail($$
  insert into public.subscriber_classifications
    (username_key, classification, reason_code, source_completeness)
  values ('u-guard', 'NEW', 'COMPLETE_LIFETIME_HISTORY_OBSERVED', 'PARTIAL')
$$, 'NEW من مصدر ناقص مرفوضة');

select pg_temp.must_fail($$
  insert into public.subscriber_classifications
    (username_key, classification, reason_code, source_completeness)
  values ('u-guard', 'NEW', 'UNKNOWN_SOURCE_COMPLETENESS', 'COMPLETE')
$$, 'NEW بسبب لا يدل على اكتمال مرفوضة');

insert into public.subscriber_classifications
  (username_key, classification, reason_code, source_completeness)
values ('u-guard', 'NEW', 'COMPLETE_LIFETIME_HISTORY_OBSERVED', 'COMPLETE');
select 'ok    NEW مقبولة بمصدر مكتمل مُثبت';

-- NEEDS_REVIEW وEXISTING لا يقيّدهما الحارس.
insert into public.subscriber_classifications
  (username_key, classification, reason_code, source_completeness)
values ('u-review', 'NEEDS_REVIEW', 'UNKNOWN_SOURCE_COMPLETENESS', 'UNKNOWN'),
       ('u-old', 'EXISTING', 'LIFETIME_COUNT_EXCEEDS_OBSERVED', 'UNKNOWN');
select 'ok    المراجعة والقديم بلا قيد اكتمال';

-- 9. المطابَق يحمل دليل مطابقته.
select pg_temp.must_fail($$
  insert into public.subscriber_identities (username, identity_status)
  values ('u-nomethod', 'MATCHED')
$$, 'مطابقة بلا طريقة مرفوضة');

insert into public.subscriber_identities (username, identity_status, match_method, saas_user_id)
values ('u-ok', 'MATCHED', 'SAAS_USER_ID', 'S-100');
select 'ok    المطابقة بطريقة معلنة مقبولة';

-- 10. معرّف SaaS لا يخدم مشتركين.
select pg_temp.must_fail($$
  insert into public.subscriber_identities (username, identity_status, match_method, saas_user_id)
  values ('u-other', 'MATCHED', 'SAAS_USER_ID', 'S-100')
$$, 'معرّف SaaS مكرر مرفوض');

-- 11. الأساس المالي التاريخي لم يُمَس.
select case when count(*) = 0 then 'ok    لا استحقاق ولا دفعة أنشأتها هذه الطبقة'
  else 'FAIL  الطبقة أنشأت مالاً' end
from public.installation_entitlements;

-- 12. لا صلاحية TRUNCATE على أي جدول جديد — الثغرة التي تكررت مرتين.
select case when count(*) = 0 then 'ok    لا TRUNCATE لأي دور تطبيقي'
  else 'FAIL  TRUNCATE مكشوف على ' || string_agg(distinct table_name, ', ') end
from (
  select c.relname as table_name, a.privilege_type, a.grantee::regrole::text as who
  from pg_class c
  cross join lateral aclexplode(c.relacl) a
  where c.relnamespace = 'public'::regnamespace
    and c.relname in ('agents','agent_aliases','fdts','packages','saas_import_batches',
      'saas_user_snapshots','saas_activation_events','subscriber_identities',
      'subscriber_attribution_history','subscriber_classifications')
    and a.privilege_type in ('TRUNCATE','DELETE','UPDATE','INSERT')
    and a.grantee::regrole::text in ('authenticated','anon','public')
) t;

-- 13. الأدوار التطبيقية تقرأ ولا تكتب.
select case when count(*) = 10 then 'ok    قراءة فقط على الجداول العشرة'
  else 'FAIL  القراءة الممنوحة ' || count(*) end
from (
  select distinct c.relname
  from pg_class c cross join lateral aclexplode(c.relacl) a
  where c.relnamespace = 'public'::regnamespace
    and a.privilege_type = 'SELECT' and a.grantee::regrole::text = 'authenticated'
    and c.relname in ('agents','agent_aliases','fdts','packages','saas_import_batches',
      'saas_user_snapshots','saas_activation_events','subscriber_identities',
      'subscriber_attribution_history','subscriber_classifications')
) t;

-- 14. بذر البيانات الرئيسية حتمي في الحالتين.
-- بلا إعدادات: وهي حالة النشر الأول بالضبط، وفيها ظهر عيب حقيقي كان
-- يُبلّغ عدد الإدراج بدل الحالة الراهنة فيبدو البذر متغيّراً.
delete from public.app_settings where key = 'raw_import';
select case when public.bootstrap_master_data_from_settings()
             = public.bootstrap_master_data_from_settings()
  then 'ok    البذر حتمي على قاعدة بلا إعدادات'
  else 'FAIL  البذر غير حتمي بلا إعدادات' end;

select case when (public.bootstrap_master_data_from_settings() ->> 'packages')::int = 5
  then 'ok    الباقات الخمس مبذورة بلا إعدادات'
  else 'FAIL  الباقات بلا إعدادات' end;

-- ومع إعدادات حقيقية.
insert into public.app_settings (key, value, updated_by)
values ('raw_import',
  '{"profiles":[{"key":"p35"}],
    "agents":[{"id":"a1","name":"وكيل","accounts":["r.test.one","r.test.one.sub1"]}],
    "cabinetRanges":[{"id":"r1","from":1,"to":3,"ownerId":"a1"}]}'::jsonb,
  '22222222-2222-2222-2222-222222222222')
on conflict (key) do update set value = excluded.value;

select case when public.bootstrap_master_data_from_settings()
             = public.bootstrap_master_data_from_settings()
  then 'ok    البذر حتمي مع إعدادات'
  else 'FAIL  البذر غير حتمي مع إعدادات' end;

select case when (select count(*) from public.agent_aliases
                  where alias_key in ('r.test.one', 'r.test.one.sub1')) = 2
  then 'ok    الحساب الفرعي يتبع وكيله'
  else 'FAIL  الأسماء البديلة' end;

-- 15. لا عمود لكلمة السر في أي جدول.
select case when count(*) = 0 then 'ok    لا عمود كلمة سر في المخطط'
  else 'FAIL  عمود سر موجود: ' || string_agg(table_name || '.' || column_name, ', ') end
from information_schema.columns
where table_schema = 'public'
  and (column_name ilike '%password%' or column_name ilike '%ct_pass%');

rollback;
