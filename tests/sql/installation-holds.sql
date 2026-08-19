-- تعليق أجور التنصيب: دائم ومؤقّت، فردي وبالجملة.
--
-- الخطر هنا في اتجاهين: تعليقٌ لا يحجب فيُصرف ما كان يجب حجبه، وتعليقٌ
-- يحجب بعد انقضاء أجله فيُحتجَز مالٌ بلا سبب. والثالث أخطر: تعليقٌ يمسّ
-- التاريخ المدفوع.
--
-- معزول بنطاق تسمية HB-.

\set ON_ERROR_STOP on
\pset tuples_only on

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns text language sql as $$
  select case when p_cond then '            ok ' || p_label else 'FAILED: ' || p_label end;
$$;

create or replace function pg_temp.must_fail(p_sql text, p_label text)
returns text language plpgsql as $$
begin
  execute p_sql;
  return 'FAILED: ' || p_label || ' — مرّ وكان يجب أن يُرفض';
exception when others then return '            ok ' || p_label;
end;
$$;

begin;

select '           == installation holds ==';

insert into auth.users (id, email) values ('80000000-0000-0000-0000-0000000000a1','hb@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active)
values ('80000000-0000-0000-0000-0000000000a1','HB','hb@fixture.invalid','admin',true)
on conflict (id) do update set role='admin', is_active=true;

-- أربعة مشتركين: اثنان بمتبقٍّ، وواحد منتهٍ، وواحد سيُعلَّق سلفاً.
insert into public.installation_subscribers
  (id, subscriber_id, reseller, fdt, start_date, total_amount, created_by)
values
  ('80000000-0000-0000-0000-0000000000b1','hb-sub-1','وكيل الحجب','HB-FDT', date '2026-01-01', 13000,'80000000-0000-0000-0000-0000000000a1'),
  ('80000000-0000-0000-0000-0000000000b2','hb-sub-2','وكيل الحجب','HB-FDT', date '2026-01-01', 13000,'80000000-0000-0000-0000-0000000000a1'),
  ('80000000-0000-0000-0000-0000000000b3','hb-done','وكيل الحجب','HB-FDT', date '2026-01-01', 13000,'80000000-0000-0000-0000-0000000000a1'),
  ('80000000-0000-0000-0000-0000000000b4','hb-held','وكيل الحجب','HB-FDT', date '2026-01-01', 13000,'80000000-0000-0000-0000-0000000000a1'),
  ('80000000-0000-0000-0000-0000000000b5','hb-open','وكيل الحجب','HB-FDT', date '2026-01-01', 13000,'80000000-0000-0000-0000-0000000000a1')
on conflict do nothing;

insert into public.installation_subscriber_state
  (subscriber_uuid, as_of_date, remaining, current_stage, resolution, payment_eligible)
values
  ('80000000-0000-0000-0000-0000000000b1', date '2026-06-30', 13000, 'P1', 'resolved', true),
  ('80000000-0000-0000-0000-0000000000b2', date '2026-06-30', 10000, 'P2', 'resolved', true),
  ('80000000-0000-0000-0000-0000000000b3', date '2026-06-30', 0, 'DONE', 'resolved', false),
  ('80000000-0000-0000-0000-0000000000b4', date '2026-06-30', 13000, 'P1', 'resolved', true),
  ('80000000-0000-0000-0000-0000000000b5', date '2026-06-30', 13000, 'P1', 'resolved', true)
on conflict (subscriber_uuid) do update
  set remaining = excluded.remaining, current_stage = excluded.current_stage,
      resolution = excluded.resolution,
      payment_eligible = excluded.payment_eligible;

-- تعليقٌ قائم على الرابع.
insert into public.installation_holds
  (subscriber_id, reason_code, hold_type, note, status, created_by,
   permanence, source, reason_note)
values ('hb-held','MANUAL_REVIEW','MANUAL','قائم','ACTIVE',
        '80000000-0000-0000-0000-0000000000a1','PERMANENT','INDIVIDUAL','قائم')
on conflict do nothing;

set local role authenticated;
set local request.jwt.claim.sub = '80000000-0000-0000-0000-0000000000a1';

-- ---------------------------------------------------------------------------
-- 1. المعاينة تفرز قبل أن يُطبَّق شيء
-- ---------------------------------------------------------------------------

select pg_temp.ok(
  (public.preview_bulk_hold(array['hb-sub-1','hb-sub-2','hb-done','hb-held','hb-ghost','hb-sub-1'])
   -> 'counts' ->> 'valid')::int = 2,
  'المعاينة تعدّ الصالحين');

select pg_temp.ok(
  (public.preview_bulk_hold(array['hb-sub-1','hb-ghost']) -> 'counts' ->> 'unknown')::int = 1,
  'والمجهول يُفرَز وحده');

select pg_temp.ok(
  (public.preview_bulk_hold(array['hb-sub-1','hb-held']) -> 'counts' ->> 'already_held')::int = 1,
  'والمعلَّق سلفاً لا يُعلَّق مرّتين');

select pg_temp.ok(
  (public.preview_bulk_hold(array['hb-done']) -> 'counts' ->> 'already_done')::int = 1,
  'والمنتهي لا معنى لتعليقه');

select pg_temp.ok(
  (public.preview_bulk_hold(array['hb-sub-1','hb-sub-1','hb-sub-1']) ->> 'duplicate')::int = 2,
  'والتكرار داخل الملف يُعدّ');

select pg_temp.ok(
  (public.preview_bulk_hold(array['hb-sub-1','hb-sub-1']) ->> 'distinct_ids')::int = 1,
  'ويُطبَّق مرّةً واحدة');

-- المعاينة قراءةٌ محضة: لا تُنشئ تعليقاً.
select pg_temp.ok(
  (select count(*) from public.installation_holds where subscriber_id = 'hb-sub-1') = 0,
  'المعاينة لا تُعلّق شيئاً');

-- ---------------------------------------------------------------------------
-- 2. شروط القرار
-- ---------------------------------------------------------------------------

-- المؤقّت بلا أجل مقبول: يبقى حتى يُرفع يدوياً. وهذه هي الحالة الأكثر
-- وقوعاً — «علِّقه حتى نتحقّق» بلا تاريخٍ معروف سلفاً.
select pg_temp.ok(
  (public.apply_bulk_hold(array['hb-open'], 'TEMPORARY', 'MANUAL_REVIEW',
     'حتى التحقّق', 'open.xlsx', null, '80000000-0000-0000-0000-00000000ab20')
   ->> 'applied')::int = 1,
  'المؤقّت بلا أجل مقبول ويُطبَّق');

select pg_temp.ok(
  (select expires_at is null and permanence = 'TEMPORARY'
   from public.installation_holds where subscriber_id = 'hb-open') ,
  'ويُحفظ مؤقّتاً بلا أجل');

-- ويبقى سارياً: غياب الأجل ليس انقضاءً.
select pg_temp.ok(
  public.hold_is_effective('ACTIVE', 'TEMPORARY', null),
  'والمؤقّت بلا أجل يحجب حتى يُرفع');

-- والأجل في الماضي مرفوض في الحالين.
select pg_temp.must_fail(
  'select public.apply_bulk_hold(array[''hb-sub-1''], ''TEMPORARY'', ''MANUAL_REVIEW'',
     ''سبب'', ''f.xlsx'', now() - interval ''1 day'', gen_random_uuid())',
  'أجل في الماضي مرفوض');

select pg_temp.must_fail(
  'select public.apply_bulk_hold(array[''hb-sub-1''], ''PERMANENT'', ''MANUAL_REVIEW'',
     ''سبب'', ''f.xlsx'', now() + interval ''1 day'', gen_random_uuid())',
  'دائم بأجل مرفوض');


select pg_temp.must_fail(
  'select public.apply_bulk_hold(array[''hb-sub-1''], ''PERMANENT'', ''MANUAL_REVIEW'',
     ''  '', ''f.xlsx'', null, gen_random_uuid())',
  'تعليق بلا سبب مرفوض');

select pg_temp.must_fail(
  'select public.apply_bulk_hold(array[''hb-sub-1''], ''PERMANENT'', ''MANUAL_REVIEW'',
     ''سبب'', ''  '', null, gen_random_uuid())',
  'تعليق بلا اسم ملف مرفوض');

select pg_temp.must_fail(
  'select public.apply_bulk_hold(array[''hb-sub-1''], ''PERMANENT'', ''MANUAL_REVIEW'',
     ''سبب'', ''f.xlsx'', null, null)',
  'تعليق بلا معرّف طلب مرفوض');

-- ---------------------------------------------------------------------------
-- 3. التطبيق — ما يستحق التعليق وحده
-- ---------------------------------------------------------------------------

select public.apply_bulk_hold(
  array['hb-sub-1','hb-sub-2','hb-done','hb-held','hb-ghost'],
  'PERMANENT', 'MANUAL_REVIEW', 'مراجعة إدارية', 'july-holds.xlsx', null,
  '80000000-0000-0000-0000-00000000ab01');

select pg_temp.ok(
  (select count(*) from public.installation_holds h
   join public.installation_hold_uploads u on u.id = h.upload_id
   where u.request_id = '80000000-0000-0000-0000-00000000ab01'
     and h.status = 'ACTIVE') = 2,
  'يُعلَّق الصالحان فقط');

select pg_temp.ok(
  (select count(*) from public.installation_holds where subscriber_id = 'hb-done') = 0,
  'ولا يُعلَّق المنتهي');

select pg_temp.ok(
  (select count(*) from public.installation_holds where subscriber_id = 'hb-held') = 1,
  'ولا يُضاعَف المعلَّق سلفاً');

select pg_temp.ok(
  (select filename from public.installation_hold_uploads
   where request_id = '80000000-0000-0000-0000-00000000ab01') = 'july-holds.xlsx',
  'واسم الملف يبقى معروفاً بعد التطبيق');

select pg_temp.ok(
  (select applied_count from public.installation_hold_uploads
   where request_id = '80000000-0000-0000-0000-00000000ab01') = 2,
  'والرفعة تعرف كم طبّقت');

-- إعادة الرفع نفسه لا تُعلّق مرّةً ثانية.
select pg_temp.ok(
  (public.apply_bulk_hold(array['hb-sub-1','hb-sub-2'], 'PERMANENT', 'MANUAL_REVIEW',
     'مراجعة إدارية', 'july-holds.xlsx', null,
     '80000000-0000-0000-0000-00000000ab01') ->> 'idempotent')::boolean = true,
  'إعادة الرفع نفسه بلا أثر ثانٍ');

select pg_temp.ok(
  (select count(*) from public.installation_holds h
   join public.installation_hold_uploads u on u.id = h.upload_id
   where u.request_id = '80000000-0000-0000-0000-00000000ab01') = 2,
  'وعدد التعليقات يبقى كما هو');

-- والأثر مُدقَّق.
select pg_temp.ok(
  exists (select 1 from public.audit_logs
          where action = 'installation.hold.bulk_applied'
            and request_id = '80000000-0000-0000-0000-00000000ab01'
            and extra like '%july-holds.xlsx%'),
  'الرفعة مُسجَّلة في التدقيق باسم ملفها');

-- ---------------------------------------------------------------------------
-- 4. المؤقّت ينقضي بنفسه
-- ---------------------------------------------------------------------------

select pg_temp.ok(
  public.hold_is_effective('ACTIVE', 'TEMPORARY', now() + interval '1 day'),
  'المؤقّت قبل أجله يحجب');

select pg_temp.ok(
  not public.hold_is_effective('ACTIVE', 'TEMPORARY', now() - interval '1 second'),
  'وبعد أجله يتوقّف عن الحجب بلا تدخّل');

select pg_temp.ok(
  public.hold_is_effective('ACTIVE', 'PERMANENT', null),
  'والدائم يحجب بلا أجل');

select pg_temp.ok(
  not public.hold_is_effective('RELEASED', 'PERMANENT', null),
  'والمرفوع لا يحجب');

-- والأهلية تقرأ السريان لا الحالة وحدها.
reset role;
insert into public.installation_holds
  (subscriber_id, reason_code, hold_type, note, status, created_by,
   permanence, expires_at, source, reason_note)
values ('hb-expired','MANUAL_REVIEW','MANUAL','منتهٍ','ACTIVE',
        '80000000-0000-0000-0000-0000000000a1','TEMPORARY',
        now() - interval '1 hour','INDIVIDUAL','منتهٍ')
on conflict do nothing;
set local role authenticated;
set local request.jwt.claim.sub = '80000000-0000-0000-0000-0000000000a1';

select pg_temp.ok(
  (select count(*) from public.installation_holds h
   where h.subscriber_id = 'hb-expired'
     and public.hold_is_effective(h.status, h.permanence, h.expires_at)) = 0,
  'التعليق المنتهي لا يُعدّ سارياً وإن بقيت حالته ACTIVE');

-- ---------------------------------------------------------------------------
-- 5. الرفع قرارٌ يحتاج إذناً، ويُدقَّق
-- ---------------------------------------------------------------------------

select pg_temp.ok(
  (public.release_hold_v2(
     (select id from public.installation_holds where subscriber_id = 'hb-sub-1' limit 1),
     'انتهت المراجعة', '80000000-0000-0000-0000-00000000ab02') ->> 'idempotent')::boolean = false,
  'الرفع يقع');

select pg_temp.ok(
  (select status from public.installation_holds where subscriber_id = 'hb-sub-1') = 'RELEASED',
  'والحالة تصير مرفوعة');

select pg_temp.ok(
  (select btrim(coalesce(release_reason,'')) from public.installation_holds
   where subscriber_id = 'hb-sub-1') = 'انتهت المراجعة',
  'وسبب الرفع محفوظ');

select pg_temp.must_fail(
  'select public.release_hold_v2(
     (select id from public.installation_holds where subscriber_id = ''hb-sub-2'' limit 1),
     ''  '', gen_random_uuid())',
  'رفع بلا سبب مرفوض');

-- ---------------------------------------------------------------------------
-- 6. التعليق لا يمسّ التاريخ — الحدّ الذي لا يُتجاوز
-- ---------------------------------------------------------------------------

reset role;
insert into public.installation_payment_history
  (subscriber_uuid, stage, amount, payment_date, created_by)
values ('80000000-0000-0000-0000-0000000000b2','P1', 3000, date '2026-05-10',
        '80000000-0000-0000-0000-0000000000a1')
on conflict do nothing;
set local role authenticated;
set local request.jwt.claim.sub = '80000000-0000-0000-0000-0000000000a1';

select public.apply_bulk_hold(
  array['hb-sub-2'], 'TEMPORARY', 'MANUAL_REVIEW', 'مراجعة ثانية',
  'second.xlsx', now() + interval '30 days', '80000000-0000-0000-0000-00000000ab03');

select pg_temp.ok(
  (select count(*) from public.installation_payment_history
   where subscriber_uuid = '80000000-0000-0000-0000-0000000000b2') = 1,
  'الدفعة التاريخية باقية بعد التعليق');

select pg_temp.ok(
  (select sum(amount) from public.installation_payment_history
   where subscriber_uuid = '80000000-0000-0000-0000-0000000000b2') = 3000,
  'ومبلغها لم يتغيّر');

select pg_temp.ok(
  (select remaining from public.installation_subscriber_state
   where subscriber_uuid = '80000000-0000-0000-0000-0000000000b2') = 10000,
  'والمتبقّي التاريخي لم يُعد كتابته');

-- ---------------------------------------------------------------------------
-- 6.5 التعليق الفردي — الطريق الثاني، بالقواعد نفسها
-- ---------------------------------------------------------------------------

select pg_temp.ok(
  (public.place_hold_v2('hb-sub-1', 'TEMPORARY', 'MANUAL_REVIEW', 'مراجعة فردية',
     null, now() + interval '10 days', '80000000-0000-0000-0000-00000000ab10')
   ->> 'idempotent')::boolean = false,
  'التعليق الفردي يقع');

select pg_temp.ok(
  (select source from public.installation_holds
   where request_id = '80000000-0000-0000-0000-00000000ab10') = 'INDIVIDUAL',
  'ومصدره فردي لا ملف');

select pg_temp.ok(
  (select permanence from public.installation_holds
   where request_id = '80000000-0000-0000-0000-00000000ab10') = 'TEMPORARY'
  and (select expires_at is not null from public.installation_holds
       where request_id = '80000000-0000-0000-0000-00000000ab10'),
  'وأجله محفوظ');

-- إعادة الطلب نفسه لا تُعلّق مرّتين.
select pg_temp.ok(
  (public.place_hold_v2('hb-sub-1', 'TEMPORARY', 'MANUAL_REVIEW', 'مراجعة فردية',
     null, now() + interval '10 days', '80000000-0000-0000-0000-00000000ab10')
   ->> 'idempotent')::boolean = true,
  'وإعادة الطلب نفسه بلا أثر ثانٍ');

-- والمشترك المجهول يُرفض بدل أن يُنشأ له صفّ.
select pg_temp.must_fail(
  'select public.place_hold_v2(''hb-ghost'', ''PERMANENT'', ''MANUAL_REVIEW'',
     ''سبب'', null, null, gen_random_uuid())',
  'تعليق مشترك غير معروف مرفوض');

select pg_temp.ok(
  (public.place_hold_v2('hb-done', 'TEMPORARY', 'MANUAL_REVIEW',
     'حتى التحقّق', null, null, '80000000-0000-0000-0000-00000000ab21')
   ->> 'idempotent')::boolean = false,
  'الفردي المؤقّت بلا أجل مقبول');

-- والدائم بأجل مرفوض في الحالين.
select pg_temp.must_fail(
  'select public.place_hold_v2(''hb-sub-1'', ''PERMANENT'', ''MANUAL_REVIEW'',
     ''سبب'', null, now() + interval ''1 day'', gen_random_uuid())',
  'الفردي الدائم بأجل مرفوض');

-- ---------------------------------------------------------------------------
-- 7. الحارس
-- ---------------------------------------------------------------------------

reset role;
insert into auth.users (id, email) values ('80000000-0000-0000-0000-0000000000a9','hb-weak@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active)
values ('80000000-0000-0000-0000-0000000000a9','HB ضعيف','hb-weak@fixture.invalid','viewer',true)
on conflict (id) do update set role='viewer', is_active=true;

select pg_temp.must_fail(
  'set local role authenticated;
   set local request.jwt.claim.sub = ''80000000-0000-0000-0000-0000000000a9'';
   select public.apply_bulk_hold(array[''hb-sub-1''], ''PERMANENT'', ''MANUAL_REVIEW'',
     ''بلا صلاحية'', ''x.xlsx'', null, gen_random_uuid())',
  'التعليق بالجملة يرفض من لا يملك installation.hold');

select pg_temp.must_fail(
  'set local role authenticated;
   set local request.jwt.claim.sub = ''80000000-0000-0000-0000-0000000000a9'';
   select public.release_hold_v2(
     (select id from public.installation_holds limit 1), ''بلا صلاحية'', gen_random_uuid())',
  'الرفع يرفض من لا يملك installation.release_hold');

rollback;
