-- ترقية قاعدة قائمة: فتح الحالة الرسمية لتسجيلاتٍ أقدم من الجسر (INS-013).
--
-- الخطر الذي تُغطّيه هذه الرحلة ماليّ: تسجيل NEW_INSTALLATION قد يكون له
-- استحقاقات مدفوعة وقيود في الدفتر، وهو مع ذلك بلا installation_subscriber_state
-- لأن الجسر لم يكن موجوداً يوم دُفعت. فتحُه على المرحلة الافتتاحية يعيده إلى
-- P1 ويجعل مرحلةً مدفوعةً مستحقّةً ثانيةً — أي دفعاً مزدوجاً بيد الترقية نفسها.
--
-- التهيئة هنا «ما قبل المهاجرة» صناعياً: التسجيلات تُدرَج والزنادُ معطَّل، ثم
-- تُستدعى ensure_installation_state_for_enrollment كما تستدعيها المهاجرة.
-- لا قاعدة إنتاج، ولا صفّ إنتاجيّ واحد.
--
-- كل شيء داخل معاملةٍ تُلغى. معزول بنطاق تسمية ub-.

\set ON_ERROR_STOP on
\pset tuples_only on

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns text language sql as $$
  select case when p_cond then '   ok ' || p_label else 'FAILED: ' || p_label end;
$$;

create or replace function pg_temp.must_fail_with(
  p_sql text, p_label text, p_needle text)
returns text language plpgsql as $$
begin
  execute p_sql;
  return 'FAILED: ' || p_label || ' — مرّ وكان يجب أن يُرفض';
exception when others then
  if pg_catalog.strpos(sqlerrm, p_needle) > 0 then
    return '   ok ' || p_label;
  end if;
  return 'FAILED: ' || p_label || ' — رُفض بسبب آخر: ' || sqlerrm;
end;
$$;

-- استحقاقٌ مدفوعٌ بالكامل كما كان يُكتب قبل الجسر: صفّ الاستحقاق، وصفّ
-- الدفعة، وقيدُ الدفتر. بلا واقعة تاريخ — وهذا بالضبط ما كان ناقصاً.
create or replace function pg_temp.settle(
  p_sub text, p_period text, p_stage text, p_amount bigint, p_remaining bigint,
  p_actor uuid, p_seq integer)
returns void language plpgsql as $$
declare
  v_ent uuid := ('be000000-0000-0000-0000-' || lpad(p_seq::text, 12, '0'))::uuid;
begin
  insert into public.installation_entitlements
    (id, period, subscriber_id, subscriber_name, reseller, fdt, remaining, stage,
     amount, invoice_status, payment_status, paid_amount, paid_by, paid_at, created_by)
  values (v_ent, p_period, p_sub, p_sub, 'وكيل الترقية', '105', p_remaining, p_stage,
          p_amount, 'approved', 'paid', p_amount, p_actor, now(), p_actor);

  insert into public.installation_payments
    (entitlement_id, amount, payment_date, request_id, created_by)
  values (v_ent, p_amount, date '2026-05-01', gen_random_uuid(), p_actor);

  insert into public.financial_ledger
    (domain, txn_type, source_origin, source_table, source_id, agent_name,
     subscriber_id, stage, month_key, original_cycle_key, amount, direction,
     request_id, created_by, posted_by)
  values ('installation', 'PAYMENT', 'PAYMENT_PATH', 'installation_entitlements',
          v_ent, 'وكيل الترقية', p_sub, p_stage, p_period, p_period, p_amount, 1,
          gen_random_uuid(), p_actor, p_actor);
end;
$$;

begin;

select '   == installation upgrade backfill ==';

-- ===========================================================================
-- التهيئة.
-- ===========================================================================

insert into auth.users (id, email) values
  ('be000000-0000-0000-0000-0000000000a1', 'ub-admin@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active) values
  ('be000000-0000-0000-0000-0000000000a1', 'UB-AD', 'ub-admin@fixture.invalid', 'admin', true)
on conflict (id) do update set role = 'admin', is_active = true;

insert into public.agents (id, code, official_name) values
  ('be000000-0000-0000-0000-0000000000a2', 'AGT-UB', 'وكيل الترقية')
on conflict (code) do nothing;

insert into public.packages (code, name, semantic_category) values
  ('UB-PKG', 'UB-PKG', 'PAID_PACKAGE')
on conflict (code) do nothing;

insert into public.saas_import_batches
  (id, source_kind, source_filename, source_checksum, parser_version, imported_by,
   completeness_status)
values ('be000000-0000-0000-0000-0000000000b1', 'ACTIVATION_EVENTS', 'ub.xlsx',
        'ck-ub', 'v1', 'be000000-0000-0000-0000-0000000000a1', 'COMPLETE')
on conflict do nothing;

insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, canceled, fdt_code)
values
  ('be000000-0000-0000-0000-0000000000b1', 'UB-EV-FRESH',  'ub-fresh',  'UB-PKG', false, '105'),
  ('be000000-0000-0000-0000-0000000000b1', 'UB-EV-P1',     'ub-p1',     'UB-PKG', false, '105'),
  ('be000000-0000-0000-0000-0000000000b1', 'UB-EV-P123',   'ub-p123',   'UB-PKG', false, '105'),
  ('be000000-0000-0000-0000-0000000000b1', 'UB-EV-BROKEN', 'ub-broken', 'UB-PKG', false, '105')
on conflict do nothing;

select v.id
from public.installation_scheme_versions v
join public.installation_fee_schemes s on s.id = v.scheme_id
where v.status = 'PUBLISHED' and s.is_active
order by v.effective_from desc nulls last, v.version desc limit 1
\gset ub_ver_

-- المال القديم: مدفوعٌ فعلاً، بلا حالة رسمية وبلا واقعة تاريخ.
select pg_temp.settle('ub-p1',   '2026-03', 'P1', 3000, 13000,
                      'be000000-0000-0000-0000-0000000000a1', 101);
select pg_temp.settle('ub-p123', '2026-01', 'P1', 3000, 13000,
                      'be000000-0000-0000-0000-0000000000a1', 102);
select pg_temp.settle('ub-p123', '2026-02', 'P2', 3000, 10000,
                      'be000000-0000-0000-0000-0000000000a1', 103);
select pg_temp.settle('ub-p123', '2026-03', 'P3', 3000,  7000,
                      'be000000-0000-0000-0000-0000000000a1', 104);
-- تاريخٌ مختلّ: P1 و P3 مدفوعتان و P2 لا. لا سلّم متّصل يفسّره.
select pg_temp.settle('ub-broken','2026-01', 'P1', 3000, 13000,
                      'be000000-0000-0000-0000-0000000000a1', 105);
select pg_temp.settle('ub-broken','2026-03', 'P3', 3000,  7000,
                      'be000000-0000-0000-0000-0000000000a1', 106);

select pg_temp.ok(
  (select count(*) from public.installation_payment_history) = 0
  and (select count(*) from public.installation_subscriber_state) = 0,
  '٠ · «ما قبل المهاجرة»: مالٌ مدفوع، بلا حالة رسمية وبلا واقعة تاريخ');

-- التسجيلات القديمة: تُدرَج والزنادُ معطَّل، تماماً كما كانت قبل الجسر.
alter table public.installation_enrollments disable trigger trg_installation_enrollment_opens_state;

insert into public.installation_enrollments
  (id, subscriber_id, scheme_version_id, origin, effective_agent_id, fdt_code, zone,
   current_stage_code, status, first_qualifying_event_id, enrolled_at, enrolled_by)
values
  ('be000000-0000-0000-0000-0000000000e1', 'ub-fresh',  :'ub_ver_id', 'NEW_INSTALLATION',
   'be000000-0000-0000-0000-0000000000a2', '105', 'new', 'P1', 'ACTIVE', 'UB-EV-FRESH',
   timestamptz '2026-01-05 09:00+03', 'be000000-0000-0000-0000-0000000000a1'),
  ('be000000-0000-0000-0000-0000000000e2', 'ub-p1',     :'ub_ver_id', 'NEW_INSTALLATION',
   'be000000-0000-0000-0000-0000000000a2', '105', 'new', 'P1', 'ACTIVE', 'UB-EV-P1',
   timestamptz '2026-01-05 09:00+03', 'be000000-0000-0000-0000-0000000000a1'),
  ('be000000-0000-0000-0000-0000000000e3', 'ub-p123',   :'ub_ver_id', 'NEW_INSTALLATION',
   'be000000-0000-0000-0000-0000000000a2', '105', 'new', 'P1', 'ACTIVE', 'UB-EV-P123',
   timestamptz '2026-01-05 09:00+03', 'be000000-0000-0000-0000-0000000000a1'),
  ('be000000-0000-0000-0000-0000000000e4', 'ub-broken', :'ub_ver_id', 'NEW_INSTALLATION',
   'be000000-0000-0000-0000-0000000000a2', '105', 'new', 'P1', 'ACTIVE', 'UB-EV-BROKEN',
   timestamptz '2026-01-05 09:00+03', 'be000000-0000-0000-0000-0000000000a1');

alter table public.installation_enrollments enable trigger trg_installation_enrollment_opens_state;

-- وهذه هي حلقة المهاجرة نفسها، بالدالة نفسها.
select public.ensure_installation_state_for_enrollment('be000000-0000-0000-0000-0000000000e1');
select public.ensure_installation_state_for_enrollment('be000000-0000-0000-0000-0000000000e2');
select public.ensure_installation_state_for_enrollment('be000000-0000-0000-0000-0000000000e3');
select public.ensure_installation_state_for_enrollment('be000000-0000-0000-0000-0000000000e4');

-- ===========================================================================
-- ١. تسجيل قديم بلا حالة وبلا دفع ⇒ افتتاحٌ آمن.
-- ===========================================================================

select pg_temp.ok(
  (select st.current_stage from public.installation_subscriber_state st
   join public.installation_subscribers s on s.id = st.subscriber_uuid
   where s.subscriber_id = 'ub-fresh') = 'P1'
  and (select st.remaining from public.installation_subscriber_state st
       join public.installation_subscribers s on s.id = st.subscriber_uuid
       where s.subscriber_id = 'ub-fresh') = 13000
  and (select st.received_total from public.installation_subscriber_state st
       join public.installation_subscribers s on s.id = st.subscriber_uuid
       where s.subscriber_id = 'ub-fresh') = 0,
  '١ · تسجيل قديم بلا مال يُفتح افتتاحاً نظيفاً: P1 / 13000 / مستلَم 0');

-- ===========================================================================
-- ٢. تسجيل قديم و P1 مدفوعة سلفاً ⇒ لا يُعاد إلى P1 أبداً.
-- ===========================================================================

select pg_temp.ok(
  (select st.current_stage from public.installation_subscriber_state st
   join public.installation_subscribers s on s.id = st.subscriber_uuid
   where s.subscriber_id = 'ub-p1') = 'P2',
  '٢ · مَن دُفعت له P1 لا يُفتح عند P1 — بل عند P2');

select pg_temp.ok(
  (select st.remaining from public.installation_subscriber_state st
   join public.installation_subscribers s on s.id = st.subscriber_uuid
   where s.subscriber_id = 'ub-p1') = 10000
  and (select st.received_total from public.installation_subscriber_state st
       join public.installation_subscribers s on s.id = st.subscriber_uuid
       where s.subscriber_id = 'ub-p1') = 3000
  and (select st.total_amount from public.installation_subscriber_state st
       join public.installation_subscribers s on s.id = st.subscriber_uuid
       where s.subscriber_id = 'ub-p1') = 13000,
  '  · والمتبقي 10000 والمستلَم 3000 — الهوية المحاسبية متّزنة');

select pg_temp.ok(
  (select e.current_stage_code from public.installation_enrollments e
   where e.subscriber_id = 'ub-p1') = 'P2',
  '  · ومرحلة التسجيل تتبع الحالة، وإلا منع STAGE_OUT_OF_SEQUENCE كل دفعةٍ تالية');

-- الحماية الرجعية: المرحلة المدفوعة قبل الترقية صارت واقعةً مسجَّلة، فلا
-- تُدفع ثانيةً في أي فترة.
select pg_temp.ok(
  (select count(*) from public.installation_payment_history h
   join public.installation_subscribers s on s.id = h.subscriber_uuid
   where s.subscriber_id = 'ub-p1' and h.stage = 'P1') = 1,
  '  · والمدفوع قبل الترقية أُثبت واقعةً — الحماية رجعيّة لا مستقبلية فقط');

insert into public.installation_entitlements
  (id, period, subscriber_id, subscriber_name, reseller, fdt, remaining, stage, amount,
   invoice_status, payment_status, created_by)
values ('be000000-0000-0000-0000-0000000000d1', '2026-09', 'ub-p1', 'ub-p1',
        'وكيل الترقية', '105', 13000, 'P1', 3000, 'approved', 'eligible',
        'be000000-0000-0000-0000-0000000000a1');

set local role authenticated;
set local request.jwt.claim.sub = 'be000000-0000-0000-0000-0000000000a1';

select pg_temp.must_fail_with(
  $q$select public.record_installation_payment(
       'be000000-0000-0000-0000-0000000000d1', null, gen_random_uuid())$q$,
  '  · فمحاولة صرف P1 ثانيةً بعد الترقية تسقط ذرّياً',
  'STAGE_ALREADY_PAID');

reset role;

-- ===========================================================================
-- ٣. تسجيل قديم بمراحل متعدّدة مدفوعة ⇒ المصالحة إلى الموضع الصحيح.
-- ===========================================================================

select pg_temp.ok(
  (select st.current_stage from public.installation_subscriber_state st
   join public.installation_subscribers s on s.id = st.subscriber_uuid
   where s.subscriber_id = 'ub-p123') = 'P4'
  and (select st.remaining from public.installation_subscriber_state st
       join public.installation_subscribers s on s.id = st.subscriber_uuid
       where s.subscriber_id = 'ub-p123') = 4000
  and (select st.received_total from public.installation_subscriber_state st
       join public.installation_subscribers s on s.id = st.subscriber_uuid
       where s.subscriber_id = 'ub-p123') = 9000,
  '٣ · ثلاث مراحل مدفوعة ⇒ الموضع P4 / 4000 / مستلَم 9000');

select pg_temp.ok(
  (select count(*) from public.installation_payment_history h
   join public.installation_subscribers s on s.id = h.subscriber_uuid
   where s.subscriber_id = 'ub-p123') = 3
  and (select coalesce(sum(h.amount), 0) from public.installation_payment_history h
       join public.installation_subscribers s on s.id = h.subscriber_uuid
       where s.subscriber_id = 'ub-p123') = 9000,
  '  · وثلاث وقائع بمجموع 9000 — لا واحدة زائدة ولا ناقصة');

select pg_temp.ok(
  (select st.payment_eligible from public.installation_subscriber_state st
   join public.installation_subscribers s on s.id = st.subscriber_uuid
   where s.subscriber_id = 'ub-p123') is true,
  '  · وهو مؤهَّل لصرف P4 — المصالحة لا تحجب مالاً مستحقاً');

-- ===========================================================================
-- ٤. تاريخ مالي مختلّ ⇒ لا تخمين: حالة مراجعة صريحة.
-- ===========================================================================

select pg_temp.ok(
  (select st.resolution from public.installation_subscriber_state st
   join public.installation_subscribers s on s.id = st.subscriber_uuid
   where s.subscriber_id = 'ub-broken') = 'unresolved'
  and (select st.current_stage from public.installation_subscriber_state st
       join public.installation_subscribers s on s.id = st.subscriber_uuid
       where s.subscriber_id = 'ub-broken') is null
  and (select st.remaining from public.installation_subscriber_state st
       join public.installation_subscribers s on s.id = st.subscriber_uuid
       where s.subscriber_id = 'ub-broken') is null,
  '٤ · P1 و P3 بلا P2 ⇒ لا مرحلة ولا متبقٍّ مخمَّن');

select pg_temp.ok(
  (select st.payment_eligible from public.installation_subscriber_state st
   join public.installation_subscribers s on s.id = st.subscriber_uuid
   where s.subscriber_id = 'ub-broken') is false
  and exists (select 1 from public.installation_subscriber_state st
              join public.installation_subscribers s on s.id = st.subscriber_uuid
              where s.subscriber_id = 'ub-broken'
                and 'NEEDS_REVIEW:NON_CONTIGUOUS_PAID_STAGES' = any(st.warnings)),
  '  · ولا أهلية صرف، والسبب مكتوب في الصفّ نفسه');

select pg_temp.ok(
  (public.materialize_installation_entitlements('2026-09', null, 500,
     'be000000-0000-0000-0000-00000000f001') is not null)
  and not exists (
    select 1 from public.installation_entitlements
    where subscriber_id = 'ub-broken' and period = '2026-09'),
  '  · والتثبيت الشهري يتخطّاه — لا يُصرف على تاريخٍ مشكوك فيه');

-- ===========================================================================
-- ٥. الصفوف المالية المكتملة لا تُمسّ.
-- ===========================================================================

select pg_temp.ok(
  (select count(*) from public.installation_entitlements
   where subscriber_id like 'ub-%' and payment_status = 'paid') = 6
  and (select coalesce(sum(paid_amount), 0) from public.installation_entitlements
       where subscriber_id like 'ub-%' and payment_status = 'paid') = 18000,
  '٥ · ستّة استحقاقات مدفوعة بمجموع 18000 كما كانت قبل الترقية');

select pg_temp.ok(
  (select count(*) from public.installation_payments p
   join public.installation_entitlements e on e.id = p.entitlement_id
   where e.subscriber_id like 'ub-%') = 6
  and (select count(*) from public.financial_ledger
       where subscriber_id like 'ub-%' and txn_type = 'PAYMENT') = 6,
  '  · وستّ دفعات وستّة قيود — الترقية لم تكتب قرشاً ولم تمحُ قرشاً');

select pg_temp.ok(
  not exists (select 1 from public.installation_entitlements
              where subscriber_id like 'ub-%' and payment_status = 'paid'
                and paid_amount is distinct from amount),
  '  · وكل مدفوعٍ لا يزال مطابقاً لمبلغه المرصود');

rollback;
