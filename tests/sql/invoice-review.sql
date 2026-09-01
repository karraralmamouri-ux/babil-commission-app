-- مراجعة الفواتير.
--
-- التدقيق يفتح مالاً: يرفع الحاجب عن قسطٍ لم يُدفع. فالخطر أن يُدقَّق ما لا
-- يجوز — مرحلةٌ ماضية، أو مشتركٌ أنهى أقساطه — فيُصرف عن شيءٍ دُفع.
--
-- معزول بنطاق تسمية IR-.

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

select '           == invoice review ==';

insert into auth.users (id, email) values ('a0000000-0000-0000-0000-0000000000a1','ir@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active)
values ('a0000000-0000-0000-0000-0000000000a1','IR','ir@fixture.invalid','admin',true)
on conflict (id) do update set role='admin', is_active=true;

insert into public.installation_subscribers
  (id, subscriber_id, reseller, fdt, start_date, total_amount, created_by)
values
  ('a0000000-0000-0000-0000-0000000000b1','ir-1','وكيل الفواتير','IR-FDT', date '2026-01-01', 13000,'a0000000-0000-0000-0000-0000000000a1'),
  ('a0000000-0000-0000-0000-0000000000b2','ir-2','وكيل الفواتير','IR-FDT', date '2026-01-01', 13000,'a0000000-0000-0000-0000-0000000000a1'),
  ('a0000000-0000-0000-0000-0000000000b3','ir-done','وكيل الفواتير','IR-FDT', date '2026-01-01', 13000,'a0000000-0000-0000-0000-0000000000a1')
on conflict do nothing;

insert into public.installation_subscriber_state
  (subscriber_uuid, as_of_date, remaining, current_stage, resolution, payment_eligible)
values
  ('a0000000-0000-0000-0000-0000000000b1', date '2026-06-30', 13000, 'P1', 'resolved', true),
  ('a0000000-0000-0000-0000-0000000000b2', date '2026-06-30',  4000, 'P4', 'resolved', true),
  ('a0000000-0000-0000-0000-0000000000b3', date '2026-06-30',     0, 'DONE','resolved', false)
on conflict (subscriber_uuid) do update
  set remaining = excluded.remaining, current_stage = excluded.current_stage,
      resolution = excluded.resolution, payment_eligible = excluded.payment_eligible;

insert into public.agents (id, code, official_name) values
  ('a0000000-0000-0000-0000-0000000000c1','IR-A','وكيل الفواتير')
on conflict (code) do nothing;

-- عائدية محسومة: بدونها يُحجب المشترك بصنف PARENT، فلا يظهر أثر الفاتورة.
insert into public.subscriber_ownership
  (username_key, ownership_type, agent_id, effective_from, reason, performed_by)
values
  ('ir-1','RESELLER','a0000000-0000-0000-0000-0000000000c1',
   timestamptz '2026-01-01 00:00+03','تثبيت','a0000000-0000-0000-0000-0000000000a1'),
  ('ir-2','RESELLER','a0000000-0000-0000-0000-0000000000c1',
   timestamptz '2026-01-01 00:00+03','تثبيت','a0000000-0000-0000-0000-0000000000a1')
on conflict do nothing;

set local role authenticated;
set local request.jwt.claim.sub = 'a0000000-0000-0000-0000-0000000000a1';

-- ---------------------------------------------------------------------------
-- 1. الطابور يعرض من لا فاتورة له
-- ---------------------------------------------------------------------------

select pg_temp.ok(
  (public.page_invoice_review(p_limit => 50) ->> 'total')::int = 2,
  'الطابور يحمل أصحاب القسط القادم وحدهم');

select pg_temp.ok(
  (select count(*) from jsonb_array_elements(
     public.page_invoice_review(p_limit => 50) -> 'rows') r
   where r ->> 'invoice_status' = 'NOT_CHECKED') = 2,
  'وغياب الصفّ يُعرض «لم تُفحص» لا يُخفي المشترك');

select pg_temp.ok(
  (public.invoice_review_summary() -> 'by_status' -> 'NOT_CHECKED' ->> 'amount')::bigint = 7000,
  'والملخّص يقول كم من المال ينتظر الفحص');

select pg_temp.ok(
  (public.invoice_review_summary() ->> 'verified')::int = 0,
  'ولا مدقَّقة بعد');

-- ---------------------------------------------------------------------------
-- 2. التدقيق يفتح الحاجب
-- ---------------------------------------------------------------------------

select pg_temp.ok(
  (public.review_invoice('ir-1', 'P1', 'VERIFIED', 'فاتورة مطابقة', 'INV-1',
     'a0000000-0000-0000-0000-00000000ab01') ->> 'status_after') = 'VERIFIED',
  'التدقيق يقع');

select pg_temp.ok(
  (select status from public.installation_invoices where subscriber_id = 'ir-1') = 'VERIFIED'
  and (select verified_by is not null and verified_at is not null
       from public.installation_invoices where subscriber_id = 'ir-1'),
  'ويُنسب إلى من دقّقه ومتى');

select pg_temp.ok(
  (public.invoice_review_summary() ->> 'verified')::int = 1
  and (public.invoice_review_summary() ->> 'verified_amount')::bigint = 3000,
  'والملخّص يعكسه فوراً');

-- والأثر في الصرف: الحاجب يُرفع عن هذا المشترك وحده.
select pg_temp.ok(
  (public.installation_payout_candidates() -> 'blocked' ->> 'invoice')::int = 1,
  'ويقلّ المحجوبون بالفاتورة واحداً');

select pg_temp.ok(
  (public.installation_payout_candidates() ->> 'ready')::int = 1
  and (public.installation_payout_candidates() ->> 'ready_amount')::bigint = 3000,
  'ويصير جاهزاً فعلاً — لا محجوباً بصنفٍ آخر');

-- ---------------------------------------------------------------------------
-- 3. ما لا يجوز تدقيقه
-- ---------------------------------------------------------------------------

select pg_temp.must_fail(
  'select public.review_invoice(''ir-1'', ''P2'', ''VERIFIED'', ''مرحلة ليست القادمة'',
     null, gen_random_uuid())',
  'تدقيق مرحلةٍ ليست القسط القادم مرفوض');

select pg_temp.must_fail(
  'select public.review_invoice(''ir-done'', ''P1'', ''VERIFIED'', ''أنهى أقساطه'',
     null, gen_random_uuid())',
  'تدقيق من أنهى أقساطه مرفوض');

select pg_temp.must_fail(
  'select public.review_invoice(''ir-ghost'', ''P1'', ''VERIFIED'', ''مجهول'',
     null, gen_random_uuid())',
  'تدقيق مشترك غير معروف مرفوض');

select pg_temp.must_fail(
  'select public.review_invoice(''ir-2'', ''DONE'', ''VERIFIED'', ''مرحلة غير قابلة للدفع'',
     null, gen_random_uuid())',
  'تدقيق مرحلة غير قابلة للدفع مرفوض');

select pg_temp.must_fail(
  'select public.review_invoice(''ir-2'', ''P4'', ''VERIFIED'', ''  '',
     null, gen_random_uuid())',
  'قرار بلا سبب مرفوض');

select pg_temp.must_fail(
  'select public.review_invoice(''ir-2'', ''P4'', ''VERIFIED'', ''سبب'', null, null)',
  'قرار بلا معرّف طلب مرفوض');

select pg_temp.must_fail(
  'select public.review_invoice(''ir-2'', ''P4'', ''WHATEVER'', ''سبب'',
     null, gen_random_uuid())',
  'حالة فاتورة غير معروفة مرفوضة');

-- ---------------------------------------------------------------------------
-- 4. الرفض والنقص قراران أيضاً
-- ---------------------------------------------------------------------------

select pg_temp.ok(
  (public.review_invoice('ir-2', 'P4', 'MISSING', 'لا فاتورة في المصدر', null,
     'a0000000-0000-0000-0000-00000000ab02') ->> 'status_after') = 'MISSING',
  'إعلان النقص حكمٌ يُسجَّل');

select pg_temp.ok(
  (public.installation_payout_candidates() -> 'blocked' ->> 'invoice')::int = 1,
  'والنقص يبقى حاجباً');

select pg_temp.ok(
  (public.review_invoice('ir-2', 'P4', 'REJECTED', 'الفاتورة لا تخصّ هذه المرحلة', null,
     'a0000000-0000-0000-0000-00000000ab03') ->> 'status_after') = 'REJECTED',
  'والرفض يقع');

select pg_temp.ok(
  (select rejected_by is not null and rejected_at is not null
      and btrim(coalesce(rejection_reason, '')) <> ''
   from public.installation_invoices where subscriber_id = 'ir-2'),
  'ويُنسب بسببه — كما يشترط القيد');

-- إعادة الطلب نفسه بلا أثر ثانٍ.
select pg_temp.ok(
  (public.review_invoice('ir-2', 'P4', 'REJECTED', 'الفاتورة لا تخصّ هذه المرحلة', null,
     'a0000000-0000-0000-0000-00000000ab03') ->> 'idempotent')::boolean = true,
  'وإعادة القرار نفسه بلا أثر ثانٍ');

-- والقرار مُدقَّق.
select pg_temp.ok(
  exists (select 1 from public.audit_logs
          where action = 'installation.invoice.reviewed'
            and request_id = 'a0000000-0000-0000-0000-00000000ab01'
            and extra like '%stage=P1%' and extra like '%amount=3000%'),
  'وكل قرار مُسجَّل بمرحلته ومبلغه');

-- ---------------------------------------------------------------------------
-- 4ب. صفّ واحد لكل (مشترك، مرحلة) — حتى تحت تعارض متزامن
-- ---------------------------------------------------------------------------

select pg_temp.ok(
  (select count(*) from public.installation_invoices
   where subscriber_id = 'ir-1' and stage_code = 'P1') = 1,
  'صفّ فاتورة واحد بعد التدقيق — لا يتضاعف بإعادة القرار');

-- محاكاة السباق: إدراج مباشر لصفّ ثانٍ لنفس (المشترك، المرحلة) يُرفض بالقيد
-- الفريد نفسه الذي يجعل review_invoice ذرّياً، لا بمنطق الدالة وحده.
select pg_temp.must_fail(
  'insert into public.installation_invoices
     (subscriber_id, stage_code, invoice_source, amount, status, created_by)
   values (''ir-1'', ''P1'', ''MANUAL'', 3000, ''PENDING'',
           ''a0000000-0000-0000-0000-0000000000a1'')',
  'إدراج فاتورة ثانية لنفس المشترك والمرحلة مرفوض بالقيد الفريد');

-- ---------------------------------------------------------------------------
-- 5. أودو مؤجَّل: لا يُكتب ولا يُقرأ
-- ---------------------------------------------------------------------------

select pg_temp.ok(
  (select count(*) from public.installation_invoices
   where odoo_invoice_id is not null or odoo_state is not null
      or odoo_checked_at is not null) = 0,
  'لا حقل أودو يُكتب في هذا المسار');

-- ---------------------------------------------------------------------------
-- 6. الحارس
-- ---------------------------------------------------------------------------

reset role;
insert into auth.users (id, email) values ('a0000000-0000-0000-0000-0000000000a9','ir-weak@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active)
values ('a0000000-0000-0000-0000-0000000000a9','IR ضعيف','ir-weak@fixture.invalid','viewer',true)
on conflict (id) do update set role='viewer', is_active=true;

select pg_temp.must_fail(
  'set local role authenticated;
   set local request.jwt.claim.sub = ''a0000000-0000-0000-0000-0000000000a9'';
   select public.review_invoice(''ir-1'', ''P1'', ''VERIFIED'', ''بلا صلاحية'',
     null, gen_random_uuid())',
  'التدقيق يرفض من لا يملك invoice.verify');

-- القراءة مسموحة للمشاهد: الطابور ليس سرّاً، والقرار وحده محروس.
set local role authenticated;
set local request.jwt.claim.sub = 'a0000000-0000-0000-0000-0000000000a9';
select pg_temp.ok(
  (public.page_invoice_review(p_limit => 5) ->> 'total')::int >= 0,
  'والمشاهد يقرأ الطابور ولا يقرّر فيه');
reset role;

rollback;
