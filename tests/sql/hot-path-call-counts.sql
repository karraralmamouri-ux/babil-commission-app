-- الدالّة العدديّة المُناداة لكل صفّ.
--
-- دالّتان كانتا تردّان 500 في الإنتاج: `installation_cycle_pipeline`
-- و`commission_finalization_blockers`. السبب ليس خطأً في المنطق بل مهلة:
-- دور `authenticated` عليه `statement_timeout = 8s`، وكلتاهما كانت تنادي
-- دالّةً عدديّة مرّةً لكل صفّ حتى تتجاوزه، فيُلغي Postgres الجملة بالرمز
-- 57014 ويردّ PostgREST بـ500.
--
-- ولا يُقاس هذا بالزمن: قاعدة الاختبار أصغر من الإنتاج بمراتب، فأيّ حدٍّ
-- زمنيّ هنا إمّا يمرّ دائماً أو يرتعش مع حِمل الآلة. فيُقاس بما يصف العلّة
-- وصفاً دقيقاً: **كم مرّةً نوديت الدالّة**.
--
-- تُستبدل الدالّة المُناداة بنسخةٍ تَعُدّ نداءاتها، ثم يُقارَن العدد بعدد
-- القيم المميّزة لا بعدد الصفوف. النسخة القديمة تسقط هنا حتماً، والجديدة
-- تمرّ، ولا علاقة للزمن بالحكم.
--
-- معزول بنطاق تسمية HP-.

\set ON_ERROR_STOP on
\pset tuples_only on

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns text language sql as $$
  select case when p_cond then '              ok ' || p_label else 'FAILED: ' || p_label end;
$$;

begin;

select '             == hot path call counts ==';

-- العدّاد إعدادُ جلسة لا جدول: الدالّتان المُختبَرتان `stable`، وأيّ إدخال
-- في شجرة ندائهما مرفوض. و`set_config` تغييرُ إعدادٍ لا تغييرُ بيانات.
select set_config('hp.rate_calls', '0', false);

insert into auth.users (id, email)
values ('ab000000-0000-0000-0000-0000000000a1'::uuid, 'hp-admin@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active)
values ('ab000000-0000-0000-0000-0000000000a1'::uuid,'HPA','hp-admin@fixture.invalid','admin',true)
on conflict (id) do update set role = 'admin', is_active = true;

-- ------------------------------------------------------------------
-- ١ · حواجب الاعتماد: السعر مرّةً لكل باقة لا لكل استثناء
-- ------------------------------------------------------------------

insert into public.commission_cycles
  (id, name, period_start, period_end, engine_version, created_by, status)
values ('ab000000-0000-0000-0000-0000000000a2'::uuid, 'HP دورة',
        date '2027-03-01', date '2027-03-31', 'VNEXT',
        'ab000000-0000-0000-0000-0000000000a1'::uuid, 'UNDER_REVIEW')
on conflict do nothing;

insert into public.saas_import_batches
  (id, source_kind, source_filename, source_checksum, parser_version, imported_by,
   completeness_status)
values ('ab000000-0000-0000-0000-0000000000a3'::uuid,'ACTIVATION_EVENTS','hp.xlsx',
        'hp-checksum','v1','ab000000-0000-0000-0000-0000000000a1'::uuid,'COMPLETE')
on conflict do nothing;

-- 300 حدثاً على ثلاث باقات مميّزة.
insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, canceled, raw_parent,
   event_created_at)
select 'ab000000-0000-0000-0000-0000000000a3'::uuid,
       'HP-EV-' || i,
       'hp-sub-' || i,
       'HP-PKG-' || (i % 3),
       false,
       'hp.parent',
       timestamptz '2027-03-05 00:00:00+03'
from generate_series(1, 300) i
on conflict do nothing;

insert into public.commission_exceptions
  (cycle_id, activation_event_id, subscriber_key, reason_code, detail, blocks_finalization)
select 'ab000000-0000-0000-0000-0000000000a2'::uuid,
       'HP-EV-' || i,
       'hp-sub-' || i,
       'UNKNOWN_FDT',
       'HP',
       true
from generate_series(1, 300) i
on conflict do nothing;

-- نسخةٌ تَعُدّ. القيمة لا تهمّ هنا — العدد وحده هو محلّ الحكم.
create or replace function public.commission_rate_for(
  p_version_id uuid, p_zone text, p_subscribers integer, p_package text)
returns bigint
language plpgsql
volatile
security definer
set search_path = ''
as $count$
begin
  perform pg_catalog.set_config('hp.rate_calls',
    ((pg_catalog.current_setting('hp.rate_calls', true))::int + 1)::text, false);
  return 1000;
end;
$count$;

set local role authenticated;
set local request.jwt.claim.sub = 'ab000000-0000-0000-0000-0000000000a1';

select count(*) from public.commission_finalization_blockers(
  'ab000000-0000-0000-0000-0000000000a2'::uuid);

reset role;

select pg_temp.ok(
  current_setting('hp.rate_calls', true)::int <= 4,
  'السعر يُحسب مرّةً لكل باقة مميّزة لا لكل استثناء (300 صفّاً · 3 باقات)');

select pg_temp.ok(
  current_setting('hp.rate_calls', true)::int < 300,
  'عدد النداءات أقلّ من عدد الصفوف بمراتب');

-- ------------------------------------------------------------------
-- ٢ · مرشّحو الصرف: لا نداء لدالّة العائدية أصلاً
-- ------------------------------------------------------------------

select set_config('hp.own_calls', '0', false);

-- 200 مشتركاً في حالةٍ تجعلهم مرشّحين فعلاً. بدون هذا لا يدخل أحدٌ في
-- ، فلا تُنادى دالّة العائدية أصلاً ويمرّ الاختبار وهو لا يفحص شيئاً.
insert into public.installation_subscribers (subscriber_id, reseller, created_by)
select 'hp-cand-' || i, 'HP وكيل', 'ab000000-0000-0000-0000-0000000000a1'::uuid
from generate_series(1, 200) i
on conflict do nothing;

insert into public.installation_subscriber_state
  (subscriber_uuid, as_of_date, remaining, received_total, total_amount,
   current_stage, resolution, payment_eligible)
select s.id, date '2027-03-31', 13000, 0, 13000,
       public.installation_stage_for_remaining(13000), 'resolved', true
from public.installation_subscribers s
where s.subscriber_id like 'hp-cand-%'
on conflict do nothing;

create or replace function public.subscriber_ownership_type(p_subscriber_id text)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $count$
begin
  perform pg_catalog.set_config('hp.own_calls',
    ((pg_catalog.current_setting('hp.own_calls', true))::int + 1)::text, false);
  return 'RESELLER';
end;
$count$;

set local role authenticated;
set local request.jwt.claim.sub = 'ab000000-0000-0000-0000-0000000000a1';

select pg_temp.ok(
  (public.installation_payout_candidates() ->> 'subscribers')::int >= 200,
  'المرشّحون دخلوا الحساب فعلاً (وإلا لم يُفحص شيء)');

reset role;

select pg_temp.ok(
  coalesce(current_setting('hp.own_calls', true)::int, 0) = 0,
  'العائدية تُقرأ من الصفّ الحاضر بلا نداءٍ لكل مشترك');

-- ------------------------------------------------------------------
-- ٣ · القاعدة لم تسقط مع النداء
-- ------------------------------------------------------------------
--
-- إزالة النداء لا يجوز أن تُزيل معه الحكم. وحكم العائدية نفسه مُختبَر
-- بفواتيره ومراحله في installation-payout.sql؛ ما يلزم هنا أن الشرط ما زال
-- مكتوباً في الدالّة ويقرأ الجدولين اللذين كان ينادي الدالّة ليقرأهما.

select pg_temp.ok(
  (select prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'installation_payout_candidates')
    like '%subscriber_ownership%',
  'الحجب بالعائدية ما زال يقرأ سجلّ العائدية');

select pg_temp.ok(
  (select prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'installation_payout_candidates')
    like '%subscriber_identities%',
  'وما زال يرجع إلى تصنيف المصدر عند غياب السجلّ');

select pg_temp.ok(
  (select prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'installation_payout_candidates')
    like '%<> ''RESELLER''%',
  'ومن ليس وكيلاً يبقى محجوباً');

rollback;
