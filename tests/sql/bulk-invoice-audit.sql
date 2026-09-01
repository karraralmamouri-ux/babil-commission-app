-- تدقيق الفواتير بالجملة: المعاينة السداسية والتطبيق عبر review_invoice.

\set ON_ERROR_STOP on
\pset tuples_only on

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns text language sql as $$
  select case when p_cond then '    ok ' || p_label else 'FAILED: ' || p_label end;
$$;

begin;

insert into auth.users (id, email) values
  ('a1111111-1111-1111-1111-111111111111','adm-inv@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active) values
  ('a1111111-1111-1111-1111-111111111111','AD','adm-inv@fixture.invalid','admin',true)
on conflict (id) do update set role=excluded.role, is_active=true;

-- ثلاثة مشتركين: واحد على P1 (سيُطابَق)، وواحد منتهٍ (remaining=0)، وواحد
-- غير معروف يُترك خارج الرفعة عمداً — معرَّفه لا يظهر في installation_subscribers.
insert into public.installation_subscribers (id, subscriber_id, reseller, created_by) values
  ('a2222222-2222-2222-2222-222222222221','BULK-P1','Fixture Reseller','a1111111-1111-1111-1111-111111111111'),
  ('a2222222-2222-2222-2222-222222222222','BULK-P2','Fixture Reseller','a1111111-1111-1111-1111-111111111111'),
  ('a2222222-2222-2222-2222-222222222223','BULK-DONE','Fixture Reseller','a1111111-1111-1111-1111-111111111111')
on conflict (id) do nothing;

insert into public.installation_subscriber_state
  (subscriber_uuid, as_of_date, remaining, received_total, total_amount,
   current_stage, resolution, payment_eligible)
values
  ('a2222222-2222-2222-2222-222222222221','2026-09-01',13000,0,13000,'P1','resolved',true),
  ('a2222222-2222-2222-2222-222222222222','2026-09-01',10000,3000,13000,'P2','resolved',true),
  ('a2222222-2222-2222-2222-222222222223','2026-09-01',0,13000,13000,'DONE','resolved',false)
on conflict (subscriber_uuid) do update
  set remaining = excluded.remaining, current_stage = excluded.current_stage,
      payment_eligible = excluded.payment_eligible;

set local role authenticated;
set local request.jwt.claim.sub = 'a1111111-1111-1111-1111-111111111111';

-- الرفعة: BULK-P1 مطابق، BULK-P2 مكرَّر مرّتين (سيُصنَّف تعارضاً)، BULK-DONE
-- لا مرحلة مفتوحة له (سيُصنَّف "مستخدَمة سلفاً")، BULK-UNKNOWN غير معروف،
-- وصفٌّ فاسد بلا رقم فاتورة.
select public.preview_bulk_invoice_upload($$[
  {"subscriber_id":"BULK-P1","invoice_number":"INV-9001","invoice_date":"2026-09-05"},
  {"subscriber_id":"BULK-P2","invoice_number":"INV-9002","invoice_date":"2026-09-05"},
  {"subscriber_id":"BULK-P2","invoice_number":"INV-9003","invoice_date":"2026-09-06"},
  {"subscriber_id":"BULK-DONE","invoice_number":"INV-9004","invoice_date":"2026-09-05"},
  {"subscriber_id":"BULK-UNKNOWN","invoice_number":"INV-9005","invoice_date":"2026-09-05"},
  {"subscriber_id":"BULK-P9","invoice_number":"","invoice_date":"2026-09-05"}
]$$::jsonb) as v_preview \gset

select (:'v_preview'::jsonb -> 'counts' ->> 'matched')::int = 1 as v_matched_ok \gset
select (:'v_preview'::jsonb -> 'counts' ->> 'conflict')::int = 2 as v_conflict_ok \gset
select (:'v_preview'::jsonb -> 'counts' ->> 'already_used')::int = 1 as v_already_used_ok \gset
select (:'v_preview'::jsonb -> 'counts' ->> 'unknown')::int = 1 as v_unknown_ok \gset
select (:'v_preview'::jsonb -> 'counts' ->> 'invalid')::int = 1 as v_invalid_ok \gset

select pg_temp.ok(:'v_matched_ok'::boolean, 'BULK-P1 وحدها تُصنَّف matched');
select pg_temp.ok(:'v_conflict_ok'::boolean, 'BULK-P2 بفاتورتين في الرفعة نفسها = صفّان conflict — لا تخمين لتقدّم مرحلتين');
select pg_temp.ok(:'v_already_used_ok'::boolean, 'BULK-DONE بلا مرحلة مفتوحة (remaining=0) = already_used');
select pg_temp.ok(:'v_unknown_ok'::boolean, 'BULK-UNKNOWN غير الموجود = unknown');
select pg_temp.ok(:'v_invalid_ok'::boolean, 'الصفّ بلا رقم فاتورة = invalid');

-- التطبيق: يُعيد نفس التصنيف من الخادم، ولا يطبّق إلا BULK-P1.
select public.apply_bulk_invoice_upload($$[
  {"subscriber_id":"BULK-P1","invoice_number":"INV-9001","invoice_date":"2026-09-05"},
  {"subscriber_id":"BULK-P2","invoice_number":"INV-9002","invoice_date":"2026-09-05"},
  {"subscriber_id":"BULK-P2","invoice_number":"INV-9003","invoice_date":"2026-09-06"},
  {"subscriber_id":"BULK-DONE","invoice_number":"INV-9004","invoice_date":"2026-09-05"},
  {"subscriber_id":"BULK-UNKNOWN","invoice_number":"INV-9005","invoice_date":"2026-09-05"},
  {"subscriber_id":"BULK-P9","invoice_number":"","invoice_date":"2026-09-05"}
]$$::jsonb, 'fixture.csv', 'تدقيق تجريبي', 'b3333333-3333-3333-3333-333333333333'
) as v_apply \gset

select (:'v_apply'::jsonb ->> 'applied')::int = 1 as v_applied_one \gset
select (:'v_apply'::jsonb ->> 'skipped')::int = 5 as v_skipped_five \gset

select pg_temp.ok(:'v_applied_one'::boolean, 'التطبيق يُنفِّذ صفّاً واحداً فقط — BULK-P1');
select pg_temp.ok(:'v_skipped_five'::boolean, 'البقية الخمسة تُترَك — لا تخمين ولا تطبيق جزئي خاطئ');

select pg_temp.ok(
  (select status from public.installation_invoices
   where subscriber_id = 'BULK-P1' and stage_code = 'P1') = 'VERIFIED',
  'BULK-P1/P1 صار VERIFIED فعلاً عبر review_invoice نفسها');

select pg_temp.ok(
  (select count(*) from public.installation_invoices where subscriber_id = 'BULK-P2') = 0,
  'BULK-P2 (تعارض) لم يُكتَب لها أيّ صفّ فاتورة');

-- إعادة تطبيق نفس request_id لا تُكرِّر الأثر.
select public.apply_bulk_invoice_upload($$[
  {"subscriber_id":"BULK-P1","invoice_number":"INV-9001","invoice_date":"2026-09-05"}
]$$::jsonb, 'fixture.csv', 'تدقيق تجريبي', 'b3333333-3333-3333-3333-333333333333'
) as v_replay \gset

select pg_temp.ok(
  (:'v_replay'::jsonb ->> 'idempotent')::boolean,
  'إعادة نفس request_id تُعامَل كتكرارٍ هادئ');

reset role;

rollback;
