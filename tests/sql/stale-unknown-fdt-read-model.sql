-- 20261029090000: current_unknown_fdt_decisions/_events must exclude stale
-- OPEN UNKNOWN_FDT exceptions once fdt_commission_scope() can classify the
-- code deterministically — proven directly against the Production shape
-- (27/61/87 = OLD, 94/95/119 = NEW, all frozen VNEXT-era rows). Only rows
-- with no code at all must still surface as genuinely unknown work.
--
-- معزول بملفه ومعاملته ونطاق تسمية SF- خاص به.

\set ON_ERROR_STOP on
\pset tuples_only on

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns text language sql as $$
  select case when p_cond then '  ok ' || p_label else 'FAILED: ' || p_label end;
$$;

begin;

select '  == stale unknown_fdt read model ==';

insert into auth.users (id, email) values
  ('a1000000-0000-0000-0000-0000000000a1', 'sf-admin@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active) values
  ('a1000000-0000-0000-0000-0000000000a1','SFA','sf-admin@fixture.invalid','admin',true)
on conflict (id) do update set role = excluded.role, is_active = true;

insert into public.packages (code, name, semantic_category)
values ('SF-PKG','SF-PKG','PAID_PACKAGE') on conflict (code) do nothing;

insert into public.saas_import_batches
  (id, source_kind, source_filename, source_checksum, parser_version, imported_by,
   completeness_status)
values ('a1000000-0000-0000-0000-0000000000a4','ACTIVATION_EVENTS','sf.xlsx','sf-checksum',
        'v1','a1000000-0000-0000-0000-0000000000a1','COMPLETE')
on conflict do nothing;

-- دورة UNDER_REVIEW عاملة — تحاكي تموز 2026 في الإنتاج (VNEXT، لا ملغاة، لا
-- مسوّدة بلا حساب)، فتُرشَّح current_commission_cycle_id() تلقائياً.
insert into public.commission_cycles
  (id, name, period_start, period_end, status, engine_version, created_by)
values ('a1000000-0000-0000-0000-0000000000a5','SF تموز', date '2026-07-01', date '2026-07-31',
        'UNDER_REVIEW','VNEXT','a1000000-0000-0000-0000-0000000000a1')
on conflict do nothing;

-- ستّة أحداثٍ برموزَ قابلة للحسم اليوم (٣ OLD خارج ٩٤-١١٩، ٣ NEW داخلها)،
-- حدثٌ سابعٌ بلا رمزٍ إطلاقاً، وثامنٌ برمزٍ غير رقميٍّ (ليس معرِّف كابينةٍ
-- حقيقياً — fdt_commission_scope() تردّه AGENT افتراضياً فقط، لا حسماً) —
-- هذان الأخيران وحدهما يبقيان «مجهولَين» فعلاً.
insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, canceled, raw_parent,
   event_created_at, fdt_code)
values
  ('a1000000-0000-0000-0000-0000000000a4','SF-EV-27','sf-sub-27','SF-PKG',false,'sf.parent','2026-07-05','27'),
  ('a1000000-0000-0000-0000-0000000000a4','SF-EV-61','sf-sub-61','SF-PKG',false,'sf.parent','2026-07-06','61'),
  ('a1000000-0000-0000-0000-0000000000a4','SF-EV-87','sf-sub-87','SF-PKG',false,'sf.parent','2026-07-07','87'),
  ('a1000000-0000-0000-0000-0000000000a4','SF-EV-94','sf-sub-94','SF-PKG',false,'sf.parent','2026-07-08','94'),
  ('a1000000-0000-0000-0000-0000000000a4','SF-EV-95','sf-sub-95','SF-PKG',false,'sf.parent','2026-07-09','95'),
  ('a1000000-0000-0000-0000-0000000000a4','SF-EV-119','sf-sub-119','SF-PKG',false,'sf.parent','2026-07-10','119'),
  ('a1000000-0000-0000-0000-0000000000a4','SF-EV-NULL','sf-sub-null','SF-PKG',false,'sf.parent','2026-07-11',null),
  ('a1000000-0000-0000-0000-0000000000a4','SF-EV-JUNK','sf-sub-junk','SF-PKG',false,'sf.parent','2026-07-12','SF-JUNK')
on conflict do nothing;

-- استثناءات UNKNOWN_FDT مفتوحة مجمَّدة من محرّكٍ قديم — بالضبط شكل صفوف
-- الإنتاج: لا يُنتجها المحرّك الحالي (LIVE-02)، فتُدرَج يدوياً هنا لتحاكي
-- ركودها. لا calculate_commission_cycle هنا: هذا اختبار قراءةٍ فقط.
insert into public.commission_exceptions
  (cycle_id, activation_event_id, subscriber_key, reason_code, status)
values
  ('a1000000-0000-0000-0000-0000000000a5','SF-EV-27','sf-sub-27','UNKNOWN_FDT','OPEN'),
  ('a1000000-0000-0000-0000-0000000000a5','SF-EV-61','sf-sub-61','UNKNOWN_FDT','OPEN'),
  ('a1000000-0000-0000-0000-0000000000a5','SF-EV-87','sf-sub-87','UNKNOWN_FDT','OPEN'),
  ('a1000000-0000-0000-0000-0000000000a5','SF-EV-94','sf-sub-94','UNKNOWN_FDT','OPEN'),
  ('a1000000-0000-0000-0000-0000000000a5','SF-EV-95','sf-sub-95','UNKNOWN_FDT','OPEN'),
  ('a1000000-0000-0000-0000-0000000000a5','SF-EV-119','sf-sub-119','UNKNOWN_FDT','OPEN'),
  ('a1000000-0000-0000-0000-0000000000a5','SF-EV-NULL','sf-sub-null','UNKNOWN_FDT','OPEN'),
  ('a1000000-0000-0000-0000-0000000000a5','SF-EV-JUNK','sf-sub-junk','UNKNOWN_FDT','OPEN');

set local role authenticated;
set local request.jwt.claim.sub = 'a1000000-0000-0000-0000-0000000000a1';

select pg_temp.ok(
  (select public.current_unknown_fdt_decisions('a1000000-0000-0000-0000-0000000000a5')) is not null,
  'الاستدعاء ينجح');

with d as (
  select jsonb_array_elements(
    public.current_unknown_fdt_decisions('a1000000-0000-0000-0000-0000000000a5', null, 50, 0) -> 'rows'
  ) row
)
select pg_temp.ok(
  not exists (select 1 from d where row ->> 'fdt_code' in ('27','61','87')),
  '27/61/87 (OLD محسومة) مستبعدة من طابور القرار — راجحة، لا مجهولة');

with d as (
  select jsonb_array_elements(
    public.current_unknown_fdt_decisions('a1000000-0000-0000-0000-0000000000a5', null, 50, 0) -> 'rows'
  ) row
)
select pg_temp.ok(
  not exists (select 1 from d where row ->> 'fdt_code' in ('94','95','119')),
  '94/95/119 (NEW محسومة) مستبعدة رغم وجود صفٍّ قديمٍ مفتوح لها');

with d as (
  select jsonb_array_elements(
    public.current_unknown_fdt_decisions('a1000000-0000-0000-0000-0000000000a5', null, 50, 0) -> 'rows'
  ) row
)
select pg_temp.ok(
  (select count(*) from d) = 2
  and exists (select 1 from d where row ->> 'fdt_code' = '(بلا رمز)' and (row ->> 'events')::int = 1)
  and exists (select 1 from d where row ->> 'fdt_code' = 'SF-JUNK' and (row ->> 'events')::int = 1),
  'الصفّان المتبقيان فقط: بلا رمزٍ، ورمزٌ غير رقميٍّ (SF-JUNK) — لا شيء رقميٌّ محسومٌ يُصنَّف عشوائياً');

select pg_temp.ok(
  ((public.current_unknown_fdt_events('27', 'a1000000-0000-0000-0000-0000000000a5')) ->> 'total')::int = 0,
  'تصفّح مباشر لرابط ٢٧ القديم يعيد صفحةً فارغة، لا بيانات دورةٍ متجاوَزة');

select pg_temp.ok(
  ((public.current_unknown_fdt_events('(بلا رمز)', 'a1000000-0000-0000-0000-0000000000a5')) ->> 'total')::int = 1,
  'الحدث بلا رمزٍ يبقى مرئياً عبر current_unknown_fdt_events');

select pg_temp.ok(
  ((public.current_unknown_fdt_events('SF-JUNK', 'a1000000-0000-0000-0000-0000000000a5')) ->> 'total')::int = 1,
  'رمزٌ غير رقميٍّ (SF-JUNK) يبقى مرئياً — fdt_commission_scope() لا تحسمه فعلياً');

reset role;

rollback;
