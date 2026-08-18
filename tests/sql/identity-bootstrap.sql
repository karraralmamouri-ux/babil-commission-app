-- تشغيل مسار بناء الهوية فعلياً من طرف إلى طرف.
--
-- سبب وجود هذا الملف منفصلاً: المسار بُني ولم يُستدعَ في أي اختبار، فمرّت
-- min(uuid) غير الموجودة إلى الإنتاج وظهرت عند أول تشغيل حقيقي. ومحاولة إضافة
-- الاختبار داخل data-intelligence.sql تعارضت مع تجهيزاته القائمة، فالعزل هنا
-- بملف ومعاملة ونطاق تسمية خاصّة به — لا بإضعاف توكيدات قائمة.
--
-- كل معرّف هنا يبدأ بـIB- أو ib- ليستحيل اشتباكه مع أي تجهيز آخر.

\set ON_ERROR_STOP on
\pset tuples_only on

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns text language sql as $$
  select case when p_cond then '      ok ' || p_label else 'FAILED: ' || p_label end;
$$;

begin;

select '     == identity bootstrap ==';

-- ---------------------------------------------------------------------------
-- تجهيز معزول
-- ---------------------------------------------------------------------------

insert into auth.users (id, email)
values ('1b000000-0000-0000-0000-000000000b01', 'ib@fixture.invalid')
on conflict do nothing;

insert into public.profiles (id, full_name, email, role, is_active)
values ('1b000000-0000-0000-0000-000000000b01', 'IB', 'ib@fixture.invalid', 'admin', true)
on conflict (id) do update set role = 'admin', is_active = true;

insert into public.agents (id, code, official_name)
values ('1b000000-0000-0000-0000-000000000b02', 'IB-AGENT', 'وكيل اختبار الهوية')
on conflict (code) do nothing;

-- اسم بديل محلول إلى وكيل، وآخر للمراجعة.
insert into public.agent_aliases (agent_id, alias, resolution)
values ('1b000000-0000-0000-0000-000000000b02', 'ib.known.parent', 'mapped'),
       (null, 'ib.unknown.parent', 'needs_review')
on conflict (alias_key) do nothing;

insert into public.saas_import_batches
  (id, source_kind, source_filename, source_checksum, parser_version, imported_by)
values ('1b000000-0000-0000-0000-000000000b03', 'USERS_SNAPSHOT', 'ib.xlsx',
        'ib-checksum-unique', 'v1', '1b000000-0000-0000-0000-000000000b01')
on conflict do nothing;

-- مشترك تاريخي واحد في السجل، ليُثبَت أن المطابقة به تعمل.
insert into public.installation_subscribers
  (subscriber_id, reseller, fdt, start_date, created_by)
values ('ib-in-registry', 'وكيل اختبار الهوية', '11', date '2026-01-01',
        '1b000000-0000-0000-0000-000000000b01')
on conflict do nothing;

-- ثلاث لقطات: مطابَقة، وغير مطابَقة، وأب غير محلول.
insert into public.saas_user_snapshots
  (import_batch_id, snapshot_at, saas_user_id, username, parent_name, fdt_code)
values
  ('1b000000-0000-0000-0000-000000000b03', now(), 'IB-SAAS-1', 'ib-in-registry',
   'ib.known.parent', '11'),
  ('1b000000-0000-0000-0000-000000000b03', now(), 'IB-SAAS-2', 'ib-not-in-registry',
   'ib.known.parent', '12'),
  ('1b000000-0000-0000-0000-000000000b03', now(), 'IB-SAAS-3', 'ib-orphan-parent',
   'ib.unknown.parent', null)
on conflict do nothing;

-- الحالة المالية قبل التشغيل، لتُقارَن بعده.
create temporary table ib_before on commit drop as
select
  (select count(*) from public.installation_entitlements) as entitlements,
  (select count(*) from public.installation_payment_history) as history_rows,
  (select coalesce(sum(amount), 0) from public.installation_payment_history) as history_amount,
  (select count(*) from public.installation_payments) as installation_payments,
  (select coalesce(sum(paid), 0) from public.commission_rows) as commission_paid,
  (select count(*) from public.financial_ledger) as ledger_rows;

-- ---------------------------------------------------------------------------
-- التشغيل الحقيقي — هذا هو ما كان مفقوداً
-- ---------------------------------------------------------------------------

select public.bootstrap_subscriber_identities() is not null as ran \gset

select pg_temp.ok(
  (select count(*) from public.subscriber_identities
   where saas_user_id like 'IB-SAAS-%') = 3,
  'المسار يُنشئ هوية لكل لقطة');

-- ---------------------------------------------------------------------------
-- الهوية من المعرّف المستقر لا من الاسم المعروض
-- ---------------------------------------------------------------------------

select pg_temp.ok(
  (select count(*) from public.subscriber_identities
   where saas_user_id in ('IB-SAAS-1','IB-SAAS-2','IB-SAAS-3')) = 3,
  'المفتاح هو معرّف SaaS المستقر');

select pg_temp.ok(
  (select count(*) from public.subscriber_identities
   where saas_user_id like 'IB-SAAS-%' and display_name is not null) = 0,
  'الاسم المعروض لا يدخل الهوية');

-- ---------------------------------------------------------------------------
-- المطابقة بالسجل التاريخي
-- ---------------------------------------------------------------------------

select pg_temp.ok(
  (select identity_status from public.subscriber_identities
   where saas_user_id = 'IB-SAAS-1') = 'MATCHED',
  'الموجود في السجل التاريخي يُطابَق');

select pg_temp.ok(
  (select match_method from public.subscriber_identities
   where saas_user_id = 'IB-SAAS-1') = 'EXACT_USERNAME',
  'المطابَق يحمل طريقة مطابقته');

select pg_temp.ok(
  (select installation_subscriber_id from public.subscriber_identities
   where saas_user_id = 'IB-SAAS-1') is not null,
  'المطابَق موصول بمشتركه التاريخي');

select pg_temp.ok(
  (select identity_status from public.subscriber_identities
   where saas_user_id = 'IB-SAAS-2') = 'UNMATCHED',
  'غير الموجود يبقى UNMATCHED ولا يُخترَع له مشترك');

select pg_temp.ok(
  (select installation_subscriber_id from public.subscriber_identities
   where saas_user_id = 'IB-SAAS-2') is null,
  'غير المطابَق بلا وصلة تاريخية');

-- ---------------------------------------------------------------------------
-- تصنيف الأب
-- ---------------------------------------------------------------------------

select pg_temp.ok(
  (select source_classification from public.subscriber_identities
   where saas_user_id = 'IB-SAAS-3') = 'UNKNOWN_PARENT',
  'الأب غير المحلول يُصنَّف UNKNOWN_PARENT');

select pg_temp.ok(
  (select effective_agent_id from public.subscriber_identities
   where saas_user_id = 'IB-SAAS-3') is null,
  'الأب غير المحلول لا يُنسَب إلى وكيل');

select pg_temp.ok(
  (select source_classification from public.subscriber_identities
   where saas_user_id = 'IB-SAAS-1') = 'RESELLER'
  and (select effective_agent_id from public.subscriber_identities
       where saas_user_id = 'IB-SAAS-1') = '1b000000-0000-0000-0000-000000000b02',
  'الأب المحلول يُنسَب إلى وكيله');

-- ---------------------------------------------------------------------------
-- إعادة التشغيل
-- ---------------------------------------------------------------------------

select public.bootstrap_subscriber_identities() is not null as ran_again \gset

select pg_temp.ok(
  (select count(*) from public.subscriber_identities
   where saas_user_id like 'IB-SAAS-%') = 3,
  'إعادة التشغيل لا تُنشئ تكراراً');

-- ---------------------------------------------------------------------------
-- لا أثر مالي — الغرض الأصلي من الفصل بين الهوية والمال
-- ---------------------------------------------------------------------------

select pg_temp.ok(
  (select entitlements from ib_before) = (select count(*) from public.installation_entitlements),
  'لا استحقاق تنصيب أُنشئ');

select pg_temp.ok(
  (select history_rows from ib_before) = (select count(*) from public.installation_payment_history),
  'لا صف دفعة تاريخية أُنشئ');

select pg_temp.ok(
  (select history_amount from ib_before)
    = (select coalesce(sum(amount), 0) from public.installation_payment_history),
  'مبلغ الدفعات التاريخية لم يتغيّر');

select pg_temp.ok(
  (select installation_payments from ib_before) = (select count(*) from public.installation_payments),
  'لا دفعة تنصيب أُنشئت');

select pg_temp.ok(
  (select commission_paid from ib_before)
    = (select coalesce(sum(paid), 0) from public.commission_rows),
  'لا عمولة دُفعت');

select pg_temp.ok(
  (select ledger_rows from ib_before) = (select count(*) from public.financial_ledger),
  'لا حركة في الدفتر المالي');

rollback;
