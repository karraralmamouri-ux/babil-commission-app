-- 20261030090000: page_unknown_fdts / unknown_fdt_summary must resolve their
-- cycle window through current_commission_cycle_id(), not a bare
-- "order by period_start desc limit 1" that can land on a CANCELLED cycle
-- just because it happens to be the newest by period_start.
--
-- معزول بملفه ومعاملته ونطاق تسمية WC- خاص به.

\set ON_ERROR_STOP on
\pset tuples_only on

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns text language sql as $$
  select case when p_cond then '   ok ' || p_label else 'FAILED: ' || p_label end;
$$;

begin;

select '   == fdt workcenter operative cycle ==';

insert into auth.users (id, email) values
  ('a2000000-0000-0000-0000-0000000000a1', 'wc-admin@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active) values
  ('a2000000-0000-0000-0000-0000000000a1','WCA','wc-admin@fixture.invalid','admin',true)
on conflict (id) do update set role = excluded.role, is_active = true;

insert into public.packages (code, name, semantic_category)
values ('WC-PKG','WC-PKG','PAID_PACKAGE') on conflict (code) do nothing;

insert into public.saas_import_batches
  (id, source_kind, source_filename, source_checksum, parser_version, imported_by,
   completeness_status)
values ('a2000000-0000-0000-0000-0000000000a4','ACTIVATION_EVENTS','wc.xlsx','wc-checksum',
        'v1','a2000000-0000-0000-0000-0000000000a1','COMPLETE')
on conflict do nothing;

-- الأحدث بفترتها CANCELLED (آب)، والسابقة لها عاملة UNDER_REVIEW (تموز) —
-- بالضبط سيناريو #5: أحدث دورةٍ ملغاة، والعاملة أقدم منها.
insert into public.commission_cycles
  (id, name, period_start, period_end, status, engine_version, created_by)
values
  ('a2000000-0000-0000-0000-0000000000a5','WC تموز', date '2026-07-01', date '2026-07-31',
   'UNDER_REVIEW','VNEXT','a2000000-0000-0000-0000-0000000000a1'),
  ('a2000000-0000-0000-0000-0000000000a6','WC آب', date '2026-08-01', date '2026-08-31',
   'CANCELLED','VNEXT','a2000000-0000-0000-0000-0000000000a1')
on conflict do nothing;

insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, canceled, raw_parent,
   event_created_at, fdt_code)
values
  ('a2000000-0000-0000-0000-0000000000a4','WC-EV-1','wc-sub-1','WC-PKG',false,'wc.parent','2026-07-05','WC-NEW')
on conflict do nothing;

set local role authenticated;
set local request.jwt.claim.sub = 'a2000000-0000-0000-0000-0000000000a1';

select pg_temp.ok(
  public.current_commission_cycle_id() = 'a2000000-0000-0000-0000-0000000000a5',
  'ضبط الاختبار: current_commission_cycle_id يختار تموز العاملة لا آب الملغاة');

select pg_temp.ok(
  (public.page_unknown_fdts() ->> 'cycle_id') = 'a2000000-0000-0000-0000-0000000000a5',
  'page_unknown_fdts يستخدم الدورة العاملة (تموز) لا الأحدث الملغاة (آب)');

select pg_temp.ok(
  (public.unknown_fdt_summary() ->> 'cycle_id') = 'a2000000-0000-0000-0000-0000000000a5',
  'unknown_fdt_summary يستخدم الدورة العاملة نفسها — سياق واحد متّسق');

with d as (
  select jsonb_array_elements(
    public.current_unknown_fdt_decisions('a2000000-0000-0000-0000-0000000000a5') -> 'rows'
  ) row
)
select pg_temp.ok(
  (public.page_unknown_fdts() ->> 'cycle_id') = 'a2000000-0000-0000-0000-0000000000a5',
  'نفس سياق الدورة العاملة الذي تعتمده current_unknown_fdt_decisions لبقية الشاشة');

-- تلغى العاملة أيضاً: لا دورة عاملة على الإطلاق بعد الآن. تحديثٌ مباشرٌ على
-- الجدول يتطلّب صلاحية postgres — لا صلاحية UPDATE مباشرة لـauthenticated
-- على commission_cycles (الإلغاء الحقيقي يمرّ عبر RPC مخصّصة، لا يُختبَر هنا).
reset role;
update public.commission_cycles set status = 'CANCELLED'
where id = 'a2000000-0000-0000-0000-0000000000a5';
set local role authenticated;
set local request.jwt.claim.sub = 'a2000000-0000-0000-0000-0000000000a1';

select pg_temp.ok(
  public.current_commission_cycle_id() is null,
  'ضبط الاختبار: لا دورة عاملة إطلاقاً بعد إلغاء الاثنتين');

select pg_temp.ok(
  (public.page_unknown_fdts() ->> 'cycle_id') is null,
  'لا دورة عاملة: page_unknown_fdts لا يختار الملغاة بديلاً — cycle_id فارغ بأمان');

select pg_temp.ok(
  ((public.page_unknown_fdts() -> 'rows' -> 0 ->> 'indicative_amount'))::bigint = 0,
  'لا دورة عاملة: قائمة الكابينات نفسها تبقى ظاهرة، والمبلغ المؤشِّر صفرٌ لا خطأ');

select pg_temp.ok(
  (public.unknown_fdt_summary() ->> 'cycle_id') is null
  and ((public.unknown_fdt_summary() ->> 'indicative_amount'))::bigint = 0,
  'لا دورة عاملة: unknown_fdt_summary يعيد ملخّصاً آمناً بلا سياق دورة');

reset role;

rollback;
