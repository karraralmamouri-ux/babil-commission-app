-- PR-B3: page_activation_corrections بعد 20261014090000 —
--   1) تصحيحات ADD (لا مصدر حدثٍ لها أبداً) تشتقّ نطاقها من قاعدة 94–119
--      نفسها، لا من fdts.zone اليدوي.
--   2) active_exclusions/active_additions إجماليان على كامل المجموعة
--      الفعّالة، لا على الصفحة الحالية — لا يتغيّران بتغيّر limit/offset.
--
-- معزول بنطاق تسمية b3ak-.

\set ON_ERROR_STOP on
\pset tuples_only on

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns text language sql as $$
  select case when p_cond then '                   ok ' || p_label else 'FAILED: ' || p_label end;
$$;

begin;

select '                  == pr-b3: activation corrections scope + kpi ==';

insert into auth.users (id, email) values
  ('66000000-0000-0000-0000-0000000000a1','b3ak-admin@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active) values
  ('66000000-0000-0000-0000-0000000000a1','B3AK','b3ak-admin@fixture.invalid','admin',true)
on conflict (id) do update set role = 'admin', is_active = true;

insert into public.commission_cycles
  (id, name, period_start, period_end, engine_version, created_by, status)
values ('66000000-0000-0000-0000-0000000000a2','B3AK دورة',
        date '2027-06-01', date '2027-06-30','VNEXT',
        '66000000-0000-0000-0000-0000000000a1','UNDER_REVIEW')
on conflict do nothing;

insert into public.packages (code, name, semantic_category) values
  ('B3AK-PKG','B3AK-PKG','PAID_PACKAGE')
on conflict (code) do nothing;

-- أربع إضافات فعّالة: حدّا المدى 94/119 (نطاق FDT)، وحدّا خارجه 93/120
-- (نطاق AGENT) — بلا أي صفّ في fdts: fdt_commission_scope تُشتقّ من النصّ
-- وحده، لا من جدول الكابينات.
insert into public.activation_corrections
  (cycle_id, correction_type, subscriber_username, package_code, event_at,
   fdt_code, reason, request_id, created_by, status)
values
  ('66000000-0000-0000-0000-0000000000a2','ADD','b3ak-sub-94','B3AK-PKG','2027-06-05',
   '94','ضمن 94-119 — حدّ أدنى','66000000-0000-0000-0000-000000000f01',
   '66000000-0000-0000-0000-0000000000a1','ACTIVE'),
  ('66000000-0000-0000-0000-0000000000a2','ADD','b3ak-sub-119','B3AK-PKG','2027-06-06',
   '119','ضمن 94-119 — حدّ أعلى','66000000-0000-0000-0000-000000000f02',
   '66000000-0000-0000-0000-0000000000a1','ACTIVE'),
  ('66000000-0000-0000-0000-0000000000a2','ADD','b3ak-sub-93','B3AK-PKG','2027-06-07',
   '93','خارج المدى — تحت الحدّ الأدنى','66000000-0000-0000-0000-000000000f03',
   '66000000-0000-0000-0000-0000000000a1','ACTIVE'),
  ('66000000-0000-0000-0000-0000000000a2','ADD','b3ak-sub-120','B3AK-PKG','2027-06-08',
   '120','خارج المدى — فوق الحدّ الأعلى','66000000-0000-0000-0000-000000000f04',
   '66000000-0000-0000-0000-0000000000a1','ACTIVE'),
  -- إضافة مُلغاة: لا تُحتسَب في active_additions
  ('66000000-0000-0000-0000-0000000000a2','ADD','b3ak-sub-revoked','B3AK-PKG','2027-06-09',
   '94','مُلغاة عمداً للاختبار','66000000-0000-0000-0000-000000000f05',
   '66000000-0000-0000-0000-0000000000a1','ACTIVE')
on conflict do nothing;

-- انتقال ACTIVE -> REVOKED منسوب بالكامل دفعة واحدة، لا إدراج REVOKED مباشرة:
-- activation_corrections_revoked_is_attributed يرفض أي صفّ REVOKED لا يحمل
-- revoked_by/revoked_at/revoke_reason منذ لحظة كتابته.
update public.activation_corrections
set status = 'REVOKED',
    revoked_by = '66000000-0000-0000-0000-0000000000a1', revoked_at = now(),
    revoke_reason = 'اختبار'
where request_id = '66000000-0000-0000-0000-000000000f05';

-- استبعادٌ واحد فعّال بلا حدث مطابق حقيقي — يقع على نفس مسار fallback العارٍ
-- من fdt_code (EXCLUDE لا يحمل fdt_code أصلاً)، فيبقى AGENT كما كان دوماً.
insert into public.activation_corrections
  (cycle_id, correction_type, source_event_id, reason, request_id, created_by, status)
values
  ('66000000-0000-0000-0000-0000000000a2','EXCLUDE','B3AK-NOMATCH-1',
   'استبعاد بلا حدث مطابق','66000000-0000-0000-0000-000000000f06',
   '66000000-0000-0000-0000-0000000000a1','ACTIVE')
on conflict do nothing;

set local role authenticated;
set local request.jwt.claim.sub = '66000000-0000-0000-0000-0000000000a1';

with full_page as (
  select public.page_activation_corrections(
    p_cycle_id => '66000000-0000-0000-0000-0000000000a2', p_limit => 50, p_offset => 0) as doc
),
rows94 as (
  select r from full_page, jsonb_array_elements(doc->'rows') r
  where r->>'fdt_code' = '94' and r->>'correction_type' = 'ADD' and r->>'status' = 'ACTIVE'
  limit 1
),
rows93 as (
  select r from full_page, jsonb_array_elements(doc->'rows') r
  where r->>'fdt_code' = '93' and r->>'correction_type' = 'ADD'
  limit 1
),
rows119 as (
  select r from full_page, jsonb_array_elements(doc->'rows') r
  where r->>'fdt_code' = '119' and r->>'correction_type' = 'ADD'
  limit 1
),
rows120 as (
  select r from full_page, jsonb_array_elements(doc->'rows') r
  where r->>'fdt_code' = '120' and r->>'correction_type' = 'ADD'
  limit 1
)
select pg_temp.ok((select (r->>'scope_type') = 'FDT' and (r->>'scope_id') = '94' from rows94),
  'الحدّ الأدنى 94 — نطاق FDT، لا fdts.zone')
union all
select pg_temp.ok((select (r->>'scope_type') = 'FDT' and (r->>'scope_id') = '119' from rows119),
  'الحدّ الأعلى 119 — نطاق FDT')
union all
select pg_temp.ok((select (r->>'scope_type') = 'AGENT' and r->>'scope_id' is null from rows93),
  'خارج المدى (93) — نطاق AGENT، لا رمز نطاق')
union all
select pg_temp.ok((select (r->>'scope_type') = 'AGENT' and r->>'scope_id' is null from rows120),
  'خارج المدى (120) — نطاق AGENT');

with full_page as (
  select public.page_activation_corrections(
    p_cycle_id => '66000000-0000-0000-0000-0000000000a2', p_limit => 50, p_offset => 0) as doc
),
tiny_page as (
  select public.page_activation_corrections(
    p_cycle_id => '66000000-0000-0000-0000-0000000000a2', p_limit => 1, p_offset => 3) as doc
)
select pg_temp.ok(
  (select (doc->>'active_additions')::int from full_page) = 4,
  'أربع إضافات فعّالة فقط — الخامسة مُلغاة ولا تُحتسَب')
union all
select pg_temp.ok(
  (select (doc->>'active_exclusions')::int from full_page) = 1,
  'استبعادٌ فعّالٌ واحد')
union all
select pg_temp.ok(
  (select (doc->>'active_additions')::int from tiny_page)
    = (select (doc->>'active_additions')::int from full_page),
  'active_additions لا يتغيّر بتغيّر limit/offset')
union all
select pg_temp.ok(
  (select (doc->>'active_exclusions')::int from tiny_page)
    = (select (doc->>'active_exclusions')::int from full_page),
  'active_exclusions لا يتغيّر بتغيّر limit/offset')
union all
select pg_temp.ok(
  (select jsonb_array_length(doc->'rows') from tiny_page) = 1,
  'الصفحة الصغيرة تُعيد صفّاً واحداً فقط رغم أن الإجمالي أكبر');

-- ---------------------------------------------------------------------------
-- إضافات يدوية خارج ٩٤–١١٩: نفس سلطة العائدية المؤرَّخة التي يعتمدها المحرّك
-- (الترحيلة 78) — فترة صريحة تسود كاملةً، وغيابها وحده يُبقي احتياط الهوية.
-- ---------------------------------------------------------------------------

reset role;

insert into public.agents (id, code, official_name) values
  ('66000000-0000-0000-0000-0000000000a5','B3AK-OWN','وكيل عائدية'),
  ('66000000-0000-0000-0000-0000000000a6','B3AK-STALE','وكيل قديم — يجب ألّا يظهر')
on conflict (code) do nothing;

-- فترة صريحة RESELLER تسود: الوكيل الفعّال هو eo.agent_id.
insert into public.subscriber_ownership
  (username_key, ownership_type, agent_id, effective_from, effective_to, reason, performed_by)
values
  ('b3ak-sub-reseller','RESELLER','66000000-0000-0000-0000-0000000000a5',
   timestamptz '2027-01-01 00:00+03', null, 'اختبار', '66000000-0000-0000-0000-0000000000a1');

-- فترة صريحة DIRECT_COMPANY تسود: صفر وكيل، رغم عائدية حالية تُشير لوكيلٍ آخر.
insert into public.subscriber_identities
  (username, identity_status, match_method, source_classification, effective_agent_id)
values ('b3ak-sub-direct','MATCHED','EXACT_USERNAME','RESELLER',
        '66000000-0000-0000-0000-0000000000a6');
insert into public.subscriber_ownership
  (username_key, ownership_type, agent_id, effective_from, effective_to, reason, performed_by)
values
  ('b3ak-sub-direct','DIRECT_COMPANY', null,
   timestamptz '2027-01-01 00:00+03', null, 'اختبار', '66000000-0000-0000-0000-0000000000a1');

-- فترة صريحة NEEDS_REVIEW تسود: صفر وكيل أيضاً، رغم عائدية حالية.
insert into public.subscriber_identities
  (username, identity_status, match_method, source_classification, effective_agent_id)
values ('b3ak-sub-review','MATCHED','EXACT_USERNAME','RESELLER',
        '66000000-0000-0000-0000-0000000000a6');
insert into public.subscriber_ownership
  (username_key, ownership_type, agent_id, effective_from, effective_to, reason, performed_by)
values
  ('b3ak-sub-review','NEEDS_REVIEW', null,
   timestamptz '2027-01-01 00:00+03', null, 'اختبار', '66000000-0000-0000-0000-0000000000a1');

-- بلا فترة عائدية صريحة إطلاقاً: احتياط subscriber_identities وحده يُحسم.
insert into public.subscriber_identities
  (username, identity_status, match_method, source_classification, effective_agent_id)
values ('b3ak-sub-fallback','MATCHED','EXACT_USERNAME','RESELLER',
        '66000000-0000-0000-0000-0000000000a5');

insert into public.activation_corrections
  (cycle_id, correction_type, subscriber_username, package_code, event_at,
   fdt_code, reason, request_id, created_by, status)
values
  ('66000000-0000-0000-0000-0000000000a2','ADD','b3ak-sub-reseller','B3AK-PKG','2027-06-10',
   '93','عائدية RESELLER صريحة','66000000-0000-0000-0000-000000000f07',
   '66000000-0000-0000-0000-0000000000a1','ACTIVE'),
  ('66000000-0000-0000-0000-0000000000a2','ADD','b3ak-sub-direct','B3AK-PKG','2027-06-11',
   '93','عائدية DIRECT_COMPANY صريحة','66000000-0000-0000-0000-000000000f08',
   '66000000-0000-0000-0000-0000000000a1','ACTIVE'),
  ('66000000-0000-0000-0000-0000000000a2','ADD','b3ak-sub-review','B3AK-PKG','2027-06-12',
   '93','عائدية NEEDS_REVIEW صريحة','66000000-0000-0000-0000-000000000f09',
   '66000000-0000-0000-0000-0000000000a1','ACTIVE'),
  ('66000000-0000-0000-0000-0000000000a2','ADD','b3ak-sub-fallback','B3AK-PKG','2027-06-13',
   '93','بلا فترة عائدية صريحة — احتياط الهوية','66000000-0000-0000-0000-000000000f10',
   '66000000-0000-0000-0000-0000000000a1','ACTIVE')
on conflict do nothing;

set local role authenticated;
set local request.jwt.claim.sub = '66000000-0000-0000-0000-0000000000a1';

with owns as (
  select public.page_activation_corrections(
    p_cycle_id => '66000000-0000-0000-0000-0000000000a2', p_limit => 50, p_offset => 0) as doc
),
reseller_row as (
  select r from owns, jsonb_array_elements(doc->'rows') r
  where r->>'subscriber' = 'b3ak-sub-reseller' limit 1
),
direct_row as (
  select r from owns, jsonb_array_elements(doc->'rows') r
  where r->>'subscriber' = 'b3ak-sub-direct' limit 1
),
review_row as (
  select r from owns, jsonb_array_elements(doc->'rows') r
  where r->>'subscriber' = 'b3ak-sub-review' limit 1
),
fallback_row as (
  select r from owns, jsonb_array_elements(doc->'rows') r
  where r->>'subscriber' = 'b3ak-sub-fallback' limit 1
)
select pg_temp.ok(
  (select (r->>'scope_type') = 'AGENT'
     and (r->>'scope_id') = '66000000-0000-0000-0000-0000000000a5' from reseller_row),
  'عائدية RESELLER صريحة خارج ٩٤–١١٩ — نطاق وكيل بمعرّف eo.agent_id')
union all
select pg_temp.ok(
  (select (r->>'scope_type') = 'AGENT' and r->>'scope_id' is null from direct_row),
  'عائدية DIRECT_COMPANY صريحة — صفر وكيل رغم عائدية حالية لوكيلٍ آخر')
union all
select pg_temp.ok(
  (select (r->>'scope_type') = 'AGENT' and r->>'scope_id' is null from review_row),
  'عائدية NEEDS_REVIEW صريحة — صفر وكيل، لا وراثة وكيل حالي')
union all
select pg_temp.ok(
  (select (r->>'scope_type') = 'AGENT'
     and (r->>'scope_id') = '66000000-0000-0000-0000-0000000000a5' from fallback_row),
  'بلا فترة عائدية صريحة — احتياط subscriber_identities يبقى كما كان');

with scoped as (
  select public.page_activation_corrections(
    p_cycle_id => '66000000-0000-0000-0000-0000000000a2',
    p_scope_type => 'AGENT', p_scope_id => '66000000-0000-0000-0000-0000000000a5',
    p_limit => 50, p_offset => 0) as doc
),
scoped_tiny as (
  select public.page_activation_corrections(
    p_cycle_id => '66000000-0000-0000-0000-0000000000a2',
    p_scope_type => 'AGENT', p_scope_id => '66000000-0000-0000-0000-0000000000a5',
    p_limit => 1, p_offset => 0) as doc
)
select pg_temp.ok(
  exists (select 1 from scoped, jsonb_array_elements(doc->'rows') r
          where r->>'subscriber' = 'b3ak-sub-reseller'),
  'تصفية بمعرّف وكيل خارج ٩٤–١١٩ تُعيد الإضافة اليدوية المطابقة')
union all
select pg_temp.ok(
  (select (doc->>'active_additions')::int from scoped) = 2,
  'active_additions للتصفية بوكيل يُحسب على كامل المجموعة المُرشَّحة، لا الصفحة')
union all
select pg_temp.ok(
  (select (doc->>'active_additions')::int from scoped_tiny) = 2
    and (select jsonb_array_length(doc->'rows') from scoped_tiny) = 1,
  'وصفحة صغيرة من نفس التصفية لا تُغيّر الإجمالي رغم صفٍّ واحد فقط بالنتيجة');

reset role;
rollback;
