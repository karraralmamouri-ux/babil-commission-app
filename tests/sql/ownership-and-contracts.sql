-- العائدية تُحسم قبل قواعد الوكيل، والعقود تُنتج ما تَعِد به.
--
-- ثلاثة أحكام يحرسها هذا الملف:
--
--   ١ · التابع للشركة يخرج من المال ومن الحواجب معاً. كان يخرج من الأول
--       ويبقى في الثاني: 18,508 حاجباً من 22,723 لا يخصّ الوكلاء في شيء.
--
--   ٢ · قائمة الوكلاء تُعيد الوكلاء الفعّالين. كانت ترشّح 'ACTIVE' والقيد
--       لا يقبل إلا 'active'، فتنجح وتعيد صفراً — ولا خطأ يُلتقط.
--
--   ٣ · نتيجة الدورة كائنٌ واحد فيه `totals`. كانت الشاشة تقرأ `totals` من
--       دالّةٍ تُعيد جدولاً، فتحصل على `undefined` دائماً.
--
-- معزول بنطاق تسمية OC-.

\set ON_ERROR_STOP on
\pset tuples_only on

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns text language sql as $$
  select case when p_cond then '                ok ' || p_label else 'FAILED: ' || p_label end;
$$;

begin;

select '               == ownership and contracts ==';

insert into auth.users (id, email) values
  ('0c000000-0000-0000-0000-0000000000a1', 'oc-admin@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active) values
  ('0c000000-0000-0000-0000-0000000000a1','OCA','oc-admin@fixture.invalid','admin',true)
on conflict (id) do update set role = 'admin', is_active = true;

-- ------------------------------------------------------------------
-- ٢ · قائمة الوكلاء: الحالة بحروف صغيرة كما يفرض القيد
-- ------------------------------------------------------------------

insert into public.agents (id, code, official_name, status)
values ('0c000000-0000-0000-0000-0000000000a4','OC-AG','وكيل OC','active'),
       ('0c000000-0000-0000-0000-0000000000a5','OC-OFF','وكيل موقوف','inactive')
on conflict (code) do nothing;

set local role authenticated;
set local request.jwt.claim.sub = '0c000000-0000-0000-0000-0000000000a1';

select pg_temp.ok(
  jsonb_array_length(public.list_agents_for_pick()) >= 1,
  'قائمة الوكلاء تُعيد الوكلاء الفعّالين لا مصفوفةً فارغة');

select pg_temp.ok(
  exists (select 1 from jsonb_array_elements(public.list_agents_for_pick()) a
          where a->>'code' = 'OC-AG'),
  'والوكيل الفعّال موجود فيها بالاسم');

select pg_temp.ok(
  not exists (select 1 from jsonb_array_elements(public.list_agents_for_pick()) a
              where a->>'code' = 'OC-OFF'),
  'والموقوف لا يظهر');

-- والمقارنة لا تُقيَّد بحالة أحرف بعينها: تغيير النطاق لاحقاً يجب ألّا
-- يُفرغ القائمة صامتاً كما حدث.
reset role;
select pg_temp.ok(
  (select prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'list_agents_for_pick')
    like '%lower(a.status)%',
  'والمقارنة غير حسّاسة لحالة الأحرف');

-- ------------------------------------------------------------------
-- ١ · التابع للشركة: لا مال ولا حاجب
-- ------------------------------------------------------------------

insert into public.commission_cycles
  (id, name, period_start, period_end, engine_version, created_by, status)
values ('0c000000-0000-0000-0000-0000000000a2','OC دورة',
        date '2027-07-01', date '2027-07-31','VNEXT',
        '0c000000-0000-0000-0000-0000000000a1','UNDER_REVIEW')
on conflict do nothing;

insert into public.saas_import_batches
  (id, source_kind, source_filename, source_checksum, parser_version, imported_by,
   completeness_status)
values ('0c000000-0000-0000-0000-0000000000a3','ACTIVATION_EVENTS','oc.xlsx',
        'oc-checksum','v1','0c000000-0000-0000-0000-0000000000a1','COMPLETE')
on conflict do nothing;

insert into public.packages (code, name, semantic_category)
values ('P-35000','P-35000','PAID_PACKAGE') on conflict (code) do nothing;

insert into public.agent_aliases (agent_id, alias, resolution)
values ('0c000000-0000-0000-0000-0000000000a4','oc.parent','mapped')
on conflict (alias_key) do nothing;

-- أربعة أحداث بكابينة مجهولة: اثنان لوكيل واثنان لتابعٍ مباشر للشركة.
insert into public.saas_activation_events
  (import_batch_id, saas_event_id, username, profile_name, canceled, raw_parent,
   event_created_at, fdt_code)
values
  ('0c000000-0000-0000-0000-0000000000a3','OC-R1','oc-res1','P-35000',false,'oc.parent','2027-07-05','OC-NOFDT'),
  ('0c000000-0000-0000-0000-0000000000a3','OC-R2','oc-res2','P-35000',false,'oc.parent','2027-07-06','OC-NOFDT'),
  ('0c000000-0000-0000-0000-0000000000a3','OC-D1','oc-dc1','P-35000',false,'oc.parent','2027-07-07','OC-NOFDT'),
  ('0c000000-0000-0000-0000-0000000000a3','OC-D2','oc-dc2','P-35000',false,'oc.parent','2027-07-08','OC-NOFDT')
on conflict do nothing;

insert into public.subscriber_identities
  (username, identity_status, match_method, source_classification, effective_agent_id)
values ('oc-res1','MATCHED','EXACT_USERNAME','RESELLER','0c000000-0000-0000-0000-0000000000a4'),
       ('oc-res2','MATCHED','EXACT_USERNAME','RESELLER','0c000000-0000-0000-0000-0000000000a4'),
       ('oc-dc1','MATCHED','EXACT_USERNAME','DIRECT_COMPANY',null),
       ('oc-dc2','MATCHED','EXACT_USERNAME','DIRECT_COMPANY',null)
on conflict do nothing;

set local role authenticated;
set local request.jwt.claim.sub = '0c000000-0000-0000-0000-0000000000a1';

select public.calculate_commission_cycle('0c000000-0000-0000-0000-0000000000a2', false);

-- بعد LIVE-02 نطاق العمولة يُحسم برقم الكابينة وحده — والوكيلان هنا معروفان
-- سلفاً بعائدية subscriber_identities، بصرف النظر عن تسجيل الكابينة. فلا
-- UNKNOWN_FDT يُنتَج بعد اليوم (أُسقطت الدالة نفسها)، ولا حتى UNKNOWN_AGENT:
-- العائدية وحدها كفت لحسم الوكيل لكلا الحدثين. البند الوحيد الباقي حقيقياً
-- هو الأصلي: التابع المباشر للشركة يبقى بلا حاجب ولا عمولة (أدناه).
select pg_temp.ok(
  not exists (
    select 1 from public.commission_exceptions
    where cycle_id = '0c000000-0000-0000-0000-0000000000a2' and status = 'OPEN'),
  'لا حاجب إطلاقاً: كابينة غير مسجَّلة لم تعد تمنع حسم عائديةٍ معروفة سلفاً');

-- subscriber_key هنا هو si.id (uuid المطابقة) لا اسم المستخدم — كل صف في
-- subscriber_identities يحمل id افتراضياً (gen_random_uuid()), فمطابقة
-- subscriber_key باسم المستخدم حرفياً لا تُطابق شيئاً أبداً. activation_event_id
-- هو المعرّف الثابت للحدث بصرف النظر عن حسم العائدية.
select pg_temp.ok(
  (select count(*) from public.commission_event_entitlements
   where cycle_id = '0c000000-0000-0000-0000-0000000000a2'
     and activation_event_id in ('OC-R1','OC-R2')) = 2,
  'وحدثا الوكيل يصيران مستحقين الآن — العائدية وحدها كفت، لا تسجيل الكابينة');

select pg_temp.ok(
  not exists (
    select 1 from public.commission_exceptions x
    join public.saas_activation_events e on e.saas_event_id = x.activation_event_id
    join public.subscriber_identities si on si.username_key = e.username_key
    where x.cycle_id = '0c000000-0000-0000-0000-0000000000a2'
      and x.status = 'OPEN'
      and si.source_classification = 'DIRECT_COMPANY'),
  'ولا حاجب واحد لتابعٍ مباشر في أي سبب');

-- نفس التنبيه: subscriber_key ليس اسم المستخدم، فالمطابقة الحرفية أدناه كانت
-- ستنجح صامتة حتى لو وُجد استحقاق فعلي لهذين الحدثين. activation_event_id
-- هو الاختبار الحقيقي لعدم استحقاقهما.
select pg_temp.ok(
  not exists (select 1 from public.commission_event_entitlements
              where cycle_id = '0c000000-0000-0000-0000-0000000000a2'
                and activation_event_id in ('OC-D1','OC-D2')),
  'والتابع للشركة لا تنشأ عنه عمولة — كما كان');

-- ------------------------------------------------------------------
-- ٣ · عقد نتيجة الدورة
-- ------------------------------------------------------------------

select pg_temp.ok(
  (public.commission_cycle_result('0c000000-0000-0000-0000-0000000000a2')->>'found') = 'true',
  'نتيجة الدورة كائنٌ واحد لا جدول');

select pg_temp.ok(
  jsonb_typeof(public.commission_cycle_result(
    '0c000000-0000-0000-0000-0000000000a2')->'totals') = 'object',
  'وفيه `totals` كائناً — وهو ما كانت الشاشة تقرأه ولا تجده');

select pg_temp.ok(
  (select count(*) from (select jsonb_object_keys(
     public.commission_cycle_result('0c000000-0000-0000-0000-0000000000a2')) k) z
   where k in ('cycle','totals','volumes','zones','agents',
               'unresolved_ownership','blockers')) = 7,
  'وفيه كل ما تحتاجه الشاشة في قراءةٍ واحدة');

-- والمصالحة تستقيم: المنسوب + المعلّق = الإجمالي.
select pg_temp.ok(
  (select (r->'totals'->>'gross')::bigint
          - coalesce((select sum((a->>'gross')::bigint)
                      from jsonb_array_elements(r->'agents') a), 0)
          - (r->'unresolved_ownership'->>'amount')::bigint
   from (select public.commission_cycle_result(
           '0c000000-0000-0000-0000-0000000000a2') r) d) = 0,
  'المنسوب لوكلاء معروفين + ما لم تُحسم عائديته = إجمالي الدورة');

reset role;

rollback;
