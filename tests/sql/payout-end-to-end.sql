-- السلسلة كاملة: مرشّح ← فاتورة ← أهلية ← جاهز ← استحقاق ← دفعة ← تحقّق
--                 ← تأكيد ← دفتر ← تدقيق ← المرحلة التالية.
--
-- كل شيء داخل معاملةٍ تُلغى. لا دفعة حقيقية، ولا دورة تُعتمد.
--
-- ما تحرسه هذه الرحلة أن كل حلقةٍ تمنع ما قبلها من التسرّب: المحجوب لا
-- يُثبَّت استحقاقاً، وغير المثبَّت لا يدخل دفعة، وغير المتحقَّق منه لا يُدفع.
--
-- معزول بنطاق تسمية E2E-.

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

select '           == payout end to end ==';

insert into auth.users (id, email) values ('e0000000-0000-0000-0000-0000000000a1','e2e@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active)
values ('e0000000-0000-0000-0000-0000000000a1','E2E','e2e@fixture.invalid','admin',true)
on conflict (id) do update set role='admin', is_active=true;

insert into public.agents (id, code, official_name)
values ('e0000000-0000-0000-0000-0000000000c1','E2E-A','وكيل الرحلة')
on conflict (code) do nothing;

-- ثلاثة: واحد سيمرّ، وواحد سيبقى محجوباً بتعليق، وواحد بلا فاتورة.
insert into public.installation_subscribers
  (id, subscriber_id, reseller, fdt, start_date, total_amount, created_by)
values
  ('e0000000-0000-0000-0000-0000000000b1','e2e-pass','وكيل الرحلة','E2E-FDT', date '2026-01-01', 13000,'e0000000-0000-0000-0000-0000000000a1'),
  ('e0000000-0000-0000-0000-0000000000b2','e2e-held','وكيل الرحلة','E2E-FDT', date '2026-01-01', 13000,'e0000000-0000-0000-0000-0000000000a1'),
  ('e0000000-0000-0000-0000-0000000000b3','e2e-noinv','وكيل الرحلة','E2E-FDT', date '2026-01-01', 13000,'e0000000-0000-0000-0000-0000000000a1')
on conflict do nothing;

insert into public.installation_subscriber_state
  (subscriber_uuid, as_of_date, remaining, current_stage, resolution, payment_eligible)
values
  ('e0000000-0000-0000-0000-0000000000b1', date '2026-06-30', 13000, 'P1', 'resolved', true),
  ('e0000000-0000-0000-0000-0000000000b2', date '2026-06-30', 13000, 'P1', 'resolved', true),
  ('e0000000-0000-0000-0000-0000000000b3', date '2026-06-30',  4000, 'P4', 'resolved', true)
on conflict (subscriber_uuid) do update
  set remaining = excluded.remaining, current_stage = excluded.current_stage,
      resolution = excluded.resolution, payment_eligible = excluded.payment_eligible;

insert into public.subscriber_ownership
  (username_key, ownership_type, agent_id, effective_from, reason, performed_by)
values
  ('e2e-pass','RESELLER','e0000000-0000-0000-0000-0000000000c1',
   timestamptz '2026-01-01 00:00+03','تثبيت','e0000000-0000-0000-0000-0000000000a1'),
  ('e2e-held','RESELLER','e0000000-0000-0000-0000-0000000000c1',
   timestamptz '2026-01-01 00:00+03','تثبيت','e0000000-0000-0000-0000-0000000000a1'),
  ('e2e-noinv','RESELLER','e0000000-0000-0000-0000-0000000000c1',
   timestamptz '2026-01-01 00:00+03','تثبيت','e0000000-0000-0000-0000-0000000000a1')
on conflict do nothing;

set local role authenticated;
set local request.jwt.claim.sub = 'e0000000-0000-0000-0000-0000000000a1';

-- ١. مرشّحون ثلاثة، ولا أحد جاهز: لا فاتورة لأحد.
select pg_temp.ok(
  (public.installation_payout_candidates() ->> 'subscribers')::int = 3
  and (public.installation_payout_candidates() ->> 'ready')::int = 0,
  '١ · ثلاثة مرشّحين ولا جاهز — الفاتورة تحجب الجميع');

-- ٢. مراجعة الفواتير: تُدقَّق اثنتان، ويُترك الثالث.
select public.review_invoice('e2e-pass', 'P1', 'VERIFIED', 'مطابقة', 'E2E-1',
  'e0000000-0000-0000-0000-00000000ab01');
select public.review_invoice('e2e-held', 'P1', 'VERIFIED', 'مطابقة', 'E2E-2',
  'e0000000-0000-0000-0000-00000000ab02');

select pg_temp.ok(
  (public.installation_payout_candidates() ->> 'ready')::int = 2,
  '٢ · التدقيق يُخرج اثنين إلى الجاهزية');

-- ٣. تعليق أحدهما: يعود محجوباً.
select public.place_hold_v2('e2e-held', 'TEMPORARY', 'MANUAL_REVIEW',
  'شكوى قيد التحقيق', null, null, 'e0000000-0000-0000-0000-00000000ab03');

select pg_temp.ok(
  (public.installation_payout_candidates() ->> 'ready')::int = 1
  and (public.installation_payout_candidates() -> 'blocked' ->> 'hold')::int = 1,
  '٣ · التعليق يُعيده محجوباً، والجاهز واحد');

-- ٤. التثبيت: الجاهز وحده يصير استحقاقاً.
select pg_temp.ok(
  (public.materialize_installation_entitlements('2026-07', null, 500,
     'e0000000-0000-0000-0000-00000000ab04') ->> 'created')::int = 1,
  '٤ · لا يُثبَّت إلا الجاهز');

select pg_temp.ok(
  (select count(*) from public.installation_entitlements
   where subscriber_id in ('e2e-held','e2e-noinv')) = 0,
  '  · والمحجوب وغير المدقَّق خارج الالتزام');

select pg_temp.ok(
  (select amount from public.installation_entitlements where subscriber_id = 'e2e-pass') = 3000
  and (select stage from public.installation_entitlements where subscriber_id = 'e2e-pass') = 'P1',
  '  · وبمرحلته ومبلغه المعتمد');

-- والتثبيت لا يدفع.
select pg_temp.ok(
  (select payment_status from public.installation_entitlements
   where subscriber_id = 'e2e-pass') = 'eligible'
  and (select count(*) from public.installation_payments) = 0,
  '  · والتثبيت التزامٌ لا دفع');

-- ٥. الدفعة: تُنشأ مسوّدةً.
select pg_temp.ok(
  (public.create_installation_batch('E2E-BATCH', null, '2026-07',
     'e0000000-0000-0000-0000-00000000ab05') ->> 'items')::int = 1,
  '٥ · الدفعة تضمّ الاستحقاق الجاهز');

select pg_temp.ok(
  (select status from public.installation_payment_batches where name = 'E2E-BATCH') = 'DRAFT',
  '  · وتولد مسوّدةً — الإنشاء ليس دفعاً');

-- ٦. التحقّق: تصير جاهزة.
select pg_temp.ok(
  (public.revalidate_installation_batch(
     (select id from public.installation_payment_batches where name = 'E2E-BATCH'))
   ->> 'status') = 'READY',
  '٦ · التحقّق يجعلها جاهزة');

-- ٧. تعليقٌ بعد الإدراج: إعادة التحقّق تلتقطه.
select public.place_hold_v2('e2e-pass', 'PERMANENT', 'MANUAL_REVIEW',
  'اعتراض متأخّر', null, null, 'e0000000-0000-0000-0000-00000000ab06');

select pg_temp.must_fail(
  'select public.confirm_installation_batch_payment(
     (select id from public.installation_payment_batches where name = ''E2E-BATCH''),
     date ''2026-07-31'', ''TRF-E2E'', null, gen_random_uuid())',
  '٧ · تعليقٌ بعد الإدراج يمنع الدفع');

select pg_temp.ok(
  (select count(*) from public.installation_payments) = 0,
  '  · ولا دفعة تُسجَّل');

-- الرفض يُرجِع معاملته كلّها، فلا يبقى أثر كتابة. يُستدعى التحقّق صراحةً
-- ليُقرأ السبب المكتوب على السطر.
select public.revalidate_installation_batch(
  (select id from public.installation_payment_batches where name = 'E2E-BATCH'));

select pg_temp.ok(
  (select blocked_reason from public.installation_payment_batch_items
   where subscriber_id = 'e2e-pass') like '%ON_HOLD%',
  '  · والسبب مكتوب على السطر بعد التحقّق');

-- ٨. رفع التعليق ثم التأكيد.
select public.release_hold_v2(
  (select id from public.installation_holds
   where subscriber_id = 'e2e-pass' and status = 'ACTIVE' limit 1),
  'سُحب الاعتراض', 'e0000000-0000-0000-0000-00000000ab07');

select pg_temp.ok(
  (public.confirm_installation_batch_payment(
     (select id from public.installation_payment_batches where name = 'E2E-BATCH'),
     date '2026-07-31', 'TRF-E2E', 'تحويل الرحلة',
     'e0000000-0000-0000-0000-00000000ab08') ->> 'lines_paid')::int = 1,
  '٨ · التأكيد يدفع سطراً واحداً');

-- ٩. الأثر المالي: دفتر وسجلّ ودفعة.
select pg_temp.ok(
  (select count(*) from public.financial_ledger
   where domain = 'installation' and subscriber_id = 'e2e-pass'
     and txn_type = 'PAYMENT' and amount = 3000) = 1,
  '٩ · قيدٌ واحد في الدفتر بمبلغ المرحلة');

select pg_temp.ok(
  (select payment_status from public.installation_entitlements
   where subscriber_id = 'e2e-pass') = 'paid',
  '  · والاستحقاق صار مدفوعاً');

select pg_temp.ok(
  (select payment_ref from public.installation_payment_batches where name = 'E2E-BATCH') = 'TRF-E2E'
  and (select payment_date from public.installation_payment_batches
       where name = 'E2E-BATCH') = date '2026-07-31',
  '  · والدفعة تحمل تاريخها وإشعارها');

select pg_temp.ok(
  exists (select 1 from public.audit_logs where action = 'installation.batch.paid'
          and request_id = 'e0000000-0000-0000-0000-00000000ab08'),
  '  · والأثر مُدقَّق');

-- ١٠. لا دفع مرّتين.
select pg_temp.ok(
  (public.confirm_installation_batch_payment(
     (select id from public.installation_payment_batches where name = 'E2E-BATCH'),
     date '2026-07-31', 'TRF-E2E', null,
     'e0000000-0000-0000-0000-00000000ab08') ->> 'idempotent')::boolean = true,
  '١٠ · إعادة التأكيد بلا أثر ثانٍ');

select pg_temp.ok(
  (select count(*) from public.installation_payments) = 1
  and (select count(*) from public.financial_ledger
       where domain = 'installation' and subscriber_id = 'e2e-pass') = 1,
  '  · والدفتر يبقى بقيدٍ واحد');

-- ولا يُثبَّت استحقاقٌ ثانٍ لمرحلةٍ دُفعت.
select pg_temp.ok(
  (public.materialize_installation_entitlements('2026-07', null, 500,
     'e0000000-0000-0000-0000-00000000ab09') ->> 'created')::int = 0,
  '  · ولا التزام ثانٍ عن مرحلةٍ دُفعت');

-- ١١. التاريخ لم يُمسّ.
select pg_temp.ok(
  (select count(*) from public.installation_payment_history) = 0,
  '١١ · لا صفّ يُضاف إلى التاريخ المستورد');

rollback;
