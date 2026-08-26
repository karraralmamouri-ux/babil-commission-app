-- PR-B3: LIVE-01 (عائدية مؤرَّخة بالحدث) وLIVE-02 (نطاق FDT بالرقم ٩٤–١١٩).
--
-- الخطر: نقل عائدية اليوم يُعيد كتابة استحقاق أمسٍ عند إعادة الحساب، وكابينة
-- غير مسجَّلة خارج المدى تُحجَب بلا سبب. معزول بنطاق تسمية B3-/b3-.

\set ON_ERROR_STOP on
\pset tuples_only on

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns text language sql as $$
  select case when p_cond then '            ok ' || p_label else 'FAILED: ' || p_label end;
$$;

begin;

select '           == pr-b3: live-01 + live-02 ==';

insert into auth.users (id, email) values ('63000000-0000-0000-0000-0000000000c1','b3@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active)
values ('63000000-0000-0000-0000-0000000000c1','B3','b3@fixture.invalid','admin',true)
on conflict (id) do update set role='admin', is_active=true;

insert into public.agents (id, code, official_name) values
  ('63000000-0000-0000-0000-0000000000c2','B3-OLD','وكيل قديم'),
  ('63000000-0000-0000-0000-0000000000c3','B3-NEW','وكيل جديد'),
  ('63000000-0000-0000-0000-0000000000c4','B3-THIRD','وكيل ثالث')
on conflict (code) do nothing;

insert into public.packages (code, name, semantic_category)
values ('P-35000','P-35000','PAID_PACKAGE') on conflict (code) do nothing;

insert into public.agent_aliases (agent_id, alias, resolution) values
  ('63000000-0000-0000-0000-0000000000c3', 'b3.new', 'mapped')
on conflict (alias_key) do nothing;

insert into public.saas_import_batches
  (id, source_kind, source_filename, source_checksum, parser_version, imported_by, completeness_status)
values ('63000000-0000-0000-0000-0000000000c5','ACTIVATION_EVENTS','b3.xlsx','b3-sum','v1',
        '63000000-0000-0000-0000-0000000000c1','COMPLETE')
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- LIVE-02. النطاق ٩٤–١١٩ بالرقم وحده، مستقلاً عن fdts.zone اليدوي.
--
-- ٩٤ و١٢٠ مسجَّلان بمنطقة معاكِسة عمداً (٩٤ بـ'old'، ١٢٠ بـ'new') لإثبات أن
-- النطاق لا يقرأ العمود اليدوي. و٩٣ و١١٩ غير مسجَّلين إطلاقاً لإثبات أن
-- التسجيل لا يُشترط خارج المدى ولا داخله.
-- ---------------------------------------------------------------------------

insert into public.fdts (code, label, zone, agent_id) values
  ('94','B3-FDT-94','old', null),
  ('120','B3-FDT-120','new', null)
on conflict (code) do nothing;

insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, canceled, raw_parent, event_created_at, fdt_code)
values
  ('63000000-0000-0000-0000-0000000000c5','B3-EV-93','b3-sub-93','P-35000',false,'b3.new',
   timestamptz '2026-12-01 10:00+03','93'),
  ('63000000-0000-0000-0000-0000000000c5','B3-EV-94','b3-sub-94','P-35000',false,'b3.new',
   timestamptz '2026-12-01 10:00+03','94'),
  ('63000000-0000-0000-0000-0000000000c5','B3-EV-119','b3-sub-119','P-35000',false,'b3.new',
   timestamptz '2026-12-01 10:00+03','119'),
  ('63000000-0000-0000-0000-0000000000c5','B3-EV-120','b3-sub-120','P-35000',false,'b3.new',
   timestamptz '2026-12-01 10:00+03','120'),
  ('63000000-0000-0000-0000-0000000000c5','B3-EV-94-DC','b3-sub-94dc','P-35000',false,null,
   timestamptz '2026-12-01 10:00+03','94')
on conflict do nothing;

-- الشركة المباشرة: عائدية مؤرَّخة صريحة، لا اسم أب. صفر عمولة حتى داخل ٩٤–١١٩.
insert into public.subscriber_ownership
  (username_key, ownership_type, agent_id, effective_from, effective_to, reason, performed_by)
values
  ('b3-sub-94dc','FTTH_USER', null, timestamptz '2026-01-01 00:00+03', null,
   'اختبار B3', '63000000-0000-0000-0000-0000000000c1');

insert into public.commission_cycles (id, name, period_start, period_end, engine_version, created_by)
values ('63000000-0000-0000-0000-0000000000c6','B3 كانون', date '2026-12-01', date '2026-12-31',
        'VNEXT','63000000-0000-0000-0000-0000000000c1')
on conflict do nothing;

set local role authenticated;
set local request.jwt.claim.sub = '63000000-0000-0000-0000-0000000000c1';
select public.calculate_commission_cycle('63000000-0000-0000-0000-0000000000c6') is not null as ran;
reset role;

select pg_temp.ok(
  public.fdt_commission_scope('93') = 'AGENT'
  and public.fdt_commission_scope('94') = 'FDT'
  and public.fdt_commission_scope('119') = 'FDT'
  and public.fdt_commission_scope('120') = 'AGENT'
  and public.fdt_commission_scope(null) = 'AGENT'
  and public.fdt_commission_scope('ABC') = 'AGENT',
  'حدود ٩٣/٩٤/١١٩/١٢٠ ومدخل غير رقمي — الدالّة وحدها');

select pg_temp.ok(
  (select scope_type from public.commission_event_entitlements where activation_event_id = 'B3-EV-93') = 'AGENT'
  and (select scope_id from public.commission_event_entitlements where activation_event_id = 'B3-EV-93')
      = '63000000-0000-0000-0000-0000000000c3',
  'كابينة ٩٣ خارج المدى: نطاق وكيل، غير مسجَّلة ولم تُحجَب');

select pg_temp.ok(
  (select scope_type from public.commission_event_entitlements where activation_event_id = 'B3-EV-94') = 'FDT'
  and (select scope_id from public.commission_event_entitlements where activation_event_id = 'B3-EV-94') = '94',
  'كابينة ٩٤ داخل المدى: نطاق كابينة رغم fdts.zone=old اليدوي');

select pg_temp.ok(
  (select scope_type from public.commission_event_entitlements where activation_event_id = 'B3-EV-119') = 'FDT'
  and (select scope_id from public.commission_event_entitlements where activation_event_id = 'B3-EV-119') = '119',
  'كابينة ١١٩ داخل المدى: نطاق كابينة رغم عدم تسجيلها إطلاقاً');

select pg_temp.ok(
  not exists (
    select 1 from public.commission_exceptions
    where cycle_id = '63000000-0000-0000-0000-0000000000c6'
      and reason_code = 'UNKNOWN_FDT'
      and activation_event_id = 'B3-EV-119'),
  'كابينة ١١٩ غير المسجَّلة لا تُنتج استثناء UNKNOWN_FDT');

select pg_temp.ok(
  (select scope_type from public.commission_event_entitlements where activation_event_id = 'B3-EV-120') = 'AGENT'
  and (select scope_id from public.commission_event_entitlements where activation_event_id = 'B3-EV-120')
      = '63000000-0000-0000-0000-0000000000c3',
  'كابينة ١٢٠ خارج المدى: نطاق وكيل رغم fdts.zone=new اليدوي');

select pg_temp.ok(
  not exists (
    select 1 from public.commission_event_entitlements where activation_event_id = 'B3-EV-94-DC'),
  'شركة مباشرة داخل ٩٤–١١٩ = صفر عمولة وكيل');

select pg_temp.ok(
  (select fdt_zone from public.commission_qualifying_events where saas_event_id = 'B3-EV-94') = 'old',
  'fdt_zone الخام يبقى كما سُجِّل — بيانات تشغيلية منفصلة عن النطاق المحسوب');

-- ---------------------------------------------------------------------------
-- LIVE-01. العائدية عند لحظة الحدث، لا عند لحظة الحساب.
-- ---------------------------------------------------------------------------

insert into public.subscriber_ownership
  (username_key, ownership_type, agent_id, effective_from, effective_to, reason, performed_by)
values
  ('b3-hist-1','RESELLER','63000000-0000-0000-0000-0000000000c2',
   timestamptz '2026-01-01 00:00+03', timestamptz '2026-06-01 00:00+03',
   'اختبار B3', '63000000-0000-0000-0000-0000000000c1'),
  ('b3-hist-1','RESELLER','63000000-0000-0000-0000-0000000000c3',
   timestamptz '2026-06-01 00:00+03', null,
   'اختبار B3', '63000000-0000-0000-0000-0000000000c1');

insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, canceled, raw_parent, event_created_at, fdt_code)
values
  ('63000000-0000-0000-0000-0000000000c5','B3-EV-BEFORE','b3-hist-1','P-35000',false,'b3.hist',
   timestamptz '2026-03-01 10:00+03', null),
  ('63000000-0000-0000-0000-0000000000c5','B3-EV-AFTER','b3-hist-1','P-35000',false,'b3.hist',
   timestamptz '2026-07-01 10:00+03', null)
on conflict do nothing;

insert into public.commission_cycles (id, name, period_start, period_end, engine_version, created_by)
values ('63000000-0000-0000-0000-0000000000c7','B3 تاريخي', date '2026-01-01', date '2026-08-31',
        'VNEXT','63000000-0000-0000-0000-0000000000c1')
on conflict do nothing;

set local role authenticated;
set local request.jwt.claim.sub = '63000000-0000-0000-0000-0000000000c1';
select public.calculate_commission_cycle('63000000-0000-0000-0000-0000000000c7') is not null as ran;
reset role;

select pg_temp.ok(
  (select effective_agent_id from public.commission_event_entitlements
   where activation_event_id = 'B3-EV-BEFORE') = '63000000-0000-0000-0000-0000000000c2',
  'حدث قبل النقل يُنسَب للوكيل القديم');

select pg_temp.ok(
  (select effective_agent_id from public.commission_event_entitlements
   where activation_event_id = 'B3-EV-AFTER') = '63000000-0000-0000-0000-0000000000c3',
  'حدث بعد النقل يُنسَب للوكيل الجديد');

-- نقلٌ آخر اليوم (فترة ثالثة سارية من أيلول)، وتغييرٌ في "السيد الحالي" عبر
-- subscriber_identities مباشرةً — كلاهما يجب ألّا يُحرِّك ما سبق.
insert into public.subscriber_ownership
  (username_key, ownership_type, agent_id, effective_from, effective_to, reason, performed_by)
values
  ('b3-hist-1','RESELLER','63000000-0000-0000-0000-0000000000c4',
   timestamptz '2026-09-01 00:00+03', null,
   'نقل ثالث اليوم', '63000000-0000-0000-0000-0000000000c1');

insert into public.subscriber_identities
  (username, identity_status, match_method, source_classification, effective_agent_id)
values ('b3-hist-1','MATCHED','EXACT_USERNAME','RESELLER','63000000-0000-0000-0000-0000000000c4');

set local role authenticated;
set local request.jwt.claim.sub = '63000000-0000-0000-0000-0000000000c1';
select public.calculate_commission_cycle('63000000-0000-0000-0000-0000000000c7') is not null as recalculated;
reset role;

select pg_temp.ok(
  (select effective_agent_id from public.commission_event_entitlements
   where activation_event_id = 'B3-EV-BEFORE') = '63000000-0000-0000-0000-0000000000c2',
  'إعادة الحساب بعد نقل ثالث لا تُعيد كتابة حدث ما قبل الأول');

select pg_temp.ok(
  (select effective_agent_id from public.commission_event_entitlements
   where activation_event_id = 'B3-EV-AFTER') = '63000000-0000-0000-0000-0000000000c3',
  'وتغيير السيد الحالي (subscriber_identities) لا يمسّ حدثاً تحكمه فترة صريحة');

reset role;
rollback;
