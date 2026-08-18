-- الحراسة نفسها، مقيَّمةً مرة واحدة.
--
-- الخطر في تغييرٍ كهذا أن يُسرِّع بإضعاف. فالتوكيدات هنا أمنية أولاً: من لا
-- يملك القدرة لا يرى صفاً، ومن يملكها يرى. والسرعة تُتحقَّق بعد ذلك بفحص
-- شكل السياسة لا بقياس زمن (الزمن على قاعدة اختبار فارغة لا يُثبت شيئاً).
--
-- معزول بنطاق تسمية RC-.

\set ON_ERROR_STOP on
\pset tuples_only on

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns text language sql as $$
  select case when p_cond then '         ok ' || p_label else 'FAILED: ' || p_label end;
$$;

begin;

select '        == rls capability scope ==';

insert into auth.users (id, email) values
  ('4c000000-0000-0000-0000-0000000000d1', 'rc-admin@fixture.invalid'),
  ('4c000000-0000-0000-0000-0000000000d2', 'rc-viewer@fixture.invalid'),
  ('4c000000-0000-0000-0000-0000000000d3', 'rc-nobody@fixture.invalid')
on conflict do nothing;

insert into public.profiles (id, full_name, email, role, is_active) values
  ('4c000000-0000-0000-0000-0000000000d1','RCA','rc-admin@fixture.invalid','admin',true),
  ('4c000000-0000-0000-0000-0000000000d2','RCV','rc-viewer@fixture.invalid','viewer',true),
  ('4c000000-0000-0000-0000-0000000000d3','RCN','rc-nobody@fixture.invalid','viewer',false)
on conflict (id) do update set role = excluded.role, is_active = excluded.is_active;

insert into public.commission_cycles
  (id, name, period_start, period_end, engine_version, created_by)
values ('4c000000-0000-0000-0000-0000000000d4','RC دورة', date '2026-10-01', date '2026-10-31',
        'VNEXT','4c000000-0000-0000-0000-0000000000d1')
on conflict do nothing;

insert into public.commission_exceptions
  (cycle_id, activation_event_id, subscriber_key, reason_code, detail, blocks_finalization)
values ('4c000000-0000-0000-0000-0000000000d4','RC-EV-1','rc-sub-1','UNKNOWN_FDT','rc',true)
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- الحراسة قائمة
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claim.sub = '4c000000-0000-0000-0000-0000000000d1';
select pg_temp.ok(
  (select count(*) from public.commission_exceptions
   where cycle_id = '4c000000-0000-0000-0000-0000000000d4') = 1,
  'من يملك القدرة يرى الصف');
reset role;

set local role authenticated;
set local request.jwt.claim.sub = '4c000000-0000-0000-0000-0000000000d2';
select pg_temp.ok(
  (select count(*) from public.commission_exceptions
   where cycle_id = '4c000000-0000-0000-0000-0000000000d4') = 1,
  'المراقب يملك commission.view فيرى');
reset role;

-- المعطَّل: القدرة تسقط بسقوط الحساب، لا بالدور وحده.
set local role authenticated;
set local request.jwt.claim.sub = '4c000000-0000-0000-0000-0000000000d3';
select pg_temp.ok(
  (select count(*) from public.commission_exceptions
   where cycle_id = '4c000000-0000-0000-0000-0000000000d4') = 0,
  'الحساب المعطَّل لا يرى شيئاً');
select pg_temp.ok(
  (select count(*) from public.commission_event_entitlements) = 0,
  'المعطَّل لا يرى الاستحقاقات');
select pg_temp.ok(
  (select count(*) from public.commission_cycle_snapshots) = 0,
  'المعطَّل لا يرى اللقطات');
reset role;

-- بلا هوية إطلاقاً.
set local role authenticated;
select pg_temp.ok(
  (select count(*) from public.commission_exceptions) = 0,
  'بلا هوية لا يُرى شيء');
reset role;

-- ---------------------------------------------------------------------------
-- التقييم مرة واحدة — يُفحص شكل السياسة لا زمنها
--
-- الوسيط ثابت في كل سياسة، فالنتيجة واحدة لكل الصفوف. اللفّ في استعلام قياسي
-- هو ما يجعل المخطِّط يحسبها InitPlan بدل Filter لكل صف.
-- ---------------------------------------------------------------------------

select pg_temp.ok(
  (select count(*) from pg_policy pol
   where pg_get_expr(pol.polqual, pol.polrelid) like '%has_capability%'
     and pg_get_expr(pol.polqual, pol.polrelid) not like '%( SELECT%') = 0,
  'لا سياسة تستدعي has_capability لكل صف');

-- ولا تُمرَّر أعمدةُ الصف إلى النداء الملفوف: لو مُرِّرت لاختلفت النتيجة بين
-- الصفوف، وصار التقييم مرةً واحدة خطأً صامتاً — أخطر من البطء الذي عولج.
-- الفحص: كل وسيط في كل نداء لا بدّ أن يكون نصاً حرفياً.
select pg_temp.ok(
  (select count(*)
   from pg_policy pol
   cross join lateral regexp_matches(
     pg_get_expr(pol.polqual, pol.polrelid),
     'has_capability\(([^)]*)\)', 'g') as m(args)
   where m.args[1] !~ '^''[^'']*''(::text)?( *, *''[^'']*''(::text)?)*$') = 0,
  'كل وسيط في النداء الملفوف نصٌّ حرفي لا عمود');

rollback;
