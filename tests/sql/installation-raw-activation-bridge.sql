-- جسر التفعيل الخام → الحالة الرسمية → المرحلة المشتقّة → الاستحقاق،
-- وتقدّم المراحل بالدفع (INS-012 … INS-016).
--
-- ما تُثبته هذه الرحلة أنّ المشغّل لا يصنع عمود Remaining شهرياً: الملف الخام
-- لا يحمل هذا العمود أصلاً — يُبرهَن هنا على الصفّ نفسه لا بالادّعاء — والخادم
-- يشتقّ المتبقي والمرحلة من الحالة الرسمية والإصدار المنشور.
--
-- وتُثبت أنّ P1 → P2 → P3 → P4 → DONE يحدث فعلاً، مرّةً واحدة لكل مرحلة، وأنّ
-- الإعادة بكل أشكالها (نفس الحدث، نفس الملف، نفس الطلب، استحقاق ثانٍ لنفس
-- المرحلة في شهر آخر، محاولتان متزامنتان) لا تُقدّم أحداً مرّتين.
--
-- وأنّ الاشتقاق لا يمنح سلطة دفع: بلا فاتورة مُتحقَّقة، أو مع تعليق، أو مع
-- تعارض هوية، أو بلا عائدية وكيل — لا استحقاق ولا صرف.
--
-- كل شيء داخل معاملةٍ تُلغى. معزول بنطاق تسمية rb-.

\set ON_ERROR_STOP on
\pset tuples_only on

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns text language sql as $$
  select case when p_cond then '   ok ' || p_label else 'FAILED: ' || p_label end;
$$;

create or replace function pg_temp.must_fail(p_sql text, p_label text)
returns text language plpgsql as $$
begin
  execute p_sql;
  return 'FAILED: ' || p_label || ' — مرّ وكان يجب أن يُرفض';
exception when others then return '   ok ' || p_label;
end;
$$;

-- الرفض بسببه المعلن، لا بأي سبب. رسالة الخطأ جزء من العقد هنا.
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

-- خطوة كاملة على السلّم: فاتورة مُتحقَّقة للمرحلة، ثم تثبيت الشهر، ثم الصرف.
-- لا Remaining يُمرَّر في أي منها: التوقيع نفسه لا يقبله.
create or replace function pg_temp.advance(
  p_sub text, p_period text, p_stage text, p_n integer)
returns boolean language plpgsql as $$
declare
  v_ent uuid;
begin
  perform public.review_invoice(
    p_sub, p_stage, 'VERIFIED', 'مطابقة', 'RB-INV-' || p_sub || '-' || p_stage,
    ('bd000000-0000-0000-0000-' || lpad((p_n * 10 + 1)::text, 12, '0'))::uuid);
  perform public.materialize_installation_entitlements(
    p_period, null, 500,
    ('bd000000-0000-0000-0000-' || lpad((p_n * 10 + 2)::text, 12, '0'))::uuid);
  select id into v_ent from public.installation_entitlements
  where subscriber_id = p_sub and period = p_period and stage = p_stage;
  if v_ent is null then
    return false;
  end if;
  perform public.record_installation_payment(
    v_ent, null,
    ('bd000000-0000-0000-0000-' || lpad((p_n * 10 + 3)::text, 12, '0'))::uuid);
  return true;
end;
$$;

begin;

select '   == installation raw activation bridge ==';

-- ===========================================================================
-- التهيئة. لا صفّ منها يحمل Remaining إلا الأساس التاريخي وحده (INS-012).
-- ===========================================================================

insert into auth.users (id, email) values
  ('bd000000-0000-0000-0000-0000000000a1', 'rb-admin@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active) values
  ('bd000000-0000-0000-0000-0000000000a1', 'RB-AD', 'rb-admin@fixture.invalid', 'admin', true)
on conflict (id) do update set role = 'admin', is_active = true;

insert into public.agents (id, code, official_name) values
  ('bd000000-0000-0000-0000-0000000000a2', 'AGT-RB', 'وكيل الجسر')
on conflict (code) do nothing;

insert into public.agent_aliases (agent_id, alias, resolution) values
  ('bd000000-0000-0000-0000-0000000000a2', 'rb.raw.agent', 'mapped')
on conflict (alias_key) do nothing;

insert into public.packages (code, name, semantic_category) values
  ('RB-PKG', 'RB-PKG', 'PAID_PACKAGE')
on conflict (code) do nothing;

insert into public.saas_import_batches
  (id, source_kind, source_filename, source_checksum, parser_version, imported_by,
   completeness_status)
values ('bd000000-0000-0000-0000-0000000000b1', 'ACTIVATION_EVENTS', 'rb-july.xlsx',
        'ck-rb', 'v1', 'bd000000-0000-0000-0000-0000000000a1', 'COMPLETE')
on conflict do nothing;

-- الملف الخام: أحداث تفعيل عادية، بلا أي عمود متبقٍّ.
insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, canceled, raw_parent, fdt_code)
values
  ('bd000000-0000-0000-0000-0000000000b1', 'RB-EV-NEW', 'rb-new', 'RB-PKG', false, 'rb.raw.agent', '105'),
  ('bd000000-0000-0000-0000-0000000000b1', 'RB-EV-MID', 'rb-mid', 'RB-PKG', false, 'rb.raw.agent', '105'),
  ('bd000000-0000-0000-0000-0000000000b1', 'RB-EV-CLASH', 'rb-clash', 'RB-PKG', false, 'rb.raw.agent', '105')
on conflict do nothing;

insert into public.subscriber_identities
  (username, identity_status, match_method, source_classification, effective_agent_id, fdt_code)
values
  ('rb-new',   'MATCHED', 'EXACT_USERNAME', 'RESELLER', 'bd000000-0000-0000-0000-0000000000a2', '105'),
  ('rb-mid',   'MATCHED', 'EXACT_USERNAME', 'RESELLER', 'bd000000-0000-0000-0000-0000000000a2', '105'),
  ('rb-hist',  'MATCHED', 'EXACT_USERNAME', 'RESELLER', 'bd000000-0000-0000-0000-0000000000a2', '105'),
  ('rb-noinv', 'MATCHED', 'EXACT_USERNAME', 'RESELLER', 'bd000000-0000-0000-0000-0000000000a2', '105'),
  ('rb-held',  'MATCHED', 'EXACT_USERNAME', 'RESELLER', 'bd000000-0000-0000-0000-0000000000a2', '105'),
  ('rb-clash', 'CONFLICT', 'EXACT_USERNAME', 'RESELLER', 'bd000000-0000-0000-0000-0000000000a2', '105'),
  ('rb-direct','MATCHED', 'EXACT_USERNAME', 'DIRECT_COMPANY', 'bd000000-0000-0000-0000-0000000000a2', '105')
on conflict do nothing;

insert into public.subscriber_classifications
  (username_key, classification, reason_code, source_completeness)
values ('rb-new', 'NEW', 'COMPLETE_LIFETIME_HISTORY_OBSERVED', 'COMPLETE')
on conflict do nothing;

-- الأساس التاريخي (INS-012): السلطة الافتتاحية الوحيدة التي تحمل Remaining.
insert into public.installation_subscribers
  (id, subscriber_id, reseller, fdt, start_date, total_amount, created_by)
values
  ('bd000000-0000-0000-0000-0000000000c1','rb-hist','وكيل الجسر','105', date '2026-01-01', 13000,'bd000000-0000-0000-0000-0000000000a1'),
  ('bd000000-0000-0000-0000-0000000000c2','rb-mid','وكيل الجسر','105', date '2026-01-01', 13000,'bd000000-0000-0000-0000-0000000000a1'),
  ('bd000000-0000-0000-0000-0000000000c3','rb-noinv','وكيل الجسر','105', date '2026-01-01', 13000,'bd000000-0000-0000-0000-0000000000a1'),
  ('bd000000-0000-0000-0000-0000000000c4','rb-held','وكيل الجسر','105', date '2026-01-01', 13000,'bd000000-0000-0000-0000-0000000000a1'),
  ('bd000000-0000-0000-0000-0000000000c5','rb-clash','وكيل الجسر','105', date '2026-01-01', 13000,'bd000000-0000-0000-0000-0000000000a1'),
  ('bd000000-0000-0000-0000-0000000000c6','rb-direct','وكيل الجسر','105', date '2026-01-01', 13000,'bd000000-0000-0000-0000-0000000000a1')
on conflict do nothing;

insert into public.installation_subscriber_state
  (subscriber_uuid, as_of_date, remaining, received_total, total_amount,
   current_stage, resolution, payment_eligible)
values
  ('bd000000-0000-0000-0000-0000000000c1', date '2026-06-30', 13000,     0, 13000, 'P1', 'resolved', true),
  ('bd000000-0000-0000-0000-0000000000c2', date '2026-06-30',  7000,  6000, 13000, 'P3', 'resolved', true),
  ('bd000000-0000-0000-0000-0000000000c3', date '2026-06-30', 13000,     0, 13000, 'P1', 'resolved', true),
  ('bd000000-0000-0000-0000-0000000000c4', date '2026-06-30', 13000,     0, 13000, 'P1', 'resolved', true),
  ('bd000000-0000-0000-0000-0000000000c5', date '2026-06-30', 13000,     0, 13000, 'P1', 'resolved', true),
  ('bd000000-0000-0000-0000-0000000000c6', date '2026-06-30', 13000,     0, 13000, 'P1', 'resolved', true)
on conflict (subscriber_uuid) do nothing;

insert into public.subscriber_ownership
  (username_key, ownership_type, agent_id, effective_from, reason, performed_by)
values
  ('rb-new','RESELLER','bd000000-0000-0000-0000-0000000000a2',
   timestamptz '2026-01-01 00:00+03','تثبيت','bd000000-0000-0000-0000-0000000000a1'),
  ('rb-hist','RESELLER','bd000000-0000-0000-0000-0000000000a2',
   timestamptz '2026-01-01 00:00+03','تثبيت','bd000000-0000-0000-0000-0000000000a1'),
  ('rb-mid','RESELLER','bd000000-0000-0000-0000-0000000000a2',
   timestamptz '2026-01-01 00:00+03','تثبيت','bd000000-0000-0000-0000-0000000000a1'),
  ('rb-noinv','RESELLER','bd000000-0000-0000-0000-0000000000a2',
   timestamptz '2026-01-01 00:00+03','تثبيت','bd000000-0000-0000-0000-0000000000a1'),
  ('rb-held','RESELLER','bd000000-0000-0000-0000-0000000000a2',
   timestamptz '2026-01-01 00:00+03','تثبيت','bd000000-0000-0000-0000-0000000000a1'),
  ('rb-clash','RESELLER','bd000000-0000-0000-0000-0000000000a2',
   timestamptz '2026-01-01 00:00+03','تثبيت','bd000000-0000-0000-0000-0000000000a1')
on conflict do nothing;

set local role authenticated;
set local request.jwt.claim.sub = 'bd000000-0000-0000-0000-0000000000a1';

-- ===========================================================================
-- ١. الملف الخام لا يحمل Remaining — على الصفّ نفسه (INS-013).
-- ===========================================================================

select pg_temp.ok(
  not (to_jsonb((select e from public.saas_activation_events e
                 where e.saas_event_id = 'RB-EV-NEW')) ? 'remaining')
  and not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'saas_activation_events'
      and column_name ilike '%remain%'),
  '١ · حدث التفعيل الخام لا يحمل عمود Remaining إطلاقاً');

-- ===========================================================================
-- ٢. الأساس التاريخي 13000/P1 + المسار الشهري الخام ⇒ P1 = 3000 (INS-012/014).
-- ===========================================================================

select pg_temp.ok(
  (select remaining from public.installation_subscriber_state
   where subscriber_uuid = 'bd000000-0000-0000-0000-0000000000c1') = 13000
  and (select current_stage from public.installation_subscriber_state
       where subscriber_uuid = 'bd000000-0000-0000-0000-0000000000c1') = 'P1',
  '٢ · الأساس التاريخي هو السلطة الافتتاحية: 13000 / P1');

select public.review_invoice('rb-hist', 'P1', 'VERIFIED', 'مطابقة', 'RB-INV-HIST-P1',
  'bd000000-0000-0000-0000-00000000f001');

select pg_temp.ok(
  (public.materialize_installation_entitlements('2026-07', null, 500,
     'bd000000-0000-0000-0000-00000000f002') ->> 'created')::int >= 1,
  '  · والتثبيت الشهري يشتقّ الاستحقاق بلا أي Remaining من المُرسِل');

select pg_temp.ok(
  (select amount from public.installation_entitlements
   where subscriber_id = 'rb-hist' and period = '2026-07') = 3000
  and (select stage from public.installation_entitlements
       where subscriber_id = 'rb-hist' and period = '2026-07') = 'P1'
  and (select remaining from public.installation_entitlements
       where subscriber_id = 'rb-hist' and period = '2026-07') = 13000,
  '  · P1 بثلاثة آلاف، والمتبقي والمرحلة مشتقّان على الخادم');

-- ===========================================================================
-- ٣. التفعيل الخام وحده يفتح حالةً رسمية لمشترك لا أساس تاريخي له (INS-013).
-- ===========================================================================

select pg_temp.ok(
  not exists (select 1 from public.installation_subscribers where subscriber_id = 'rb-new'),
  '٣ · قبل التسجيل: لا سجلّ مشترك ولا حالة لمن عُرف بالتفعيل وحده');

-- المسح الجماعي على دفعة الاستيراد نفسها: لا enroll_new_installation بيد
-- المشغّل، ولا اسم مشترك يُكتب في أي استدعاء. هذا هو المسار الشهري العادي.
select pg_temp.ok(
  (public.bridge_saas_activations_to_enrollments(
     'bd000000-0000-0000-0000-0000000000b1', 500,
     'bd000000-0000-0000-0000-00000000f003') #>> '{result,enrolled}')::int = 1,
  '  · مسحُ الدفعة الخام يُسجّل المؤهَّل وحده — بلا استدعاءٍ فرديّ');

select pg_temp.ok(
  (select count(*) from public.installation_subscribers where subscriber_id = 'rb-new') = 1,
  '  · التسجيل من الحدث الخام يفتح سجلّ المشترك');

select pg_temp.ok(
  (select st.remaining from public.installation_subscriber_state st
   join public.installation_subscribers s on s.id = st.subscriber_uuid
   where s.subscriber_id = 'rb-new') = 13000
  and (select st.current_stage from public.installation_subscriber_state st
       join public.installation_subscribers s on s.id = st.subscriber_uuid
       where s.subscriber_id = 'rb-new') = 'P1'
  and (select st.received_total from public.installation_subscriber_state st
       join public.installation_subscribers s on s.id = st.subscriber_uuid
       where s.subscriber_id = 'rb-new') = 0,
  '  · وحالةً افتتاحية 13000 / P1 من الإصدار المنشور لا من ملفّ');

-- والمتبقي جاء من التهيئة لا من رقمٍ في الكود.
select pg_temp.ok(
  (select d.expected_remaining
   from public.installation_stage_definitions d
   join public.installation_enrollments e on e.scheme_version_id = d.scheme_version_id
   where e.subscriber_id = 'rb-new' and d.code = 'P1') = 13000,
  '  · والرقم مصدره installation_stage_definitions لا الكود');

-- ===========================================================================
-- ٤. المشترك المفتوح من التفعيل الخام يصل إلى استحقاقٍ حقيقي (INS-014).
-- ===========================================================================

select pg_temp.ok(
  pg_temp.advance('rb-new', '2026-07', 'P1', 11),
  '٤ · فاتورة مُتحقَّقة ⇒ استحقاق ⇒ صرف، بلا Remaining في أي خطوة');

select pg_temp.ok(
  (select amount from public.installation_entitlements
   where subscriber_id = 'rb-new' and period = '2026-07') = 3000,
  '  · والمبلغ 3000 للمرحلة P1');

-- ===========================================================================
-- ٥. الدفع يُقدّم المرحلة مرّةً واحدة، وواقعةً مالية مسجَّلة (INS-015).
-- ===========================================================================

select pg_temp.ok(
  (select st.remaining from public.installation_subscriber_state st
   join public.installation_subscribers s on s.id = st.subscriber_uuid
   where s.subscriber_id = 'rb-new') = 10000
  and (select st.current_stage from public.installation_subscriber_state st
       join public.installation_subscribers s on s.id = st.subscriber_uuid
       where s.subscriber_id = 'rb-new') = 'P2',
  '٥ · بعد صرف P1 تتقدّم الحالة خطوةً واحدة إلى P2 / 10000');

select pg_temp.ok(
  (select count(*) from public.installation_payment_history h
   join public.installation_subscribers s on s.id = h.subscriber_uuid
   where s.subscriber_id = 'rb-new') = 1
  and (select h.stage from public.installation_payment_history h
       join public.installation_subscribers s on s.id = h.subscriber_uuid
       where s.subscriber_id = 'rb-new') = 'P1',
  '  · والتقدّم تاريخٌ ماليّ مسجَّل: واقعة واحدة للمرحلة P1');

select pg_temp.ok(
  exists (select 1 from public.audit_logs
          where action = 'installation.stage.advanced'
            and old_value = 'P1' and new_value = 'P2'),
  '  · ومُدقَّق: من P1 إلى P2');

-- التسجيل يتبع الحالة الرسمية ولا ينافسها.
select pg_temp.ok(
  (select current_stage_code from public.installation_enrollments
   where subscriber_id = 'rb-new') = 'P2',
  '  · ومرحلة التسجيل تتبع الحالة الرسمية، لا محرّك موازٍ');

-- ===========================================================================
-- ٦. السلّم كاملاً: P1 → P2 → P3 → P4 → DONE، والمجموع 13000 بالضبط.
-- ===========================================================================

select pg_temp.ok(pg_temp.advance('rb-new', '2026-08', 'P2', 12), '٦ · P2 تُصرف');
select pg_temp.ok(pg_temp.advance('rb-new', '2026-09', 'P3', 13), '  · P3 تُصرف');
select pg_temp.ok(pg_temp.advance('rb-new', '2026-10', 'P4', 14), '  · P4 تُصرف');

select pg_temp.ok(
  (select st.remaining from public.installation_subscriber_state st
   join public.installation_subscribers s on s.id = st.subscriber_uuid
   where s.subscriber_id = 'rb-new') = 0
  and (select st.current_stage from public.installation_subscriber_state st
       join public.installation_subscribers s on s.id = st.subscriber_uuid
       where s.subscriber_id = 'rb-new') = 'DONE',
  '  · وينتهي عند DONE بمتبقٍّ صفر');

select pg_temp.ok(
  (select coalesce(sum(h.amount), 0) from public.installation_payment_history h
   join public.installation_subscribers s on s.id = h.subscriber_uuid
   where s.subscriber_id = 'rb-new') = 13000
  and (select count(*) from public.installation_payment_history h
       join public.installation_subscribers s on s.id = h.subscriber_uuid
       where s.subscriber_id = 'rb-new') = 4,
  '  · أربع وقائع مجموعها 13000 — لا زيادة ولا نقصان');

select pg_temp.ok(
  (select st.payment_eligible from public.installation_subscriber_state st
   join public.installation_subscribers s on s.id = st.subscriber_uuid
   where s.subscriber_id = 'rb-new') = false,
  '  · والمنتهي لم يعد مؤهَّلاً للصرف');

-- ===========================================================================
-- ٧. DONE نهاية: لا تقدّم بعدها ولا التزام (INS-015).
-- ===========================================================================

select pg_temp.ok(
  (public.materialize_installation_entitlements('2026-11', null, 500,
     'bd000000-0000-0000-0000-00000000f004') ->> 'created')::int = 0
  or not exists (select 1 from public.installation_entitlements
                 where subscriber_id = 'rb-new' and period = '2026-11'),
  '٧ · بعد DONE لا يُثبَّت التزامٌ جديد');

select pg_temp.ok(
  (select count(*) from public.installation_payment_history h
   join public.installation_subscribers s on s.id = h.subscriber_uuid
   where s.subscriber_id = 'rb-new') = 4,
  '  · ولا واقعة خامسة');

-- ===========================================================================
-- ٨. المشترك التاريخي يستأنف من مرحلته، ولا يُعاد إلى P1 (INS-012).
-- ===========================================================================

select v.id from public.installation_scheme_versions v
join public.installation_fee_schemes s on s.id = v.scheme_id
where v.status = 'PUBLISHED' and s.is_active
order by v.effective_from desc nulls last, v.version desc limit 1
\gset rb_ver_

reset role;

insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, canceled, raw_parent, fdt_code)
values ('bd000000-0000-0000-0000-0000000000b1', 'RB-EV-MID2', 'rb-mid', 'RB-PKG',
        false, 'rb.raw.agent', '105')
on conflict do nothing;

insert into public.installation_enrollments
  (subscriber_id, scheme_version_id, origin, effective_agent_id, fdt_code, zone,
   current_stage_code, status, first_qualifying_event_id, enrolled_by)
values ('rb-mid', :'rb_ver_id', 'NEW_INSTALLATION',
        'bd000000-0000-0000-0000-0000000000a2', '105', 'new', 'P1', 'ACTIVE',
        'RB-EV-MID2', 'bd000000-0000-0000-0000-0000000000a1');

set local role authenticated;
set local request.jwt.claim.sub = 'bd000000-0000-0000-0000-0000000000a1';

select pg_temp.ok(
  (select remaining from public.installation_subscriber_state
   where subscriber_uuid = 'bd000000-0000-0000-0000-0000000000c2') = 7000
  and (select current_stage from public.installation_subscriber_state
       where subscriber_uuid = 'bd000000-0000-0000-0000-0000000000c2') = 'P3'
  and (select received_total from public.installation_subscriber_state
       where subscriber_uuid = 'bd000000-0000-0000-0000-0000000000c2') = 6000,
  '٨ · تفعيلٌ خام لمشتركٍ له حالة لا يُعيده إلى P1 — يبقى 7000 / P3');

select pg_temp.ok(
  (select count(*) from public.installation_subscribers where subscriber_id = 'rb-mid') = 1,
  '  · ولا يُنشئ له سجلّ مشتركٍ ثانياً');

-- ===========================================================================
-- ٩. الإعادة بكل أشكالها لا تُقدّم مرّتين (INS-015).
-- ===========================================================================

-- (أ) نفس حدث التفعيل.
select pg_temp.must_fail(
  $q$select public.enroll_new_installation(
       'rb-new', 'RB-EV-NEW', null, 'bd000000-0000-0000-0000-00000000f005')$q$,
  '٩ · إعادة نفس حدث التفعيل تُرفض');

-- (ب) نفس الملف الخام: الحدث مفتاحه الفريد، فلا صفّ جديد.
reset role;

insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, canceled, raw_parent, fdt_code)
values ('bd000000-0000-0000-0000-0000000000b1', 'RB-EV-NEW', 'rb-new', 'RB-PKG',
        false, 'rb.raw.agent', '105')
on conflict (saas_event_id) do nothing;

set local role authenticated;
set local request.jwt.claim.sub = 'bd000000-0000-0000-0000-0000000000a1';

select pg_temp.ok(
  (select count(*) from public.saas_activation_events where saas_event_id = 'RB-EV-NEW') = 1
  and (select count(*) from public.installation_payment_history h
       join public.installation_subscribers s on s.id = h.subscriber_uuid
       where s.subscriber_id = 'rb-new') = 4,
  '  · إعادة استيراد نفس الملف لا تُضيف حدثاً ولا تُقدّم أحداً');

-- (ج) نفس معرّف الطلب — إعادة المتصفّح أو الطلب.
select pg_temp.ok(
  (public.materialize_installation_entitlements('2026-08', null, 500,
     'bd000000-0000-0000-0000-000000000122') ->> 'idempotent')::boolean = true,
  '  · إعادة نفس معرّف الطلب للتثبيت بلا أثر ثانٍ');

-- (د) الأخطر: استحقاقٌ ثانٍ لنفس (المشترك، المرحلة) في شهرٍ آخر.
--     مفتاح installation_payments الفريد لا يمنعه — يمنعه سجلّ التاريخ وحده.
reset role;

insert into public.installation_entitlements
  (id, period, subscriber_id, subscriber_name, reseller, fdt, remaining, stage, amount,
   invoice_status, payment_status, created_by)
values ('bd000000-0000-0000-0000-0000000000e1', '2026-12', 'rb-hist', 'rb-hist',
        'وكيل الجسر', '105', 13000, 'P1', 3000, 'approved', 'eligible',
        'bd000000-0000-0000-0000-0000000000a1');

set local role authenticated;
set local request.jwt.claim.sub = 'bd000000-0000-0000-0000-0000000000a1';

select pg_temp.ok(pg_temp.advance('rb-hist', '2026-07', 'P1', 15),
  '  · صرف P1 التاريخي مرّةً أولى');

select pg_temp.ok(
  (select remaining from public.installation_subscriber_state
   where subscriber_uuid = 'bd000000-0000-0000-0000-0000000000c1') = 10000
  and (select current_stage from public.installation_subscriber_state
       where subscriber_uuid = 'bd000000-0000-0000-0000-0000000000c1') = 'P2',
  '  · فتقدّم إلى P2 / 10000');

-- المطلوب ليس «لا يتقدّم مرّتين» بل «لا يُدفع مرّتين»: المحاولة تسقط ذرّياً
-- قبل installation_payments وقبل financial_ledger وقبل تحوّل الاستحقاق وقبل
-- تدقيق النجاح.
select pg_temp.must_fail_with(
  $q$select public.record_installation_payment(
       'bd000000-0000-0000-0000-0000000000e1', null,
       'bd000000-0000-0000-0000-00000000f006')$q$,
  '  · واستحقاقٌ ثانٍ لنفس المرحلة في شهرٍ آخر يُرفض صرفه',
  'STAGE_ALREADY_PAID');

select pg_temp.ok(
  (select count(*) from public.installation_payments
   where entitlement_id = 'bd000000-0000-0000-0000-0000000000e1') = 0
  and (select payment_status from public.installation_entitlements
       where id = 'bd000000-0000-0000-0000-0000000000e1') = 'eligible'
  and (select paid_amount from public.installation_entitlements
       where id = 'bd000000-0000-0000-0000-0000000000e1') = 0,
  '  · ولا دفعة ولا تحوّل إلى «مدفوع» على الاستحقاق المرفوض');

select pg_temp.ok(
  (select count(*) from public.financial_ledger
   where source_id = 'bd000000-0000-0000-0000-0000000000e1'
     and txn_type = 'PAYMENT') = 0
  and (select count(*) from public.audit_logs
       where request_id = 'bd000000-0000-0000-0000-00000000f006') = 0,
  '  · ولا قيد مالي ولا تدقيق نجاحٍ للمحاولة المرفوضة');

select pg_temp.ok(
  (select remaining from public.installation_subscriber_state
   where subscriber_uuid = 'bd000000-0000-0000-0000-0000000000c1') = 10000
  and (select current_stage from public.installation_subscriber_state
       where subscriber_uuid = 'bd000000-0000-0000-0000-0000000000c1') = 'P2'
  and (select count(*) from public.installation_payment_history
       where subscriber_uuid = 'bd000000-0000-0000-0000-0000000000c1') = 1,
  '  · والحالة والواقعة كما كانتا: خطوة واحدة، مرّة واحدة');

-- (هـ) محاولتان متزامنتان: المفتاح الفريد يمنع الالتزام المكرَّر أصلاً.
select pg_temp.must_fail(
  $q$insert into public.installation_entitlements
       (period, subscriber_id, subscriber_name, reseller, fdt, remaining, stage,
        amount, created_by)
     values ('2026-07', 'rb-hist', 'rb-hist', 'وكيل الجسر', '105', 13000, 'P1', 3000,
             'bd000000-0000-0000-0000-0000000000a1')$q$,
  '  · التزامان متزامنان لنفس (الشهر، المشترك، المرحلة) مستحيلان');

select pg_temp.must_fail(
  $q$insert into public.installation_payment_history
       (subscriber_uuid, stage, amount, created_by)
     values ('bd000000-0000-0000-0000-0000000000c1', 'P1', 3000,
             'bd000000-0000-0000-0000-0000000000a1')$q$,
  '  · وواقعتا تقدّمٍ لنفس (المشترك، المرحلة) مستحيلتان');

-- ===========================================================================
-- ١٠. الاشتقاق لا يتجاوز ضوابط الفاتورة ولا الحجب (INS-016).
-- ===========================================================================

select pg_temp.ok(
  not exists (select 1 from public.installation_entitlements
              where subscriber_id = 'rb-noinv'),
  '١٠ · بلا فاتورة مُتحقَّقة لا التزام ولا صرف');

select public.review_invoice('rb-held', 'P1', 'VERIFIED', 'مطابقة', 'RB-INV-HELD-P1',
  'bd000000-0000-0000-0000-00000000f007');
select public.place_hold_v2('rb-held', 'TEMPORARY', 'MANUAL_REVIEW',
  'قيد التحقيق', null, null, 'bd000000-0000-0000-0000-00000000f008');
select public.review_invoice('rb-clash', 'P1', 'VERIFIED', 'مطابقة', 'RB-INV-CLASH-P1',
  'bd000000-0000-0000-0000-00000000f009');

select public.materialize_installation_entitlements('2026-07', null, 500,
  'bd000000-0000-0000-0000-00000000f00a');

select pg_temp.ok(
  not exists (select 1 from public.installation_entitlements where subscriber_id = 'rb-held'),
  '  · والمعلَّق محجوب رغم فاتورته المتحقَّقة');

select pg_temp.ok(
  not exists (select 1 from public.installation_entitlements where subscriber_id = 'rb-clash'),
  '  · وتعارض الهوية يحجب رغم الفاتورة');

select pg_temp.ok(
  not exists (select 1 from public.installation_entitlements where subscriber_id = 'rb-direct'),
  '  · ومن ليست عائديته وكيلاً محجوب');

-- ===========================================================================
-- ١١. التاريخ المدفوع والدفتر لا يُعاد كتابتهما (INS-015).
-- ===========================================================================

select pg_temp.must_fail(
  $q$update public.installation_entitlements set amount = 9999
     where subscriber_id = 'rb-new' and period = '2026-07'$q$,
  '١١ · الاستحقاق المدفوع لا يُعاد تسعيره');

select pg_temp.must_fail(
  $q$update public.installation_payment_history set amount = 1
     where subscriber_uuid = 'bd000000-0000-0000-0000-0000000000c2'$q$,
  '  · وواقعة تاريخية مستوردة لا تُعاد كتابتها بمبلغٍ غير مقبول');

select pg_temp.ok(
  (select count(*) from public.financial_ledger
   where domain = 'installation' and subscriber_id = 'rb-new') = 4
  and (select coalesce(sum(amount), 0) from public.financial_ledger
       where domain = 'installation' and subscriber_id = 'rb-new') = 13000,
  '  · والدفتر يحمل أربعة قيود مجموعها 13000، لا أكثر');

-- ===========================================================================
-- ١٢. التنصيب والعمولة مفصولان مالياً (INS-016).
-- ===========================================================================

select pg_temp.ok(
  not exists (select 1 from public.financial_ledger
              where subscriber_id like 'rb-%' and domain <> 'installation'),
  '١٢ · لا قيد عمولةٍ واحد نتج عن مسار التنصيب');

select pg_temp.ok(
  (select count(*) from public.commission_rows) = 0
  and (select count(*) from public.commission_months) = 0,
  '  · وجداول العمولة لم تُمسّ إطلاقاً');

select pg_temp.ok(
  not exists (select 1 from public.audit_logs
              where action = 'installation.stage.advanced'
                and request_id is not null),
  '  · وأثر التقدّم بلا معرّف طلب — لا يُربك حرّاس الإعادة المالية');

-- ===========================================================================
-- ١٣. المسح الجماعي لا يُسجّل أحداً أعمى، ويعود بالممنوعين وأسبابهم (INS-013).
-- ===========================================================================

-- rb-clash في الملف الخام نفسه، وباقته مؤهِّلة ومصدره معلَن الاكتمال —
-- لكن هويته متعارضة وبلا تصنيف. فالبوابة تمنعه، ولا يُسجَّل، ولا تُمسّ حالته.
select pg_temp.ok(
  (select count(*) from public.installation_enrollments
   where subscriber_id = 'rb-clash') = 0,
  '١٣ · مَن لم تُجزه البوابة لا يُسجَّل مهما كان في الملف');

select pg_temp.ok(
  (select st.current_stage from public.installation_subscriber_state st
   join public.installation_subscribers s on s.id = st.subscriber_uuid
   where s.subscriber_id = 'rb-mid') = 'P3'
  and (select st.remaining from public.installation_subscriber_state st
       join public.installation_subscribers s on s.id = st.subscriber_uuid
       where s.subscriber_id = 'rb-mid') = 7000,
  '  · والمشترك التاريخي في الملف نفسه باقٍ عند P3 / 7000 — لا إعادة إلى P1');

-- إعادة التشغيل بمعرّف طلبٍ جديد: الهوية والتصنيف يُحسمان بعد الرفع عادةً،
-- فالمسح يُعاد. ولا ازدواج: المسجَّل مُستبعَد أصلاً.
select pg_temp.ok(
  (public.bridge_saas_activations_to_enrollments(
     'bd000000-0000-0000-0000-0000000000b1', 500,
     'bd000000-0000-0000-0000-00000000f050') #>> '{result,enrolled}')::int = 0,
  '  · وإعادة المسح لا تُسجّل أحداً مرّتين');

select pg_temp.ok(
  (public.bridge_saas_activations_to_enrollments(
     'bd000000-0000-0000-0000-0000000000b1', 500,
     'bd000000-0000-0000-0000-00000000f050') #>> '{result,blocked}')::int = 1
  and (public.bridge_saas_activations_to_enrollments(
     'bd000000-0000-0000-0000-0000000000b1', 500,
     'bd000000-0000-0000-0000-00000000f050')
       #>> '{result,reasons,IDENTITY_CONFLICT}')::int = 1,
  '  · والممنوع يعود بسببه نصاً: IDENTITY_CONFLICT × 1');

select pg_temp.ok(
  (public.bridge_saas_activations_to_enrollments(
     'bd000000-0000-0000-0000-0000000000b1', 500,
     'bd000000-0000-0000-0000-00000000f050') ->> 'replayed')::boolean = true,
  '  · ونفس معرّف الطلب إعادةٌ بلا أثر ثانٍ');

-- ===========================================================================
-- ١٤. التقدّم يتبع إصدار التسجيل المجمَّد، لا السلّم التاريخي (INS-015).
-- ===========================================================================

-- (أ) المبالغ المصروفة فعلاً جاءت من تعريفات إصدار التسجيل.
select pg_temp.ok(
  (select public.stage_amount_for_version(e.scheme_version_id, 'P1')
   from public.installation_enrollments e where e.subscriber_id = 'rb-new') = 3000
  and (select public.stage_amount_for_version(e.scheme_version_id, 'P4')
       from public.installation_enrollments e where e.subscriber_id = 'rb-new') = 4000
  and (select public.next_stage_for_version(e.scheme_version_id, 'P3')
       from public.installation_enrollments e where e.subscriber_id = 'rb-new') = 'P4',
  '١٤ · سلّم rb-new ومبالغه مقروءان من إصدار تسجيله');

-- (ب) إصدارٌ ثانٍ منشور بسلّمٍ مختلف: 9000 بدل 10000 بعد P1.
reset role;

insert into public.installation_fee_schemes (id, code, name_ar, is_active, created_by)
values ('bd000000-0000-0000-0000-0000000000f1', 'RB-SCHEME-2', 'مخطط الاختبار الثاني',
        true, 'bd000000-0000-0000-0000-0000000000a1');

insert into public.installation_scheme_versions
  (id, scheme_id, version, status, effective_from, total_amount, created_by)
values ('bd000000-0000-0000-0000-0000000000f2',
        'bd000000-0000-0000-0000-0000000000f1', 1, 'DRAFT', current_date, 13000,
        'bd000000-0000-0000-0000-0000000000a1');

insert into public.installation_stage_definitions
  (scheme_version_id, sequence, code, display_name_ar, amount, expected_remaining, is_terminal)
values
  ('bd000000-0000-0000-0000-0000000000f2', 1, 'P1', 'الأولى', 3000, 13000, false),
  ('bd000000-0000-0000-0000-0000000000f2', 2, 'P2', 'الثانية', 3000,  9000, false),
  ('bd000000-0000-0000-0000-0000000000f2', 3, 'DONE', 'منتهية',   0,     0, true);

update public.installation_scheme_versions
set status = 'PUBLISHED', published_at = now(),
    published_by = 'bd000000-0000-0000-0000-0000000000a1'
where id = 'bd000000-0000-0000-0000-0000000000f2';

insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, canceled, raw_parent, fdt_code)
values ('bd000000-0000-0000-0000-0000000000b1', 'RB-EV-V2', 'rb-v2', 'RB-PKG', false,
        'rb.raw.agent', '105');

insert into public.subscriber_identities
  (username, identity_status, match_method, source_classification, effective_agent_id, fdt_code)
values ('rb-v2', 'MATCHED', 'EXACT_USERNAME', 'RESELLER',
        'bd000000-0000-0000-0000-0000000000a2', '105');

insert into public.subscriber_classifications
  (username_key, classification, reason_code, source_completeness)
values ('rb-v2', 'NEW', 'COMPLETE_LIFETIME_HISTORY_OBSERVED', 'COMPLETE');

insert into public.subscriber_ownership
  (username_key, ownership_type, agent_id, effective_from, reason, performed_by)
values ('rb-v2','RESELLER','bd000000-0000-0000-0000-0000000000a2',
        timestamptz '2026-01-01 00:00+03','تثبيت','bd000000-0000-0000-0000-0000000000a1');

set local role authenticated;
set local request.jwt.claim.sub = 'bd000000-0000-0000-0000-0000000000a1';

select pg_temp.ok(
  (public.bridge_saas_activations_to_enrollments(
     'bd000000-0000-0000-0000-0000000000b1', 500,
     'bd000000-0000-0000-0000-00000000f060') #>> '{result,enrolled}')::int = 1,
  '  · والمشترك الجديد يُسجَّل على الإصدار المنشور الساري');

select pg_temp.ok(
  (select scheme_version_id from public.installation_enrollments
   where subscriber_id = 'rb-v2') = 'bd000000-0000-0000-0000-0000000000f2',
  '  · فيتجمّد إصداره الثاني في تسجيله هو، لا الأول');

-- (ج) الصرف يقرأ سلّم إصداره: بعد 3000 يصير المتبقي 10000، ولا مرحلة عنده
--     بهذا المتبقي. السلّم التاريخي كان سيقول P2 ويُمرّرها بصمت — وهذا هو
--     الفارق الذي يُثبته الرفض.
select public.review_invoice('rb-v2', 'P1', 'VERIFIED', 'مطابقة', 'RB-INV-V2-P1',
  'bd000000-0000-0000-0000-00000000f061');
select public.materialize_installation_entitlements('2026-11', null, 500,
  'bd000000-0000-0000-0000-00000000f062');

select pg_temp.ok(
  (select count(*) from public.installation_entitlements
   where subscriber_id = 'rb-v2' and stage = 'P1') = 1,
  '  · واستحقاق P1 يُشتقّ له عادياً');

select pg_temp.must_fail_with(
  $q$select public.record_installation_payment(
       (select id from public.installation_entitlements
        where subscriber_id = 'rb-v2' and stage = 'P1'),
       null, 'bd000000-0000-0000-0000-00000000f063')$q$,
  '  · لكن الصرف يسقط ذرّياً لأن سلّم إصداره لا يعرف متبقّي 10000',
  'INSTALLATION_SCHEME_LADDER_MISMATCH');

select pg_temp.ok(
  (select st.current_stage from public.installation_subscriber_state st
   join public.installation_subscribers s on s.id = st.subscriber_uuid
   where s.subscriber_id = 'rb-v2') = 'P1'
  and (select st.remaining from public.installation_subscriber_state st
       join public.installation_subscribers s on s.id = st.subscriber_uuid
       where s.subscriber_id = 'rb-v2') = 13000
  and not exists (select 1 from public.installation_payment_history h
                  join public.installation_subscribers s on s.id = h.subscriber_uuid
                  where s.subscriber_id = 'rb-v2')
  and not exists (select 1 from public.financial_ledger
                  where subscriber_id = 'rb-v2'),
  '  · ولا واقعة ولا قيد ولا تقدّم: الفشل ذرّيّ لا صامت');

-- (د) الحدّ يُعلن صراحةً: قيود التخزين نفسها مكتوبة على سلّم V1، فلا يُدّعى
--     دعمٌ كامل للإصدارات المختلفة — يُقرأ الإصدار ويُرفَض ما لا يُمثَّل.
select pg_temp.ok(
  (select count(*) from pg_catalog.pg_constraint
   where conname in ('installation_state_stage_matches_remaining',
                     'installation_entitlements_stage_matches_remaining',
                     'installation_entitlements_amount_matches_stage')
     and pg_catalog.pg_get_constraintdef(oid) like '%installation\_%\_for\_%') = 3,
  '  · وقيود التخزين الثلاثة مكتوبة على الدوال التاريخية — حدٌّ معلن لا مُدّعى');

rollback;
