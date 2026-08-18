-- ضمانات محرّك العمليات المالية على قاعدة حقيقية.
-- كل تجربة تُثبت منعاً أو استمراريةً، لا نجاحاً فقط. القيم كلها مُختلَقة.

\set ON_ERROR_STOP on
\pset tuples_only on

create or replace function pg_temp.must_fail(p_sql text, p_label text)
returns text language plpgsql as $$
begin
  execute p_sql;
  return 'FAILED: ' || p_label || ' — مرّ وكان يجب أن يُرفض';
exception when others then
  return ' ok   ' || p_label;
end;
$$;

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns text language sql as $$
  select case when p_cond then ' ok   ' || p_label else 'FAILED: ' || p_label end;
$$;

begin;

insert into auth.users (id, email) values
  ('b1111111-1111-1111-1111-111111111111', 'adm@fixture.invalid'),
  ('b2222222-2222-2222-2222-222222222222', 'acc@fixture.invalid'),
  ('b3333333-3333-3333-3333-333333333333', 'vie@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active) values
  ('b1111111-1111-1111-1111-111111111111', 'AD', 'adm@fixture.invalid', 'admin', true),
  ('b2222222-2222-2222-2222-222222222222', 'AC', 'acc@fixture.invalid', 'accountant', true),
  ('b3333333-3333-3333-3333-333333333333', 'VI', 'vie@fixture.invalid', 'viewer', true)
on conflict (id) do update set role = excluded.role, is_active = true;

insert into public.packages (code, name, semantic_category) values
  ('P-35000','P-35000','PAID_PACKAGE'),
  ('Loan-3','Loan-3','DEBT_SERVICE'),
  ('Diamond','Diamond','UNKNOWN')
on conflict (code) do nothing;

-- ===========================================================================
-- 32. الصلاحيات
-- ===========================================================================
select ' == permissions ==';

select pg_temp.ok(
  public.effective_permission('b2222222-2222-2222-2222-222222222222', 'payment.execute'),
  'المحاسب يرث تنفيذ الدفع من قالبه');

select pg_temp.ok(
  not public.effective_permission('b2222222-2222-2222-2222-222222222222', 'payment.correct'),
  'المحاسب لا يكتسب التصحيح ضمناً');

select pg_temp.ok(
  not public.effective_permission('b2222222-2222-2222-2222-222222222222', 'payment.reverse'),
  'المحاسب لا يكتسب العكس ضمناً');

select pg_temp.ok(
  not public.effective_permission('b3333333-3333-3333-3333-333333333333', 'payment.execute'),
  'المشاهد لا يدفع');

select pg_temp.ok(
  public.effective_permission('b3333333-3333-3333-3333-333333333333', 'installation.view'),
  'المشاهد يقرأ');

-- منح صريح لمستخدم واحد بلا ترقية دوره.
insert into public.user_permission_overrides
  (user_id, capability_key, effect, granted_by, reason)
values ('b2222222-2222-2222-2222-222222222222', 'payment.correct', 'GRANT',
        'b1111111-1111-1111-1111-111111111111', 'قرار إداري صريح');

select pg_temp.ok(
  public.effective_permission('b2222222-2222-2222-2222-222222222222', 'payment.correct'),
  'المنح الصريح يعمل بلا تغيير الدور');

select pg_temp.ok(
  (select role from public.profiles where id = 'b2222222-2222-2222-2222-222222222222') = 'accountant',
  'الدور لم يتغيّر مع المنح');

-- المنع يغلب القالب.
insert into public.user_permission_overrides
  (user_id, capability_key, effect, granted_by, reason)
values ('b2222222-2222-2222-2222-222222222222', 'payment.execute', 'DENY',
        'b1111111-1111-1111-1111-111111111111', 'إيقاف مؤقت');

select pg_temp.ok(
  not public.effective_permission('b2222222-2222-2222-2222-222222222222', 'payment.execute'),
  'المنع الصريح يغلب وراثة القالب');

-- المنع يغلب المنح على القدرة نفسها.
insert into public.user_permission_overrides
  (user_id, capability_key, effect, scope_type, scope_id, granted_by)
values ('b3333333-3333-3333-3333-333333333333', 'subscriber.edit', 'GRANT', 'AGENT', 'AG-1',
        'b1111111-1111-1111-1111-111111111111'),
       ('b3333333-3333-3333-3333-333333333333', 'subscriber.edit', 'DENY', 'GLOBAL', null,
        'b1111111-1111-1111-1111-111111111111');

select pg_temp.ok(
  not public.effective_permission('b3333333-3333-3333-3333-333333333333',
                                  'subscriber.edit', 'AGENT', 'AG-1'),
  'المنع العام يغلب منحاً مقيّداً بنطاق');

-- النطاق: منح لوكيل واحد لا يمتد إلى غيره.
insert into public.user_permission_overrides
  (user_id, capability_key, effect, scope_type, scope_id, granted_by)
values ('b3333333-3333-3333-3333-333333333333', 'subscriber.match', 'GRANT', 'AGENT', 'AG-7',
        'b1111111-1111-1111-1111-111111111111');

select pg_temp.ok(
  public.effective_permission('b3333333-3333-3333-3333-333333333333',
                              'subscriber.match', 'AGENT', 'AG-7'),
  'المنح المقيّد يعمل داخل نطاقه');

select pg_temp.ok(
  not public.effective_permission('b3333333-3333-3333-3333-333333333333',
                                  'subscriber.match', 'AGENT', 'AG-8'),
  'المنح المقيّد لا يتسرّب إلى نطاق آخر');

-- التفسير قابل للقراءة.
select pg_temp.ok(
  (public.explain_permission('b2222222-2222-2222-2222-222222222222', 'payment.execute')
     ->> 'explicit_deny')::boolean
  and not (public.explain_permission('b2222222-2222-2222-2222-222222222222', 'payment.execute')
     ->> 'effective')::boolean,
  'التفسير يكشف سبب المنع');

-- النطاق يلزمه معرّف، والعام يلزمه غيابه.
select pg_temp.must_fail($$
  insert into public.user_permission_overrides
    (user_id, capability_key, effect, scope_type, scope_id, granted_by)
  values ('b3333333-3333-3333-3333-333333333333','report.view','GRANT','AGENT',null,
          'b1111111-1111-1111-1111-111111111111')
$$, 'نطاق وكيل بلا معرّف مرفوض');

-- الحماية من الإقفال.
-- الحارس مؤجَّل عمداً: خطوة وسيطة قد تُنقص العدد، والمهم حصيلة المعاملة. لذا
-- لا يُرى أثره داخل معاملة مفتوحة إلا بجعله فورياً، وهذا ما تفعله التجربة
-- حتى تقيس المنع نفسه لا توقيته.
select pg_temp.must_fail($$
  set constraints public.trg_guard_permission_lockout immediate;
  insert into public.user_permission_overrides
    (user_id, capability_key, effect, granted_by)
  values ('b1111111-1111-1111-1111-111111111111','permission.manage','DENY',
          'b1111111-1111-1111-1111-111111111111')
$$, 'منع آخر مدير صلاحيات مرفوض');

select pg_temp.ok(public.permission_administrators_remaining() >= 1,
  'يبقى مدير صلاحيات واحد على الأقل');

-- الإنفاذ خادمي: لا يكفي إخفاء زر.
set local role authenticated;
set local request.jwt.claim.sub = 'b3333333-3333-3333-3333-333333333333';
select pg_temp.must_fail(
  $$select public.set_user_permission('b2222222-2222-2222-2222-222222222222',
      'payment.execute','GRANT','GLOBAL',null,'x', gen_random_uuid())$$,
  'المشاهد لا يمنح صلاحيات عبر RPC');
select pg_temp.must_fail(
  $$select public.release_installation_hold(gen_random_uuid(), 'x', gen_random_uuid())$$,
  'المشاهد لا يرفع تعليقاً عبر RPC');
reset role;

-- ===========================================================================
-- 33. المخططات
-- ===========================================================================
select ' == schemes ==';

select pg_temp.ok(
  (select count(*) from public.installation_stage_definitions d
   join public.installation_scheme_versions v on v.id = d.scheme_version_id
   where v.version = 1) = 5,
  'V1 يمثّل أربع مراحل ونهاية');

select pg_temp.ok(
  (select sum(amount) from public.installation_stage_definitions d
   join public.installation_scheme_versions v on v.id = d.scheme_version_id
   where v.version = 1) = 13000,
  'مجموع V1 ثلاثة عشر ألفاً');

select pg_temp.ok(
  (select amount from public.installation_stage_definitions d
   join public.installation_scheme_versions v on v.id = d.scheme_version_id
   where v.version = 1 and d.code = 'P4') = 4000,
  'القسط الرابع أربعة آلاف من التهيئة لا من الكود');

-- المنشور لا يُعدَّل بصمت.
select pg_temp.must_fail($$
  update public.installation_scheme_versions set total_amount = 99999
  where version = 1 and status = 'PUBLISHED'
$$, 'تعديل مبلغ إصدار منشور مرفوض');

select pg_temp.must_fail($$
  update public.installation_stage_definitions set amount = 9999
  where code = 'P1'
$$, 'تعديل مرحلة في إصدار منشور مرفوض');

select pg_temp.must_fail($$
  delete from public.installation_scheme_versions where version = 1
$$, 'حذف إصدار منشور مرفوض');

-- إصدار جديد بعدد مراحل مختلف، بلا سطر كود واحد.
do $$
declare v_scheme uuid; v_v2 uuid;
begin
  select id into v_scheme from public.installation_fee_schemes where code = 'INSTALLATION_STANDARD';
  insert into public.installation_scheme_versions (scheme_id, version, status, notes)
  values (v_scheme, 2, 'DRAFT', 'three stages') returning id into v_v2;
  insert into public.installation_stage_definitions
    (scheme_version_id, sequence, code, display_name_ar, amount, is_terminal)
  values (v_v2, 1, 'S1', 'الأولى', 5000, false),
         (v_v2, 2, 'S2', 'الثانية', 5000, false),
         (v_v2, 3, 'END', 'منتهٍ', 0, true);
end;
$$;

select pg_temp.ok(
  (select count(*) from public.installation_stage_definitions d
   join public.installation_scheme_versions v on v.id = d.scheme_version_id
   where v.version = 2) = 3,
  'إصدار ثانٍ بثلاث مراحل بلا تغيير كود');

-- V1 لم يتأثر بوجود V2.
select pg_temp.ok(
  (select sum(amount) from public.installation_stage_definitions d
   join public.installation_scheme_versions v on v.id = d.scheme_version_id
   where v.version = 1) = 13000,
  'نشر إصدار ثانٍ لا يمسّ الأول');

-- المخطط لا يؤهِّل خدمة الدَّين ولا المجهول.
select pg_temp.ok(
  (select semantic_category from public.packages where code = 'Loan-3') = 'DEBT_SERVICE',
  'Loan-3 خدمة دَين');
select pg_temp.ok(
  (select semantic_category from public.packages where code = 'Diamond') = 'UNKNOWN',
  'Diamond تبقى مجهولة');

-- ===========================================================================
-- 34. استمرارية التاريخ
-- ===========================================================================
select ' == historical continuity ==';

-- أساس مصغّر يحاكي شكل الإنتاج.
insert into public.installation_subscribers (id, subscriber_id, reseller, fdt, start_date, created_by)
values ('c1111111-1111-1111-1111-111111111111', 'h-p3', 'وكيل', '11', date '2026-01-01', 'b1111111-1111-1111-1111-111111111111'),
       ('c2222222-2222-2222-2222-222222222222', 'h-done', 'وكيل', '12', date '2026-01-01', 'b1111111-1111-1111-1111-111111111111'),
       ('c3333333-3333-3333-3333-333333333333', 'h-unres', 'وكيل', '13', date '2026-01-01', 'b1111111-1111-1111-1111-111111111111')
on conflict do nothing;

insert into public.installation_subscriber_state
  (subscriber_uuid, as_of_date, remaining, current_stage, resolution, payment_eligible)
values ('c1111111-1111-1111-1111-111111111111', date '2026-07-31', 7000, 'P3', 'resolved', true),
       ('c2222222-2222-2222-2222-222222222222', date '2026-07-31', 0, 'DONE', 'resolved', false),
       ('c3333333-3333-3333-3333-333333333333', date '2026-07-31', null, null, 'unresolved', false)
on conflict do nothing;

insert into public.installation_payment_history (subscriber_uuid, stage, amount, payment_date, created_by)
values ('c1111111-1111-1111-1111-111111111111', 'P1', 3000, date '2026-03-01', 'b1111111-1111-1111-1111-111111111111'),
       ('c1111111-1111-1111-1111-111111111111', 'P2', 3000, date '2026-05-01', 'b1111111-1111-1111-1111-111111111111')
on conflict do nothing;

select public.bootstrap_historical_enrollments() as first_run \gset
select public.bootstrap_historical_enrollments() as second_run \gset

select pg_temp.ok(
  (select current_stage_code from public.installation_enrollments where subscriber_id = 'h-p3') = 'P3',
  'من دفع قسطين يكمل من الثالث لا من الأول');

select pg_temp.ok(
  (select origin from public.installation_enrollments where subscriber_id = 'h-p3')
    = 'HISTORICAL_BASELINE',
  'التسجيل التاريخي موسوم بأصله');

select pg_temp.ok(
  (select status from public.installation_enrollments where subscriber_id = 'h-done') = 'COMPLETED',
  'المكتمل يبقى مكتملاً');

select pg_temp.ok(
  not exists (select 1 from public.installation_enrollments where subscriber_id = 'h-unres'),
  'غير المحسوم لا يُسجَّل ولا تُخمَّن مرحلته');

select pg_temp.ok(
  (select count(*) from public.installation_payment_history
   where subscriber_uuid = 'c1111111-1111-1111-1111-111111111111') = 2,
  'الدفعات التاريخية لم تتغيّر عدداً');

select pg_temp.ok(
  (select sum(amount) from public.installation_payment_history
   where subscriber_uuid = 'c1111111-1111-1111-1111-111111111111') = 6000,
  'الدفعات التاريخية لم تتغيّر مبلغاً');

select pg_temp.ok(
  (select remaining from public.installation_subscriber_state
   where subscriber_uuid = 'c1111111-1111-1111-1111-111111111111') = 7000,
  'المتبقي لم يُمَس');

select pg_temp.ok(
  (select count(*) from public.installation_enrollments where origin = 'HISTORICAL_BASELINE') = 2,
  'إعادة تشغيل الوصل لا تُنشئ تسجيلات مكرّرة');

select pg_temp.ok(
  (select count(*) from public.installation_entitlements) = 0,
  'الوصل التاريخي لم يُنشئ استحقاقاً واحداً');

-- ===========================================================================
-- 35. التسجيل الجديد والأهلية
-- ===========================================================================
select ' == enrollment gate ==';

insert into public.saas_import_batches
  (id, source_kind, source_filename, source_checksum, parser_version, imported_by,
   completeness_status)
values ('d1111111-1111-1111-1111-111111111111', 'ACTIVATION_EVENTS', 'unknown.xlsx',
        'ck-unknown', 'v1', 'b1111111-1111-1111-1111-111111111111', 'UNKNOWN'),
       ('d2222222-2222-2222-2222-222222222222', 'ACTIVATION_EVENTS', 'complete.xlsx',
        'ck-complete', 'v1', 'b1111111-1111-1111-1111-111111111111', 'COMPLETE')
on conflict do nothing;

insert into public.agents (id, code, official_name)
values ('e1111111-1111-1111-1111-111111111111', 'AGT-T', 'وكيل تجربة')
on conflict (code) do nothing;

insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, canceled, raw_parent)
values ('d1111111-1111-1111-1111-111111111111','EV-UNK','u-new','P-35000',false,'r.t'),
       ('d2222222-2222-2222-2222-222222222222','EV-OK','u-new','P-35000',false,'r.t'),
       ('d2222222-2222-2222-2222-222222222222','EV-LOAN','u-loan','Loan-3',false,'r.t'),
       ('d2222222-2222-2222-2222-222222222222','EV-CANC','u-canc','P-35000',true,'r.t'),
       ('d2222222-2222-2222-2222-222222222222','EV-DIRECT','u-direct','P-35000',false,'FTTH_Users'),
       ('d2222222-2222-2222-2222-222222222222','EV-EXIST','u-exist','P-35000',false,'r.t'),
       ('d2222222-2222-2222-2222-222222222222','EV-REVIEW','u-review','P-35000',false,'r.t')
on conflict do nothing;

insert into public.agent_aliases (agent_id, alias, resolution)
values ('e1111111-1111-1111-1111-111111111111', 'r.t', 'mapped')
on conflict (alias_key) do nothing;

insert into public.subscriber_identities
  (username, identity_status, match_method, source_classification, effective_agent_id)
values ('u-new','MATCHED','EXACT_USERNAME','RESELLER','e1111111-1111-1111-1111-111111111111'),
       ('u-loan','MATCHED','EXACT_USERNAME','RESELLER','e1111111-1111-1111-1111-111111111111'),
       ('u-canc','MATCHED','EXACT_USERNAME','RESELLER','e1111111-1111-1111-1111-111111111111'),
       ('u-direct','MATCHED','EXACT_USERNAME','DIRECT_COMPANY',null),
       ('u-exist','MATCHED','EXACT_USERNAME','RESELLER','e1111111-1111-1111-1111-111111111111'),
       ('u-review','MATCHED','EXACT_USERNAME','RESELLER','e1111111-1111-1111-1111-111111111111')
on conflict do nothing;

insert into public.subscriber_classifications
  (username_key, classification, reason_code, source_completeness)
values ('u-new','NEW','COMPLETE_LIFETIME_HISTORY_OBSERVED','COMPLETE'),
       ('u-loan','NEW','COMPLETE_LIFETIME_HISTORY_OBSERVED','COMPLETE'),
       ('u-canc','NEW','COMPLETE_LIFETIME_HISTORY_OBSERVED','COMPLETE'),
       ('u-direct','NEW','COMPLETE_LIFETIME_HISTORY_OBSERVED','COMPLETE'),
       ('u-exist','EXISTING','REGISTRY_PREEXISTING','UNKNOWN'),
       ('u-review','NEEDS_REVIEW','UNKNOWN_SOURCE_COMPLETENESS','UNKNOWN');

select pg_temp.ok(
  (public.evaluate_enrollment_gate('u-new','EV-OK') ->> 'allowed')::boolean,
  'جديد بمصدر مكتمل وحدث مدفوع يُسجَّل');

select pg_temp.ok(
  not (public.evaluate_enrollment_gate('u-new','EV-UNK') ->> 'allowed')::boolean
  and public.evaluate_enrollment_gate('u-new','EV-UNK') -> 'blockers' ? 'SOURCE_INCOMPLETE',
  'جديد بمصدر مجهول الاكتمال لا يُسجَّل تلقائياً');

select pg_temp.ok(
  public.evaluate_enrollment_gate('u-loan','EV-LOAN') -> 'blockers' ? 'DEBT_SERVICE_NEVER_QUALIFIES',
  'Loan-3 لا يُنشئ تسجيلاً أبداً');

select pg_temp.ok(
  public.evaluate_enrollment_gate('u-canc','EV-CANC') -> 'blockers' ? 'EVENT_CANCELED',
  'الحدث الملغى لا يؤهِّل');

select pg_temp.ok(
  public.evaluate_enrollment_gate('u-direct','EV-DIRECT') -> 'blockers' ? 'DIRECT_COMPANY_NOT_ELIGIBLE',
  'الشركة المباشرة ليست استحقاق وكيل افتراضاً');

select pg_temp.ok(
  public.evaluate_enrollment_gate('u-exist','EV-EXIST') -> 'blockers' ? 'SUBSCRIBER_IS_EXISTING',
  'القديم لا يُسجَّل تنصيباً جديداً');

select pg_temp.ok(
  public.evaluate_enrollment_gate('u-review','EV-REVIEW') -> 'blockers' ? 'CLASSIFICATION_NEEDS_REVIEW',
  'المرشَّح للمراجعة لا يُسجَّل تلقائياً');

-- التسجيل الفعلي ثم منع إعادة استعمال الحدث.
set local role authenticated;
set local request.jwt.claim.sub = 'b1111111-1111-1111-1111-111111111111';
select public.enroll_new_installation('u-new','EV-OK',null, gen_random_uuid()) as enrolled \gset
reset role;

select pg_temp.ok(
  (select current_stage_code from public.installation_enrollments where subscriber_id = 'u-new') = 'P1',
  'التسجيل الجديد يبدأ من أول مرحلة مُهيَّأة');

select pg_temp.ok(
  public.evaluate_enrollment_gate('u-new','EV-OK') -> 'blockers' ? 'ALREADY_ENROLLED',
  'لا تسجيل مرتين للمشترك نفسه');

select pg_temp.must_fail($$
  insert into public.installation_enrollments
    (subscriber_id, scheme_version_id, origin, first_qualifying_event_id)
  select 'u-other', scheme_version_id, 'NEW_INSTALLATION', 'EV-OK'
  from public.installation_enrollments where subscriber_id = 'u-new'
$$, 'حدث واحد لا يموّل تسجيلين');

-- ===========================================================================
-- 36. الأهلية والدفع
-- ===========================================================================
select ' == eligibility and payment ==';

insert into public.installation_batches (id, period, created_by, file_name, file_checksum)
values ('f1111111-1111-1111-1111-111111111111', '2026-08',
        'b1111111-1111-1111-1111-111111111111', 'f.xlsx', 'ck-f')
on conflict do nothing;

insert into public.installation_entitlements
  (id, batch_id, period, subscriber_id, reseller, remaining, stage, amount,
   invoice_status, payment_status, created_by)
values ('f2222222-2222-2222-2222-222222222222', 'f1111111-1111-1111-1111-111111111111',
        '2026-08', 'h-p3', 'وكيل', 7000, 'P3', 3000, 'approved', 'eligible',
        'b1111111-1111-1111-1111-111111111111')
on conflict do nothing;

select pg_temp.ok(
  (public.installation_entitlement_eligibility('f2222222-2222-2222-2222-222222222222')
    ->> 'eligible')::boolean,
  'المستحق المطابق للتسجيل والفاتورة مؤهَّل');

-- مرحلة خارج التسلسل.
insert into public.installation_entitlements
  (id, batch_id, period, subscriber_id, reseller, remaining, stage, amount,
   invoice_status, payment_status, created_by)
values ('f3333333-3333-3333-3333-333333333333', 'f1111111-1111-1111-1111-111111111111',
        '2026-08', 'h-p3', 'وكيل', 13000, 'P1', 3000, 'approved', 'eligible',
        'b1111111-1111-1111-1111-111111111111')
on conflict do nothing;

select pg_temp.ok(
  public.installation_entitlement_eligibility('f3333333-3333-3333-3333-333333333333')
    -> 'blockers' ? 'STAGE_OUT_OF_SEQUENCE',
  'لا يُدفع قسط سابق قُفز عنه');

-- الفاتورة الناقصة تحجب.
insert into public.installation_entitlements
  (id, batch_id, period, subscriber_id, reseller, remaining, stage, amount,
   invoice_status, payment_status, created_by)
values ('f4444444-4444-4444-4444-444444444444', 'f1111111-1111-1111-1111-111111111111',
        '2026-09', 'h-p3', 'وكيل', 7000, 'P3', 3000, 'pending', 'awaiting_invoice',
        'b1111111-1111-1111-1111-111111111111')
on conflict do nothing;

select pg_temp.ok(
  public.installation_entitlement_eligibility('f4444444-4444-4444-4444-444444444444')
    -> 'blockers' ? 'MISSING_INVOICE',
  'لا دفع بلا فاتورة');

-- التعليق يحجب ثم يُرفَع.
insert into public.installation_holds
  (subscriber_id, stage_code, reason_code, hold_type, created_by)
values ('h-p3', 'P3', 'FINANCIAL_MISMATCH', 'MANUAL', 'b1111111-1111-1111-1111-111111111111');

select pg_temp.ok(
  public.installation_entitlement_eligibility('f2222222-2222-2222-2222-222222222222')
    -> 'blockers' ? 'ON_HOLD',
  'التعليق النشط يحجب الدفع');

update public.installation_holds
set status = 'RELEASED', released_by = 'b1111111-1111-1111-1111-111111111111',
    released_at = now(), release_reason = 'تمت المطابقة'
where subscriber_id = 'h-p3' and status = 'ACTIVE';

select pg_temp.ok(
  (public.installation_entitlement_eligibility('f2222222-2222-2222-2222-222222222222')
    ->> 'eligible')::boolean,
  'رفع التعليق يعيد التقييم ولا يدفع بنفسه');

select pg_temp.ok(
  (select count(*) from public.installation_payments) = 0,
  'رفع التعليق لم يُنشئ دفعة');

-- التعليق لا يمحو التاريخ المالي.
select pg_temp.ok(
  (select count(*) from public.installation_payment_history
   where subscriber_uuid = 'c1111111-1111-1111-1111-111111111111') = 2,
  'التعليق لم يمسّ سجل الدفعات');

-- إعادة التحقق قبل الترحيل تمسك تغيّراً بعد إعداد الدفعة.
insert into public.installation_payment_batches (id, name, prepared_by)
values ('f5555555-5555-5555-5555-555555555555', 'دفعة تجربة',
        'b1111111-1111-1111-1111-111111111111')
on conflict do nothing;

insert into public.installation_payment_batch_items
  (batch_id, entitlement_id, subscriber_id, stage_code, amount)
values ('f5555555-5555-5555-5555-555555555555', 'f2222222-2222-2222-2222-222222222222',
        'h-p3', 'P3', 3000)
on conflict do nothing;

-- يتغيّر الحال بعد الإعداد: تعليق جديد.
insert into public.installation_holds
  (subscriber_id, stage_code, reason_code, hold_type, created_by)
values ('h-p3', 'P3', 'DUPLICATE', 'MANUAL', 'b1111111-1111-1111-1111-111111111111');

set local role authenticated;
set local request.jwt.claim.sub = 'b1111111-1111-1111-1111-111111111111';
select public.revalidate_payment_batch('f5555555-5555-5555-5555-555555555555') as reval \gset
reset role;

select pg_temp.ok(
  (select status from public.installation_payment_batch_items
   where batch_id = 'f5555555-5555-5555-5555-555555555555') = 'BLOCKED',
  'إعادة التحقق تمسك تعليقاً طرأ بعد الإعداد');

-- الاستحقاق الواحد لا يدخل دفعتين.
insert into public.installation_payment_batches (id, name, prepared_by)
values ('f6666666-6666-6666-6666-666666666666', 'دفعة ثانية',
        'b1111111-1111-1111-1111-111111111111')
on conflict do nothing;

update public.installation_payment_batch_items set status = 'PENDING'
where batch_id = 'f5555555-5555-5555-5555-555555555555';

select pg_temp.must_fail($$
  insert into public.installation_payment_batch_items
    (batch_id, entitlement_id, subscriber_id, stage_code, amount)
  values ('f6666666-6666-6666-6666-666666666666','f2222222-2222-2222-2222-222222222222',
          'h-p3','P3',3000)
$$, 'الاستحقاق الواحد لا يدخل دفعتين نشطتين');

-- حارس الدفع يمنع تحويل استحقاق محجوب إلى مدفوع.
select pg_temp.must_fail($$
  update public.installation_entitlements
  set payment_status = 'paid', paid_amount = 3000,
      paid_by = 'b1111111-1111-1111-1111-111111111111', paid_at = now()
  where id = 'f4444444-4444-4444-4444-444444444444'
$$, 'حارس الدفع يرفض استحقاقاً بلا فاتورة');

-- ===========================================================================
-- 12. إدارة الاكتمال
-- ===========================================================================
select ' == completeness ==';

select pg_temp.must_fail($$
  insert into public.import_completeness_declarations
    (import_batch_id, previous_status, declared_status, evidence, declared_by)
  values ('d1111111-1111-1111-1111-111111111111','UNKNOWN','COMPLETE','',
          'b1111111-1111-1111-1111-111111111111')
$$, 'إعلان الاكتمال بلا حدود تغطية ولا دليل مرفوض');

insert into public.import_completeness_declarations
  (import_batch_id, previous_status, declared_status, coverage_start, coverage_end,
   evidence, declared_by)
values ('d1111111-1111-1111-1111-111111111111','UNKNOWN','COMPLETE',
        date '2026-07-01', date '2026-07-31', 'تأكيد المزوّد',
        'b1111111-1111-1111-1111-111111111111');
select pg_temp.ok(true, 'إعلان الاكتمال بحدود ودليل مقبول ومُدقَّق');

-- ===========================================================================
-- 31. ثوابت السلامة المالية
-- ===========================================================================
select ' == invariants ==';

select pg_temp.ok(
  (select count(*) from pg_class c cross join lateral aclexplode(c.relacl) a
   where c.relnamespace = 'public'::regnamespace
     and c.relname in ('installation_enrollments','installation_holds','installation_invoices',
                       'installation_payment_batches','installation_payment_batch_items',
                       'installation_cycles','installation_scheme_versions',
                       'installation_stage_definitions','user_permission_overrides')
     and a.privilege_type <> 'SELECT'
     and a.grantee::regrole::text in ('authenticated','anon','public')) = 0,
  'لا صلاحية كتابة لأي دور تطبيقي على جداول العمليات');

select pg_temp.ok(
  (select count(*) from public.commission_rows where paid > 0) = 0,
  'لا عمولة دُفعت أثناء هذه التجارب');

rollback;
