-- الدورة العاملة، والمسوّدة الفارغة.
--
-- في الإنتاج فُتحت مسوّدة آب بلا حساب، فورثت مكان تموز في كل قراءة
-- افتراضية وأعادت الشاشات أصفاراً. الخطأ لم يكن في المال بل في اختيار
-- الدورة — وهو نوعٌ لا يُلتقط بمقارنة أرقام لأن الأرقام المُعادة صحيحة
-- لدورةٍ خاطئة.
--
-- ولذلك يُقاس هنا **أيّ دورة تُختار**، لا كم تساوي.
--
-- معزول بنطاق تسمية CC-.

\set ON_ERROR_STOP on
\pset tuples_only on

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns text language sql as $$
  select case when p_cond then '                  ok ' || p_label else 'FAILED: ' || p_label end;
$$;

begin;

select '                 == current cycle and draft lifecycle ==';

insert into auth.users (id, email) values
  ('cc000000-0000-0000-0000-0000000000a1', 'cc-admin@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active) values
  ('cc000000-0000-0000-0000-0000000000a1','CCA','cc-admin@fixture.invalid','admin',true)
on conflict (id) do update set role = 'admin', is_active = true;

-- تموز: قيد المراجعة وقد حُسبت. آب: مسوّدة فارغة، أحدث فترةً.
insert into public.commission_cycles
  (id, name, period_start, period_end, status, engine_version, created_by, calculated_at)
values
  ('cc000000-0000-0000-0000-0000000000b1','CC تموز',
   date '2027-07-01', date '2027-07-31','UNDER_REVIEW','VNEXT',
   'cc000000-0000-0000-0000-0000000000a1', now()),
  ('cc000000-0000-0000-0000-0000000000b2','CC آب',
   date '2027-08-01', date '2027-08-31','DRAFT','VNEXT',
   'cc000000-0000-0000-0000-0000000000a1', null)
on conflict do nothing;

-- ------------------------------------------------------------------
-- ١ · مسوّدة فارغة أحدث لا ترث مكان دورةٍ قيد المراجعة
-- ------------------------------------------------------------------

select pg_temp.ok(
  public.current_commission_cycle_id() = 'cc000000-0000-0000-0000-0000000000b1',
  'الافتراضي تموزُ قيد المراجعة، لا مسوّدة آب الفارغة وإن كانت أحدث');

select pg_temp.ok(
  public.commission_cycle_is_operative('DRAFT', null) = false,
  'المسوّدة بلا حساب ليست عاملة');

select pg_temp.ok(
  public.commission_cycle_is_operative('UNDER_REVIEW', null) = true,
  'وما تجاوز المسوّدة عاملٌ ولو لم يُحسب بعد');

-- والقاعدة القديمة كانت تختار آب. تُثبَت العلّة صراحةً كي لا تعود.
select pg_temp.ok(
  (select id from public.commission_cycles
   where id in ('cc000000-0000-0000-0000-0000000000b1','cc000000-0000-0000-0000-0000000000b2')
   order by period_start desc limit 1) = 'cc000000-0000-0000-0000-0000000000b2',
  'القاعدة القديمة (أحدث period_start) كانت تعيد آب — هذه هي العلّة نفسها');

-- ------------------------------------------------------------------
-- ٢ · آب تبقى قابلةً للفتح صراحةً
-- ------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claim.sub = 'cc000000-0000-0000-0000-0000000000a1';

select pg_temp.ok(
  (public.commission_cycle_result('cc000000-0000-0000-0000-0000000000b2')->>'found') = 'true',
  'اختيار آب صراحةً ما زال ممكناً');

select pg_temp.ok(
  (public.commission_cycle_result('cc000000-0000-0000-0000-0000000000b2')
     ->'cycle'->>'id') = 'cc000000-0000-0000-0000-0000000000b2',
  'والشاشة تعرف أيّ دورة تعرض — المعرّف في العقد نفسه');

select pg_temp.ok(
  (public.commission_cycle_result(null)->'cycle'->>'id')
    = 'cc000000-0000-0000-0000-0000000000b1',
  'والقراءة الافتراضية تُسمّي تموز صراحةً لا ضمناً');

reset role;

-- ------------------------------------------------------------------
-- ٣ · دورةٌ لاحقة تدخل دورة حياتها فتتقدّم فعلاً
-- ------------------------------------------------------------------

update public.commission_cycles set calculated_at = now()
where id = 'cc000000-0000-0000-0000-0000000000b2';

select pg_temp.ok(
  public.current_commission_cycle_id() = 'cc000000-0000-0000-0000-0000000000b2',
  'آب إذا حُسبت صارت هي العاملة — التقدّم مشروع لا ممنوع');

update public.commission_cycles set calculated_at = null, status = 'DRAFT'
where id = 'cc000000-0000-0000-0000-0000000000b2';

select pg_temp.ok(
  public.current_commission_cycle_id() = 'cc000000-0000-0000-0000-0000000000b1',
  'وبإلغاء الحساب تعود تموز');

-- ------------------------------------------------------------------
-- ٤ · إلغاء المسوّدة الفارغة: بحجّة، ومُدقَّقاً، وبلا حذف
-- ------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claim.sub = 'cc000000-0000-0000-0000-0000000000a1';
select public.cancel_empty_commission_cycle(
  'cc000000-0000-0000-0000-0000000000b2', 'فُتحت سهواً', gen_random_uuid()) as cancelled \gset
reset role;

select pg_temp.ok(
  (select status from public.commission_cycles
   where id = 'cc000000-0000-0000-0000-0000000000b2') = 'CANCELLED',
  'المسوّدة أُلغيت');

select pg_temp.ok(
  exists (select 1 from public.commission_cycles
          where id = 'cc000000-0000-0000-0000-0000000000b2'),
  'وصفّها باقٍ — الإلغاء ليس حذفاً');

select pg_temp.ok(
  exists (select 1 from public.audit_logs
          where action = 'commission.cycle.cancelled'
            and entity_id = 'cc000000-0000-0000-0000-0000000000b2'
            and actor_id = 'cc000000-0000-0000-0000-0000000000a1'
            and old_value = 'DRAFT' and new_value = 'CANCELLED'
            and extra = 'فُتحت سهواً'),
  'ويُسجَّل من ألغاها ومتى ولماذا');

select pg_temp.ok(
  public.current_commission_cycle_id() = 'cc000000-0000-0000-0000-0000000000b1',
  'والملغاة لا تُختار عاملةً أبداً');

select pg_temp.ok(
  public.commission_cycle_is_operative('CANCELLED', now()) = false,
  'ولو حُسبت قبل إلغائها');

-- والفترة لا تبقى محجوزة: آب تُفتح من جديد.
set local role authenticated;
set local request.jwt.claim.sub = 'cc000000-0000-0000-0000-0000000000a1';
select public.open_commission_cycle(
  'CC آب من جديد', date '2027-08-01', date '2027-08-31', null, gen_random_uuid()) as reopened \gset
reset role;

select pg_temp.ok(
  (select count(*) from public.commission_cycles
   where period_start = date '2027-08-01' and status = 'DRAFT') = 1,
  'الفترة الملغاة تُفتح من جديد ولا تبقى محجوزة');

-- ------------------------------------------------------------------
-- ٥ · ما له أثر لا يُلغى
-- ------------------------------------------------------------------

insert into public.commission_cycles
  (id, name, period_start, period_end, status, engine_version, created_by)
values ('cc000000-0000-0000-0000-0000000000b3','CC أيلول',
        date '2027-09-01', date '2027-09-30','DRAFT','VNEXT',
        'cc000000-0000-0000-0000-0000000000a1')
on conflict do nothing;

insert into public.commission_exceptions
  (cycle_id, activation_event_id, subscriber_key, reason_code, detail, blocks_finalization)
values ('cc000000-0000-0000-0000-0000000000b3','CC-EV-1','cc-sub-1',
        'UNKNOWN_FDT','CC',true)
on conflict do nothing;

set local role authenticated;
set local request.jwt.claim.sub = 'cc000000-0000-0000-0000-0000000000a1';
do $cc$
begin
  perform public.cancel_empty_commission_cycle(
    'cc000000-0000-0000-0000-0000000000b3', 'محاولة', gen_random_uuid());
  raise exception 'CC-GUARD-DID-NOT-FIRE';
exception when sqlstate '42501' then
  null;
end $cc$;
reset role;

select pg_temp.ok(
  (select status from public.commission_cycles
   where id = 'cc000000-0000-0000-0000-0000000000b3') = 'DRAFT',
  'مسوّدة تحمل استثناءً واحداً لا تُلغى، وتبقى كما هي');

-- ودورةٌ تجاوزت المسوّدة لا تُلغى بهذا الباب أصلاً.
set local role authenticated;
set local request.jwt.claim.sub = 'cc000000-0000-0000-0000-0000000000a1';
do $cc$
begin
  perform public.cancel_empty_commission_cycle(
    'cc000000-0000-0000-0000-0000000000b1', 'محاولة', gen_random_uuid());
  raise exception 'CC-STATUS-GUARD-DID-NOT-FIRE';
exception when sqlstate '42501' then
  null;
end $cc$;
reset role;

select pg_temp.ok(
  (select status from public.commission_cycles
   where id = 'cc000000-0000-0000-0000-0000000000b1') = 'UNDER_REVIEW',
  'ودورةٌ قيد المراجعة لا تُلغى بباب المسوّدات');

-- ------------------------------------------------------------------
-- ٦ · لا دورة عاملة = لا نتيجة، لا صفرٌ مصطنع
-- ------------------------------------------------------------------

update public.commission_cycles
set status = 'DRAFT', calculated_at = null
where id in ('cc000000-0000-0000-0000-0000000000b1',
             'cc000000-0000-0000-0000-0000000000b3');
update public.commission_cycles set status = 'CANCELLED'
where period_start = date '2027-08-01';

select pg_temp.ok(
  public.current_commission_cycle_id() is null,
  'حين لا دورة عاملة، لا تُختار واحدة على سبيل التخمين');

set local role authenticated;
set local request.jwt.claim.sub = 'cc000000-0000-0000-0000-0000000000a1';

select pg_temp.ok(
  (public.commission_cycle_result(null)->>'found') = 'false',
  'والعقد يقول «لا نتيجة» صراحةً');

select pg_temp.ok(
  (public.commission_cycle_result(null) ? 'totals') = false,
  'ولا يُصنّع `totals` أصفاراً تُقرأ كأنها مال حقيقي');

select pg_temp.ok(
  (public.commission_cycle_product_result(null)->>'found') = 'false',
  'وعقد المنتج يقول الشيء نفسه — مصدرٌ واحد للحكم');

reset role;

rollback;
