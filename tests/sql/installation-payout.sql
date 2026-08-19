-- صرف أجور التنصيب: الدفعة، وإعادة التحقّق، والتأكيد.
--
-- كل ما هنا داخل معاملةٍ تُلغى في نهايتها. لا دفعة حقيقية تُنفَّذ، ولا دورة
-- تُعتمد. المسارات المُتلِفة تُختبَر بالتراجع لا بالأثر.
--
-- الخطر المحروس: إنشاء الدفعة يُقرأ دفعاً، وسطرٌ عُلّق بعد إدراجه يمرّ لأنه
-- كان مؤهَّلاً ساعةَ الإدراج، ومرحلةٌ تُدفع مرّتين.
--
-- معزول بنطاق تسمية PB-.

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

select '           == installation payout ==';

insert into auth.users (id, email) values ('90000000-0000-0000-0000-0000000000a1','pb@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active)
values ('90000000-0000-0000-0000-0000000000a1','PB','pb@fixture.invalid','admin',true)
on conflict (id) do update set role='admin', is_active=true;

-- ثلاثة مشتركين عند وكيلٍ واحد، بمراحل مختلفة.
insert into public.installation_subscribers
  (id, subscriber_id, reseller, fdt, start_date, total_amount, created_by)
values
  ('90000000-0000-0000-0000-0000000000b1','pb-1','وكيل الصرف','PB-FDT', date '2026-01-01', 13000,'90000000-0000-0000-0000-0000000000a1'),
  ('90000000-0000-0000-0000-0000000000b2','pb-2','وكيل الصرف','PB-FDT', date '2026-01-01', 13000,'90000000-0000-0000-0000-0000000000a1'),
  ('90000000-0000-0000-0000-0000000000b3','pb-3','وكيل الصرف','PB-FDT', date '2026-01-01', 13000,'90000000-0000-0000-0000-0000000000a1')
on conflict do nothing;

insert into public.installation_subscriber_state
  (subscriber_uuid, as_of_date, remaining, current_stage, resolution, payment_eligible)
values
  ('90000000-0000-0000-0000-0000000000b1', date '2026-06-30', 13000, 'P1', 'resolved', true),
  ('90000000-0000-0000-0000-0000000000b2', date '2026-06-30',  4000, 'P4', 'resolved', true),
  ('90000000-0000-0000-0000-0000000000b3', date '2026-06-30',     0, 'DONE','resolved', false)
on conflict (subscriber_uuid) do update
  set remaining = excluded.remaining, current_stage = excluded.current_stage,
      resolution = excluded.resolution, payment_eligible = excluded.payment_eligible;

set local role authenticated;
set local request.jwt.claim.sub = '90000000-0000-0000-0000-0000000000a1';

-- ---------------------------------------------------------------------------
-- 1. المرشّحون من الأساس التاريخي — والمنتهي ليس منهم
-- ---------------------------------------------------------------------------

select pg_temp.ok(
  (public.installation_payout_candidates() ->> 'subscribers')::bigint = 2,
  'المرشّحون هم أصحاب المتبقّي وحدهم');

select pg_temp.ok(
  (public.installation_payout_candidates() ->> 'amount')::bigint = 7000,
  'والمبلغ مجموع القسط التالي لا المتبقّي كلّه');

select pg_temp.ok(
  (public.installation_payout_candidates() -> 'by_stage' -> 'P1' ->> 'amount')::bigint = 3000
  and (public.installation_payout_candidates() -> 'by_stage' -> 'P4' ->> 'amount')::bigint = 4000,
  'وكل مرحلة بمبلغها المعتمد');

select pg_temp.ok(
  (select count(*) from jsonb_array_elements(
     public.installation_payout_candidates() -> 'by_reseller') r
   where r ->> 'reseller' = 'وكيل الصرف'
     and (r ->> 'p1')::int = 1 and (r ->> 'p4')::int = 1) = 1,
  'والتجميع بالوكيل يعرض عدّ كل مرحلة');

-- ولا صفّ استحقاقٍ أُنشئ: القراءة لا تلتزم بمال.
select pg_temp.ok(
  (select count(*) from public.installation_entitlements
   where subscriber_id in ('pb-1','pb-2','pb-3')) = 0,
  'قراءة المرشّحين لا تُنشئ استحقاقاً');

-- التعليق يُخرج من الجاهزين ولا يُخرج من المرشّحين.
select public.apply_bulk_hold(array['pb-2'], 'PERMANENT', 'MANUAL_REVIEW',
  'مراجعة', 'pb.xlsx', null, '90000000-0000-0000-0000-00000000ab01');

select pg_temp.ok(
  (public.installation_payout_candidates() ->> 'held')::bigint = 1
  and (public.installation_payout_candidates() ->> 'subscribers')::bigint = 2,
  'المعلَّق يبقى مرشّحاً ويُعدّ محجوباً');

select pg_temp.ok(
  (select (r ->> 'ready')::int from jsonb_array_elements(
     public.installation_payout_candidates() -> 'by_reseller') r
   where r ->> 'reseller' = 'وكيل الصرف') = 1,
  'والجاهزون واحدٌ فقط بعد التعليق');

-- ---------------------------------------------------------------------------
-- 2. الاستحقاق والدفعة
-- ---------------------------------------------------------------------------

reset role;

insert into public.installation_entitlements
  (id, period, subscriber_id, subscriber_name, reseller, zone, fdt, remaining, stage, amount,
   invoice_status, payment_status, created_by)
values
  ('90000000-0000-0000-0000-0000000000c1','2026-07','pb-1','PB One','وكيل الصرف','new','PB-FDT',
   13000,'P1',3000,'approved','eligible','90000000-0000-0000-0000-0000000000a1'),
  ('90000000-0000-0000-0000-0000000000c2','2026-07','pb-2','PB Two','وكيل الصرف','new','PB-FDT',
   4000,'P4',4000,'approved','eligible','90000000-0000-0000-0000-0000000000a1')
on conflict do nothing;

insert into public.installation_payment_batches (id, name, status, prepared_by, prepared_at)
values ('90000000-0000-0000-0000-0000000000d1','PB-BATCH-1','DRAFT',
        '90000000-0000-0000-0000-0000000000a1', now())
on conflict do nothing;

insert into public.installation_payment_batch_items
  (batch_id, entitlement_id, subscriber_id, agent_name, stage_code, amount, status)
values
  ('90000000-0000-0000-0000-0000000000d1','90000000-0000-0000-0000-0000000000c1',
   'pb-1','وكيل الصرف','P1',3000,'PENDING'),
  ('90000000-0000-0000-0000-0000000000d1','90000000-0000-0000-0000-0000000000c2',
   'pb-2','وكيل الصرف','P4',4000,'PENDING')
on conflict do nothing;

set local role authenticated;
set local request.jwt.claim.sub = '90000000-0000-0000-0000-0000000000a1';

-- pb-2 مُعلَّق، فإعادة التحقّق يجب أن تُخرجه بسببه.
select pg_temp.ok(
  (public.revalidate_installation_batch('90000000-0000-0000-0000-0000000000d1')
   ->> 'blocked')::int = 1,
  'إعادة التحقّق تكشف السطر المُعلَّق');

select pg_temp.ok(
  (select blocked_reason from public.installation_payment_batch_items
   where entitlement_id = '90000000-0000-0000-0000-0000000000c2') like '%ON_HOLD%',
  'والسبب مكتوب بنصّه على السطر');

select pg_temp.ok(
  (select status from public.installation_payment_batches
   where id = '90000000-0000-0000-0000-0000000000d1') = 'VALIDATED',
  'والدفعة لا تصير جاهزة وفيها محجوب');

-- ---------------------------------------------------------------------------
-- 3. التأكيد يرفض ما لم يُحسم
-- ---------------------------------------------------------------------------

select pg_temp.must_fail(
  'select public.confirm_installation_batch_payment(
     ''90000000-0000-0000-0000-0000000000d1'', date ''2026-07-31'', ''REF-1'', null,
     gen_random_uuid())',
  'الدفع يُرفض ما دام في الدفعة سطر محجوب');

select pg_temp.ok(
  (select count(*) from public.installation_payments) = 0,
  'ولا دفعة تُسجَّل بعد الرفض');

-- شروط التأكيد نفسها.
select pg_temp.must_fail(
  'select public.confirm_installation_batch_payment(
     ''90000000-0000-0000-0000-0000000000d1'', null, ''REF-1'', null, gen_random_uuid())',
  'الدفع بلا تاريخ مرفوض');

select pg_temp.must_fail(
  'select public.confirm_installation_batch_payment(
     ''90000000-0000-0000-0000-0000000000d1'', date ''2026-07-31'', ''  '', null,
     gen_random_uuid())',
  'الدفع بلا إشعار خارجي مرفوض');

select pg_temp.must_fail(
  'select public.confirm_installation_batch_payment(
     ''90000000-0000-0000-0000-0000000000d1'', date ''2026-07-31'', ''REF-1'', null, null)',
  'الدفع بلا معرّف طلب مرفوض');

-- ---------------------------------------------------------------------------
-- 4. بعد رفع التعليق: الدفعة تجهز، والتأكيد يُنشئ المال مرّةً واحدة
-- ---------------------------------------------------------------------------

select public.release_hold_v2(
  (select id from public.installation_holds where subscriber_id = 'pb-2' limit 1),
  'انتهت المراجعة', '90000000-0000-0000-0000-00000000ab02');

select pg_temp.ok(
  (public.revalidate_installation_batch('90000000-0000-0000-0000-0000000000d1')
   ->> 'status') = 'READY',
  'بعد الرفع تصير الدفعة جاهزة');

select pg_temp.ok(
  (public.revalidate_installation_batch('90000000-0000-0000-0000-0000000000d1')
   ->> 'total_amount')::bigint = 7000,
  'ومجموعها مجموع سطورها');

select pg_temp.ok(
  (public.confirm_installation_batch_payment(
     '90000000-0000-0000-0000-0000000000d1', date '2026-07-31', 'TRF-99', 'تحويل',
     '90000000-0000-0000-0000-00000000ab03') ->> 'lines_paid')::int = 2,
  'التأكيد يدفع السطرين');

select pg_temp.ok(
  (select status from public.installation_payment_batches
   where id = '90000000-0000-0000-0000-0000000000d1') = 'PAID',
  'والدفعة تصير مدفوعة');

select pg_temp.ok(
  (select payment_ref from public.installation_payment_batches
   where id = '90000000-0000-0000-0000-0000000000d1') = 'TRF-99',
  'ورقم الإشعار محفوظ');

-- السطر وحدة الحقيقة: دفعتان مفصَّلتان بتاريخهما ومرجعهما.
select pg_temp.ok(
  (select count(*) from public.installation_payments pay
   join public.installation_payment_batch_items it on it.entitlement_id = pay.entitlement_id
   where it.batch_id = '90000000-0000-0000-0000-0000000000d1') = 2,
  'ولكل مشترك سطر دفعٍ مستقل');

-- التاريخ والإشعار يُقرآن من الدفعة، فلا يوجدان مرّتين ولا يفترقان.
select pg_temp.ok(
  (select payment_date from public.installation_payment_batches
   where id = '90000000-0000-0000-0000-0000000000d1') = date '2026-07-31',
  'وتاريخ الدفع محفوظ على الدفعة');

select pg_temp.ok(
  (select sum(pay.amount) from public.installation_payments pay
   join public.installation_payment_batch_items it on it.entitlement_id = pay.entitlement_id
   where it.batch_id = '90000000-0000-0000-0000-0000000000d1') = 7000,
  'ومجموع السطور يساوي مجموع الدفعة');

-- ولكل سطر قيدٌ في الدفتر.
select pg_temp.ok(
  (select count(*) from public.financial_ledger
   where domain = 'installation' and subscriber_id in ('pb-1','pb-2')
     and txn_type = 'PAYMENT') = 2,
  'ولكل سطر قيدٌ في الدفتر');

-- إعادة التأكيد لا تدفع ثانية.
select pg_temp.ok(
  (public.confirm_installation_batch_payment(
     '90000000-0000-0000-0000-0000000000d1', date '2026-07-31', 'TRF-99', 'تحويل',
     '90000000-0000-0000-0000-00000000ab03') ->> 'idempotent')::boolean = true,
  'إعادة التأكيد بلا أثر ثانٍ');

select pg_temp.ok(
  (select count(*) from public.installation_payments) = 2,
  'وعدد الدفعات يبقى اثنتين');

-- ---------------------------------------------------------------------------
-- 4.5 الطرفان يقولان الشيء نفسه
--
-- شاشة التحقّق ومسار الترحيل يجب أن يتّفقا على كل سطر: خلافُهما يعني دفعةً
-- تُعرض جاهزة ثم تُرفض عند الدفع، أو العكس — وكلاهما عطلٌ مالي.
-- ---------------------------------------------------------------------------

select pg_temp.ok(
  (public.installation_line_payable('90000000-0000-0000-0000-0000000000c1')
   ->> 'payable')::boolean = false,
  'المدفوع سلفاً لم يعد قابلاً للدفع');

-- والتسامح مع NOT_ENROLLED هو نفسه في الطرفين.
select pg_temp.ok(
  not ((public.installation_entitlement_eligibility('90000000-0000-0000-0000-0000000000c1')
        -> 'blockers') ? 'NOT_ENROLLED')
  or ((public.installation_line_payable('90000000-0000-0000-0000-0000000000c1')
       -> 'blockers') ? 'NOT_ENROLLED') = false,
  'NOT_ENROLLED لا يحجب في التعريف المشترك');

-- ---------------------------------------------------------------------------
-- 5. حالات السطر يقرّرها الخادم
-- ---------------------------------------------------------------------------

select pg_temp.ok(
  (public.installation_payment_state('90000000-0000-0000-0000-0000000000c1')
   ->> 'state') = 'PAID',
  'المدفوع حالته PAID');

-- ---------------------------------------------------------------------------
-- 6. الحارس
-- ---------------------------------------------------------------------------

reset role;
insert into auth.users (id, email) values ('90000000-0000-0000-0000-0000000000a9','pb-weak@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active)
values ('90000000-0000-0000-0000-0000000000a9','PB ضعيف','pb-weak@fixture.invalid','viewer',true)
on conflict (id) do update set role='viewer', is_active=true;

select pg_temp.must_fail(
  'set local role authenticated;
   set local request.jwt.claim.sub = ''90000000-0000-0000-0000-0000000000a9'';
   select public.confirm_installation_batch_payment(
     ''90000000-0000-0000-0000-0000000000d1'', date ''2026-07-31'', ''X'', null,
     gen_random_uuid())',
  'التأكيد يرفض من لا يملك payment.execute');

select pg_temp.must_fail(
  'set local role authenticated;
   set local request.jwt.claim.sub = ''90000000-0000-0000-0000-0000000000a9'';
   select public.revalidate_installation_batch(''90000000-0000-0000-0000-0000000000d1'')',
  'إعادة التحقّق ترفض من لا يملك payment.prepare');

rollback;
