-- DEC-007 بعد الحسم: الاستحقاق الشهري تقوده الحالة والفاتورة، لا حدثُ الشهر.
--
-- حُسم القرار (2026-09-02) على الاحتمال (أ): استحقاق أجور التنصيب في شهرٍ ما
-- يقوم على ثلاثة، لا رابع لها:
--   ١) المرحلة الرسمية الحالية P1..P4 من installation_subscriber_state.
--   ٢) فاتورةٌ VERIFIED **لنفس المرحلة**.
--   ٣) بقيّة ضوابط الأهلية القائمة (تعليق، هوية، عائدية، متبقٍّ موجب،
--      ولا استحقاق قائم لنفس الثلاثي).
-- ولا يُشترط ظهور حدث تفعيلٍ جديد في ذلك الشهر لكل مرحلةٍ لاحقة.
--
-- مثال صاحب المنتج حرفياً: مشتركٌ حالته P3 وله فاتورة VERIFIED لـP3 يستحقّ
-- 3,000 دينار في ذلك الشهر ولو لم يظهر له أيّ حدث تفعيلٍ فيه. وبلا فاتورة
-- VERIFIED لـP3 لا استحقاق ولا دفع.
--
-- هذا هو سلوك materialize_installation_entitlements المعتمد أصلاً — والملف
-- هنا يُثبّته اختباراً بعد أن صار قراراً، لا يُغيّره. الانحدار الذي يحرسه:
-- أن يُضاف يوماً حاجزُ «حدثٌ مؤهِّلٌ في الفترة» فيُحجب مالٌ عن مشتركين
-- قائمين بلا قرارٍ جديد.
--
-- كل شيء داخل معاملةٍ تُلغى. معزول بنطاق تسمية d7-. لا قاعدة إنتاج.

\set ON_ERROR_STOP on
\pset tuples_only on

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns text language sql as $$
  select case when p_cond then '   ok ' || p_label else 'FAILED: ' || p_label end;
$$;

begin;

select '   == installation DEC-007 monthly entitlement ==';

-- ===========================================================================
-- التهيئة: ثلاثة مشتركين في منتصف أقساطهم، كلّهم عند P3 بمتبقٍّ 7000.
-- الفارق بينهم الفاتورة وحدها.
-- ===========================================================================

insert into auth.users (id, email) values
  ('d7000000-0000-0000-0000-0000000000a1', 'd7-admin@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active) values
  ('d7000000-0000-0000-0000-0000000000a1', 'D7-AD', 'd7-admin@fixture.invalid', 'admin', true)
on conflict (id) do update set role = 'admin', is_active = true;

insert into public.agents (id, code, official_name) values
  ('d7000000-0000-0000-0000-0000000000a2', 'AGT-D7', 'وكيل الحسم')
on conflict (code) do nothing;

insert into public.packages (code, name, semantic_category) values
  ('D7-PKG', 'D7-PKG', 'PAID_PACKAGE')
on conflict (code) do nothing;

insert into public.saas_import_batches
  (id, source_kind, source_filename, source_checksum, parser_version, imported_by,
   completeness_status)
values ('d7000000-0000-0000-0000-0000000000b1', 'ACTIVATION_EVENTS', 'd7-jan.xlsx',
        'ck-d7', 'v1', 'd7000000-0000-0000-0000-0000000000a1', 'COMPLETE')
on conflict do nothing;

-- حدثُ التنصيب الأصلي في كانون الثاني — وحده. لا شيء في أيلول، وهو الشهر
-- الذي يُثبَّت فيه الاستحقاق أدناه.
insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, canceled, fdt_code,
   event_created_at)
values
  ('d7000000-0000-0000-0000-0000000000b1', 'D7-EV-MID',   'd7-mid',   'D7-PKG', false, '105',
   timestamptz '2026-01-05 09:00+03'),
  ('d7000000-0000-0000-0000-0000000000b1', 'D7-EV-NOINV', 'd7-noinv', 'D7-PKG', false, '105',
   timestamptz '2026-01-05 09:00+03'),
  ('d7000000-0000-0000-0000-0000000000b1', 'D7-EV-OLDINV','d7-oldinv','D7-PKG', false, '105',
   timestamptz '2026-01-05 09:00+03')
on conflict do nothing;

insert into public.subscriber_identities
  (username, identity_status, match_method, source_classification, effective_agent_id, fdt_code)
values
  ('d7-mid',   'MATCHED', 'EXACT_USERNAME', 'RESELLER', 'd7000000-0000-0000-0000-0000000000a2', '105'),
  ('d7-noinv', 'MATCHED', 'EXACT_USERNAME', 'RESELLER', 'd7000000-0000-0000-0000-0000000000a2', '105'),
  ('d7-oldinv','MATCHED', 'EXACT_USERNAME', 'RESELLER', 'd7000000-0000-0000-0000-0000000000a2', '105')
on conflict do nothing;

insert into public.installation_subscribers
  (id, subscriber_id, reseller, fdt, start_date, total_amount, created_by)
values
  ('d7000000-0000-0000-0000-0000000000c1','d7-mid','وكيل الحسم','105', date '2026-01-01', 13000,'d7000000-0000-0000-0000-0000000000a1'),
  ('d7000000-0000-0000-0000-0000000000c2','d7-noinv','وكيل الحسم','105', date '2026-01-01', 13000,'d7000000-0000-0000-0000-0000000000a1'),
  ('d7000000-0000-0000-0000-0000000000c3','d7-oldinv','وكيل الحسم','105', date '2026-01-01', 13000,'d7000000-0000-0000-0000-0000000000a1')
on conflict do nothing;

-- منتصف الأقساط: P1 و P2 خلفهم، والمرحلة الرسمية P3 بمتبقٍّ 7000.
insert into public.installation_subscriber_state
  (subscriber_uuid, as_of_date, remaining, received_total, total_amount,
   current_stage, resolution, payment_eligible)
values
  ('d7000000-0000-0000-0000-0000000000c1', date '2026-08-31', 7000, 6000, 13000, 'P3', 'resolved', true),
  ('d7000000-0000-0000-0000-0000000000c2', date '2026-08-31', 7000, 6000, 13000, 'P3', 'resolved', true),
  ('d7000000-0000-0000-0000-0000000000c3', date '2026-08-31', 7000, 6000, 13000, 'P3', 'resolved', true)
on conflict (subscriber_uuid) do nothing;

insert into public.subscriber_ownership
  (username_key, ownership_type, agent_id, effective_from, reason, performed_by)
values
  ('d7-mid','RESELLER','d7000000-0000-0000-0000-0000000000a2',
   timestamptz '2026-01-01 00:00+03','تثبيت','d7000000-0000-0000-0000-0000000000a1'),
  ('d7-noinv','RESELLER','d7000000-0000-0000-0000-0000000000a2',
   timestamptz '2026-01-01 00:00+03','تثبيت','d7000000-0000-0000-0000-0000000000a1'),
  ('d7-oldinv','RESELLER','d7000000-0000-0000-0000-0000000000a2',
   timestamptz '2026-01-01 00:00+03','تثبيت','d7000000-0000-0000-0000-0000000000a1')
on conflict do nothing;

-- فاتورة P2 مُتحقَّقةٌ باقيةٌ من مرحلةٍ ماضية — أمرٌ طبيعيّ بعد دفع P2.
-- review_invoice لا يقبل تدقيق مرحلةٍ ليست القسط القادم، فتُكتب كما تبقى
-- في القاعدة فعلاً بعد أن دُفعت مرحلتها.
insert into public.installation_invoices
  (subscriber_id, stage_code, invoice_number, invoice_source, amount, status,
   verified_by, verified_at, created_by)
values ('d7-oldinv', 'P2', 'D7-INV-OLD-P2', 'MANUAL', 3000, 'VERIFIED',
        'd7000000-0000-0000-0000-0000000000a1', timestamptz '2026-08-01 10:00+03',
        'd7000000-0000-0000-0000-0000000000a1')
on conflict do nothing;

set local role authenticated;
set local request.jwt.claim.sub = 'd7000000-0000-0000-0000-0000000000a1';

-- ===========================================================================
-- ١. الشرط الذي يحكم القرار: لا حدث تفعيلٍ في شهر الاستحقاق.
-- ===========================================================================

select pg_temp.ok(
  (select count(*) from public.saas_activation_events
   where username in ('d7-mid', 'd7-noinv', 'd7-oldinv')
     and event_created_at >= timestamptz '2026-09-01 00:00+03'
     and event_created_at <  timestamptz '2026-10-01 00:00+03') = 0
  and (select count(*) from public.saas_activation_events
       where username in ('d7-mid', 'd7-noinv', 'd7-oldinv')) = 3,
  '١ · الشهر المطلوب بلا حدث تفعيلٍ واحد — والأحداث كلّها في كانون الثاني');

select pg_temp.ok(
  (select count(*) from public.installation_subscriber_state st
   join public.installation_subscribers s on s.id = st.subscriber_uuid
   where s.subscriber_id in ('d7-mid', 'd7-noinv', 'd7-oldinv')
     and st.current_stage = 'P3' and st.remaining = 7000) = 3,
  '  · وثلاثتهم في منتصف أقساطهم: المرحلة الرسمية P3 بمتبقٍّ 7000');

-- ===========================================================================
-- ٢. (أ) المحسوم: حالة P3 + فاتورة VERIFIED لـP3 ⇒ 3,000 في أيلول.
-- ===========================================================================

select public.review_invoice('d7-mid', 'P3', 'VERIFIED', 'مطابقة', 'D7-INV-MID-P3',
  'd7000000-0000-0000-0000-00000000f001');

select public.materialize_installation_entitlements('2026-09', null, 500,
  'd7000000-0000-0000-0000-00000000f002');

select pg_temp.ok(
  (select count(*) from public.installation_entitlements
   where subscriber_id = 'd7-mid' and period = '2026-09') = 1
  and (select stage from public.installation_entitlements
       where subscriber_id = 'd7-mid' and period = '2026-09') = 'P3'
  and (select amount from public.installation_entitlements
       where subscriber_id = 'd7-mid' and period = '2026-09') = 3000
  and (select remaining from public.installation_entitlements
       where subscriber_id = 'd7-mid' and period = '2026-09') = 7000,
  '٢ · P3 وفاتورتها المُتحقَّقة تُنتج استحقاق 3000 في شهرٍ بلا حدث تفعيل (DEC-007 أ)');

-- والمال يُصرف فعلاً، لا يقف عند «مستحقّ على الورق».
select public.record_installation_payment(
  (select id from public.installation_entitlements
   where subscriber_id = 'd7-mid' and period = '2026-09'),
  null, 'd7000000-0000-0000-0000-00000000f003');

select pg_temp.ok(
  (select payment_status from public.installation_entitlements
   where subscriber_id = 'd7-mid' and period = '2026-09') = 'paid'
  and (select sum(p.amount) from public.installation_payments p
       join public.installation_entitlements t on t.id = p.entitlement_id
       where t.subscriber_id = 'd7-mid' and t.period = '2026-09') = 3000,
  '  · ويُصرف 3000 فعلاً: الحدث الغائب لا يحجب قسطاً استحقّته الحالة والفاتورة');

-- ===========================================================================
-- ٣. الوجه الآخر من القرار نفسه: بلا فاتورة VERIFIED للمرحلة ⇒ لا شيء.
-- ===========================================================================

select pg_temp.ok(
  not exists (select 1 from public.installation_entitlements
              where subscriber_id = 'd7-noinv'),
  '٣ · بلا فاتورة مُتحقَّقة لـP3 لا استحقاق ولا دفع');

select pg_temp.ok(
  not exists (select 1 from public.installation_entitlements
              where subscriber_id = 'd7-oldinv'),
  '  · وفاتورة P2 المُتحقَّقة لا تُغني عن P3 — المطابقة بالمرحلة نفسها');

select pg_temp.ok(
  not exists (select 1 from public.installation_payments p
              join public.installation_entitlements t on t.id = p.entitlement_id
              where t.subscriber_id in ('d7-noinv', 'd7-oldinv'))
  and not exists (select 1 from public.financial_ledger
                  where subscriber_id in ('d7-noinv', 'd7-oldinv')),
  '  · ولا دفعة ولا قيدٌ في الدفتر لأيٍّ منهما');

-- ===========================================================================
-- ٤. لا حاجز «حدثٌ مؤهِّلٌ في الفترة» في المحرّك الشهري — القرار في المصدر.
-- ===========================================================================

select pg_temp.ok(
  pg_catalog.strpos(
    pg_catalog.pg_get_functiondef(
      'public.materialize_installation_entitlements(text,text,integer,uuid)'::regprocedure),
    'saas_activation_events') = 0,
  '٤ · والمحرّك الشهري لا يقرأ أحداث التفعيل إطلاقاً — لا حاجز شهريّ خفيّ');

rollback;
