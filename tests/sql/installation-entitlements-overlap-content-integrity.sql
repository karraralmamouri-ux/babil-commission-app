-- 20261102090000: an already-received logical file position must never
-- introduce different financial content on replay/overlap for
-- import_installation_entitlements — and the legacy IN_PROGRESS backfill
-- that upgrade requires.
--
-- معزول بملفه ومعاملته ونطاق تسمية OC-.

\set ON_ERROR_STOP on
\pset tuples_only on

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns text language sql as $$
  select case when p_cond then '   ok ' || p_label else 'FAILED: ' || p_label end;
$$;

create or replace function pg_temp.must_fail_code(p_sql text, p_label text, p_sqlstate text)
returns text language plpgsql as $$
begin
  execute p_sql;
  return 'FAILED: ' || p_label || ' — مرّ وكان يجب أن يُرفض';
exception when others then
  if p_sqlstate is not null and sqlstate <> p_sqlstate then
    return 'FAILED: ' || p_label || ' — الرمز ' || sqlstate || ' لا ' || p_sqlstate || ' (' || sqlerrm || ')';
  end if;
  return '   ok ' || p_label;
end;
$$;

create or replace function pg_temp.act_as(p_user uuid)
returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', p_user::text, true); end;
$$;

begin;

select '   == installation entitlements overlap content integrity ==';

insert into auth.users (id, email) values
  ('fc000000-0000-0000-0000-0000000000a1', 'oc-admin-a@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active) values
  ('fc000000-0000-0000-0000-0000000000a1','OC Admin A','oc-admin-a@fixture.invalid','admin',true)
on conflict (id) do update set role = 'admin', is_active = true;

select pg_temp.act_as('fc000000-0000-0000-0000-0000000000a1');

-- ---------------------------------------------------------------------
-- ١-٢ · إعادة تشغيلٍ كاملة (المدى الوارد بأكمله مُستقبَلٌ سابقاً)
-- ---------------------------------------------------------------------

select (public.import_installation_entitlements('2026-12','oc-full.xlsx','oc-sha-full',
  jsonb_build_array(
    jsonb_build_object('subscriber_id','OC-FULL-1','reseller','OC-FULL','remaining',13000),
    jsonb_build_object('subscriber_id','OC-FULL-2','reseller','OC-FULL','remaining',13000)
  ), gen_random_uuid(), null, 4, false, 0) -> 'batch') as oc_full_c1 \gset

select (:'oc_full_c1'::jsonb ->> 'batch_id') as oc_full_batch_id \gset

-- ١: إعادةٌ كاملة بنفس المحتوى — لا تغيير.
select (public.import_installation_entitlements('2026-12','oc-full.xlsx','oc-sha-full',
  jsonb_build_array(
    jsonb_build_object('subscriber_id','OC-FULL-1','reseller','OC-FULL','remaining',13000),
    jsonb_build_object('subscriber_id','OC-FULL-2','reseller','OC-FULL','remaining',13000)
  ), gen_random_uuid(), (:'oc_full_batch_id')::uuid, 4, false, 0) -> 'batch') as oc_full_c2 \gset

select pg_temp.ok(
  (:'oc_full_c2'::jsonb ->> 'source_rows')::int = 0
    and (:'oc_full_c2'::jsonb ->> 'accepted')::int = 0
    and (select source_rows = 2 and accepted_rows = 2 from public.installation_batches
         where id = (:'oc_full_batch_id')::uuid),
  'إعادةٌ كاملةٌ بنفس المحتوى بالضبط: لا تغيير في source_rows ولا accepted_rows');

-- ٢: إعادةٌ كاملة نفس المدى لكن بمحتوىً مختلفٍ تماماً (هوية مشتركٍ مختلفة) —
-- يجب ألا تُدخِل أيّ استحقاقٍ جديد إطلاقاً، لأن v_new_length=0 يُسقِط
-- الاستيعاب كلّه قبل أن يُقرأ محتوى الصفوف حتى.
select (public.import_installation_entitlements('2026-12','oc-full.xlsx','oc-sha-full',
  jsonb_build_array(
    jsonb_build_object('subscriber_id','OC-FULL-CHANGED-1','reseller','OC-FULL','remaining',13000),
    jsonb_build_object('subscriber_id','OC-FULL-CHANGED-2','reseller','OC-FULL','remaining',13000)
  ), gen_random_uuid(), (:'oc_full_batch_id')::uuid, 4, false, 0) -> 'batch') as oc_full_c3 \gset

select pg_temp.ok(
  (:'oc_full_c3'::jsonb ->> 'source_rows')::int = 0
    and (:'oc_full_c3'::jsonb ->> 'accepted')::int = 0
    and (select source_rows = 2 and accepted_rows = 2 from public.installation_batches
         where id = (:'oc_full_batch_id')::uuid)
    and not exists (select 1 from public.installation_entitlements
                     where subscriber_id in ('OC-FULL-CHANGED-1','OC-FULL-CHANGED-2')),
  'إعادةٌ كاملةٌ بمحتوىً مختلفٍ (هويةٌ مختلفة): لا استحقاق جديد يُدخَل إطلاقاً');

-- ---------------------------------------------------------------------
-- ٣ · تراكبٌ جزئي بنفس المحتوى المتراكب: المواضع الجديدة فقط تُعالَج.
-- ---------------------------------------------------------------------

select (public.import_installation_entitlements('2026-12','oc-part.xlsx','oc-sha-part',
  jsonb_build_array(
    jsonb_build_object('subscriber_id','OC-PART-1','reseller','OC-PART','remaining',13000),
    jsonb_build_object('subscriber_id','OC-PART-2','reseller','OC-PART','remaining',13000),
    jsonb_build_object('subscriber_id','OC-PART-3','reseller','OC-PART','remaining',13000)
  ), gen_random_uuid(), null, 6, false, 0) -> 'batch') as oc_part_c1 \gset

select (:'oc_part_c1'::jsonb ->> 'batch_id') as oc_part_batch_id \gset

select (public.import_installation_entitlements('2026-12','oc-part.xlsx','oc-sha-part',
  jsonb_build_array(
    jsonb_build_object('subscriber_id','OC-PART-2','reseller','OC-PART','remaining',13000),
    jsonb_build_object('subscriber_id','OC-PART-3','reseller','OC-PART','remaining',13000),
    jsonb_build_object('subscriber_id','OC-PART-4','reseller','OC-PART','remaining',13000),
    jsonb_build_object('subscriber_id','OC-PART-5','reseller','OC-PART','remaining',13000)
  ), gen_random_uuid(), (:'oc_part_batch_id')::uuid, 6, false, 1) -> 'batch') as oc_part_c2 \gset

select pg_temp.ok(
  (:'oc_part_c2'::jsonb ->> 'source_rows')::int = 2
    and (:'oc_part_c2'::jsonb ->> 'accepted')::int = 2
    and (select count(*) = 5 from public.installation_entitlements where reseller = 'OC-PART'),
  'تراكبٌ جزئي بنفس المحتوى المتراكب: المواضع الجديدة فقط (٢) عُولجت — خمسة صفوفٍ محفوظة');

-- ---------------------------------------------------------------------
-- ٤ · تراكبٌ جزئي بمحتوىً مختلفٍ في المواضع المتراكبة — جوهر العائق.
-- ---------------------------------------------------------------------

select (public.import_installation_entitlements('2026-12','oc-diff.xlsx','oc-sha-diff',
  jsonb_build_array(
    jsonb_build_object('subscriber_id','OC-DIFF-1','reseller','OC-DIFF','remaining',13000),
    jsonb_build_object('subscriber_id','OC-DIFF-2','reseller','OC-DIFF','remaining',13000),
    jsonb_build_object('subscriber_id','OC-DIFF-3','reseller','OC-DIFF','remaining',13000)
  ), gen_random_uuid(), null, 5, false, 0) -> 'batch') as oc_diff_c1 \gset

select (:'oc_diff_c1'::jsonb ->> 'batch_id') as oc_diff_batch_id \gset

-- موضع ١-٤: الموضعان ١ و٢ سبق استقبالهما (بمحتوى OC-DIFF-2/3) لكن هذا
-- النداء يحمل لهما هويةً مختلفةً تماماً (OC-DIFF-CHANGED-*)؛ الموضعان ٣و٤
-- جديدان فعلياً. المطلوب: التغيير في الموضعين ١و٢ لا يُقرأ ولا يُدخَل
-- إطلاقاً، وsource_rows يزيد بمقدار الجديد الحقيقي (٢) لا طول النداء (٤).
select (public.import_installation_entitlements('2026-12','oc-diff.xlsx','oc-sha-diff',
  jsonb_build_array(
    jsonb_build_object('subscriber_id','OC-DIFF-CHANGED-2','reseller','OC-DIFF','remaining',13000),
    jsonb_build_object('subscriber_id','OC-DIFF-CHANGED-3','reseller','OC-DIFF','remaining',13000),
    jsonb_build_object('subscriber_id','OC-DIFF-4','reseller','OC-DIFF','remaining',13000),
    jsonb_build_object('subscriber_id','OC-DIFF-5','reseller','OC-DIFF','remaining',13000)
  ), gen_random_uuid(), (:'oc_diff_batch_id')::uuid, 5, false, 1) -> 'batch') as oc_diff_c2 \gset

select pg_temp.ok(
  (:'oc_diff_c2'::jsonb ->> 'source_rows')::int = 2
    and (:'oc_diff_c2'::jsonb ->> 'accepted')::int = 2
    and (select source_rows = 5 from public.installation_batches where id = (:'oc_diff_batch_id')::uuid),
  'تراكبٌ جزئي بمحتوىً مختلف: source_rows يزيد بالجديد الحقيقي فقط (٢) لا طول النداء (٤)');

select pg_temp.ok(
  not exists (select 1 from public.installation_entitlements
              where subscriber_id in ('OC-DIFF-CHANGED-2','OC-DIFF-CHANGED-3'))
    and (select count(*) = 5 from public.installation_entitlements where reseller = 'OC-DIFF'),
  'محتوىً مختلفٌ لموضعٍ سبق استقباله لا يُدخَل ولا يُبدِّل شيئاً — خمسة صفوفٍ أصلية محفوظة فقط');

-- ---------------------------------------------------------------------
-- ٥ · تراكبٌ متداخل: جزءٌ يقع بأكمله ضمن مدىً سابق، ثم جزءٌ يتراكب جزئياً.
-- ---------------------------------------------------------------------

select (public.import_installation_entitlements('2026-12','oc-nest.xlsx','oc-sha-nest',
  jsonb_build_array(
    jsonb_build_object('subscriber_id','OC-NEST-1','reseller','OC-NEST','remaining',13000),
    jsonb_build_object('subscriber_id','OC-NEST-2','reseller','OC-NEST','remaining',13000),
    jsonb_build_object('subscriber_id','OC-NEST-3','reseller','OC-NEST','remaining',13000),
    jsonb_build_object('subscriber_id','OC-NEST-4','reseller','OC-NEST','remaining',13000),
    jsonb_build_object('subscriber_id','OC-NEST-5','reseller','OC-NEST','remaining',13000)
  ), gen_random_uuid(), null, 8, false, 0) -> 'batch') as oc_nest_c1 \gset

select (:'oc_nest_c1'::jsonb ->> 'batch_id') as oc_nest_batch_id \gset

-- موضع ٢ فقط (ضمن [0,5) المُستقبل بأكمله) — لا شيء جديد.
select (public.import_installation_entitlements('2026-12','oc-nest.xlsx','oc-sha-nest',
  jsonb_build_array(jsonb_build_object('subscriber_id','OC-NEST-3','reseller','OC-NEST','remaining',13000)),
  gen_random_uuid(), (:'oc_nest_batch_id')::uuid, 8, false, 2) -> 'batch') as oc_nest_c2 \gset

select pg_temp.ok(
  (:'oc_nest_c2'::jsonb ->> 'source_rows')::int = 0
    and (select source_rows = 5 from public.installation_batches where id = (:'oc_nest_batch_id')::uuid),
  'تراكبٌ متداخلٌ بأكمله ضمن مدىً سابق: لا جديد إطلاقاً');

-- موضع ٤-٨: الموضع ٤ سبق استقباله، ٥-٧ جديدة.
select (public.import_installation_entitlements('2026-12','oc-nest.xlsx','oc-sha-nest',
  jsonb_build_array(
    jsonb_build_object('subscriber_id','OC-NEST-5','reseller','OC-NEST','remaining',13000),
    jsonb_build_object('subscriber_id','OC-NEST-6','reseller','OC-NEST','remaining',13000),
    jsonb_build_object('subscriber_id','OC-NEST-7','reseller','OC-NEST','remaining',13000),
    jsonb_build_object('subscriber_id','OC-NEST-8','reseller','OC-NEST','remaining',13000)
  ), gen_random_uuid(), (:'oc_nest_batch_id')::uuid, 8, true, 4) -> 'batch') as oc_nest_c3 \gset

select pg_temp.ok(
  (:'oc_nest_c3'::jsonb ->> 'source_rows')::int = 3
    and (:'oc_nest_c3'::jsonb ->> 'status') = 'completed'
    and (select source_rows = 8 and status = 'completed'
         from public.installation_batches where id = (:'oc_nest_batch_id')::uuid),
  'تراكبٌ متداخلٌ جزئياً بعد تداخلٍ كامل: الجديد فقط (٣) يكمل العدد وتُنهى الدفعة');

-- ---------------------------------------------------------------------
-- ٦ · أجزاءٌ خارج الترتيب: اللاحق أولاً ثم السابق — التغطية تصحّ بأيّ ترتيب.
-- ---------------------------------------------------------------------

select (public.import_installation_entitlements('2026-12','oc-ooo.xlsx','oc-sha-ooo',
  jsonb_build_array(
    jsonb_build_object('subscriber_id','OC-OOO-4','reseller','OC-OOO','remaining',13000),
    jsonb_build_object('subscriber_id','OC-OOO-5','reseller','OC-OOO','remaining',13000),
    jsonb_build_object('subscriber_id','OC-OOO-6','reseller','OC-OOO','remaining',13000)
  ), gen_random_uuid(), null, 6, false, 3) -> 'batch') as oc_ooo_c1 \gset

select (:'oc_ooo_c1'::jsonb ->> 'batch_id') as oc_ooo_batch_id \gset

select (public.import_installation_entitlements('2026-12','oc-ooo.xlsx','oc-sha-ooo',
  jsonb_build_array(
    jsonb_build_object('subscriber_id','OC-OOO-1','reseller','OC-OOO','remaining',13000),
    jsonb_build_object('subscriber_id','OC-OOO-2','reseller','OC-OOO','remaining',13000),
    jsonb_build_object('subscriber_id','OC-OOO-3','reseller','OC-OOO','remaining',13000)
  ), gen_random_uuid(), (:'oc_ooo_batch_id')::uuid, 6, true, 0) -> 'batch') as oc_ooo_c2 \gset

select pg_temp.ok(
  (:'oc_ooo_c2'::jsonb ->> 'status') = 'completed'
    and (select source_rows = 6 and status = 'completed'
         from public.installation_batches where id = (:'oc_ooo_batch_id')::uuid)
    and (select count(*) = 6 from public.installation_entitlements where reseller = 'OC-OOO'),
  'الجزء اللاحق أولاً ثم السابق: التغطية تكتمل وتُنهى الدفعة بصرف النظر عن الترتيب');

-- ---------------------------------------------------------------------
-- ٧ · فجوة: الإنهاء يفشل حتى تُملأ [0, expected_rows) بأكملها.
-- ---------------------------------------------------------------------

select (public.import_installation_entitlements('2026-12','oc-gap.xlsx','oc-sha-gap',
  jsonb_build_array(
    jsonb_build_object('subscriber_id','OC-GAP-1','reseller','OC-GAP','remaining',13000),
    jsonb_build_object('subscriber_id','OC-GAP-2','reseller','OC-GAP','remaining',13000)
  ), gen_random_uuid(), null, 5, false, 0) -> 'batch') as oc_gap_c1 \gset

select (:'oc_gap_c1'::jsonb ->> 'batch_id') as oc_gap_batch_id \gset

-- موضع ٣-٤ (يترك موضع ٢ فجوةً بينهما).
select (public.import_installation_entitlements('2026-12','oc-gap.xlsx','oc-sha-gap',
  jsonb_build_array(
    jsonb_build_object('subscriber_id','OC-GAP-4','reseller','OC-GAP','remaining',13000),
    jsonb_build_object('subscriber_id','OC-GAP-5','reseller','OC-GAP','remaining',13000)
  ), gen_random_uuid(), (:'oc_gap_batch_id')::uuid, 5, false, 3) -> 'batch') as oc_gap_c2 \gset

-- محاولة إنهاءٍ بإعادة موضعٍ سبق استقباله (لا يملأ الفجوة) — يُرفض: العدد ٤ لا ٥.
select pg_temp.must_fail_code(
  format($q$select public.import_installation_entitlements('2026-12','oc-gap.xlsx','oc-sha-gap',
      '[{"subscriber_id":"OC-GAP-1","reseller":"OC-GAP","remaining":13000}]'::jsonb,
      gen_random_uuid(), %L::uuid, 5, true, 0)$q$, :'oc_gap_batch_id'),
  'إنهاءٌ محاولٌ بفجوةٍ لم تُملأ (موضع ٢ ناقص): يُرفض رغم إعادة إرسال موضعٍ آخر',
  '22023');

select pg_temp.ok(
  (select source_rows = 4 and status = 'in_progress'
   from public.installation_batches where id = (:'oc_gap_batch_id')::uuid),
  'محاولة الإنهاء الفاشلة لم تُغيّر شيئاً — لا تزال ٤ من ٥');

-- ملء الفجوة الحقيقية (موضع ٢) مع الإنهاء — ينجح الآن.
select ((public.import_installation_entitlements('2026-12','oc-gap.xlsx','oc-sha-gap',
  '[{"subscriber_id":"OC-GAP-3","reseller":"OC-GAP","remaining":13000}]'::jsonb,
  gen_random_uuid(), (:'oc_gap_batch_id')::uuid, 5, true, 2) -> 'batch') ->> 'status') as oc_gap_final \gset

select pg_temp.ok(
  :'oc_gap_final' = 'completed'
    and (select source_rows = 5 and status = 'completed'
         from public.installation_batches where id = (:'oc_gap_batch_id')::uuid)
    and (select count(*) = 5 from public.installation_entitlements where reseller = 'OC-GAP'),
  'ملء الفجوة الحقيقية (موضع ٢) مع الإنهاء: ينجح الآن — خمسة صفوفٍ كاملة');

-- ---------------------------------------------------------------------
-- ٨-٩ · موضعٌ سالب، ومدىً وارد يتجاوز expected_rows — كلاهما يُرفض.
-- ---------------------------------------------------------------------

select (public.import_installation_entitlements('2026-12','oc-bounds.xlsx','oc-sha-bounds',
  '[{"subscriber_id":"OC-BOUNDS-1","reseller":"OC-BOUNDS","remaining":13000}]'::jsonb,
  gen_random_uuid(), null, 3, false, 0) -> 'batch' ->> 'batch_id') as oc_bounds_batch_id \gset

select pg_temp.must_fail_code(
  format($q$select public.import_installation_entitlements('2026-12','oc-bounds.xlsx','oc-sha-bounds',
      '[{"subscriber_id":"OC-BOUNDS-2","reseller":"OC-BOUNDS","remaining":13000}]'::jsonb,
      gen_random_uuid(), %L::uuid, 3, false, -1)$q$, :'oc_bounds_batch_id'),
  'موضعٌ سالب (p_row_offset=-1) يُرفض',
  '22023');

select pg_temp.must_fail_code(
  format($q$select public.import_installation_entitlements('2026-12','oc-bounds.xlsx','oc-sha-bounds',
      '[{"subscriber_id":"OC-BOUNDS-2","reseller":"OC-BOUNDS","remaining":13000},
        {"subscriber_id":"OC-BOUNDS-3","reseller":"OC-BOUNDS","remaining":13000},
        {"subscriber_id":"OC-BOUNDS-4","reseller":"OC-BOUNDS","remaining":13000}]'::jsonb,
      gen_random_uuid(), %L::uuid, 3, false, 1)$q$, :'oc_bounds_batch_id'),
  'مدىً وارد يتجاوز الحدّ العلويّ لـ expected_rows (١+٣ > ٣) يُرفض',
  '22023');

select pg_temp.ok(
  (select source_rows = 1 and status = 'in_progress'
   from public.installation_batches where id = (:'oc_bounds_batch_id')::uuid),
  'محاولتا الحدود الخاطئتان لم تُغيّرا شيئاً في الدفعة');

-- ---------------------------------------------------------------------
-- ١٠ · دفعةٌ مكتملة ترفض أيّ استئنافٍ.
-- ---------------------------------------------------------------------

select ((public.import_installation_entitlements('2026-12','oc-bounds.xlsx','oc-sha-bounds',
  '[{"subscriber_id":"OC-BOUNDS-2","reseller":"OC-BOUNDS","remaining":13000},
    {"subscriber_id":"OC-BOUNDS-3","reseller":"OC-BOUNDS","remaining":13000}]'::jsonb,
  gen_random_uuid(), (:'oc_bounds_batch_id')::uuid, 3, true, 1) -> 'batch') ->> 'status') as oc_bounds_final \gset

select pg_temp.ok(:'oc_bounds_final' = 'completed', 'الدفعة تُنهى بنجاح تمهيداً لاختبار رفض استئنافها');

select pg_temp.must_fail_code(
  format($q$select public.import_installation_entitlements('2026-12','oc-bounds.xlsx','oc-sha-bounds',
      '[{"subscriber_id":"OC-BOUNDS-9","reseller":"OC-BOUNDS","remaining":13000}]'::jsonb,
      gen_random_uuid(), %L::uuid)$q$, :'oc_bounds_batch_id'),
  'دفعةٌ مكتملة ترفض أيّ استئنافٍ',
  '22023');

-- ---------------------------------------------------------------------
-- ترحيل: دفعةٌ IN_PROGRESS بشكل العقد القديم (received_rows فارغة رغم
-- source_rows > 0) — نفس عبارة الترحيل في 20261102090000 حرفياً تُطبَّق
-- هنا على صفٍّ اصطناعيٍّ يُحاكي ما خلّفه العقد القديم، إثباتاً لسلامتها.
-- ---------------------------------------------------------------------

insert into public.installation_batches (
  id, period, file_name, file_checksum, created_by, expected_rows,
  source_rows, accepted_rows, status
) values (
  'fc000000-1111-0000-0000-0000000000b1', '2026-12', 'oc-legacy.xlsx', 'oc-sha-legacy',
  'fc000000-0000-0000-0000-0000000000a1', 5, 3, 3, 'in_progress'
);

select pg_temp.ok(
  (select received_rows = '{}'::int8multirange from public.installation_batches
   where id = 'fc000000-1111-0000-0000-0000000000b1'),
  'ضبط الاختبار: الدفعة الاصطناعية القديمة received_rows فارغة رغم source_rows=3');

update public.installation_batches
set received_rows = int8multirange(int8range(0, source_rows))
where status = 'in_progress'
  and source_rows > 0
  and received_rows = '{}'::int8multirange
  and id = 'fc000000-1111-0000-0000-0000000000b1';

select pg_temp.ok(
  (select received_rows = int8multirange(int8range(0,3)) from public.installation_batches
   where id = 'fc000000-1111-0000-0000-0000000000b1'),
  'ترحيل الدفعة القديمة: received_rows تصبح [0,3) بالضبط بعد عبارة الترحيل');

-- إعادة إرسال المواضع ٠-٣ بمحتوىً مختلف بعد الترحيل: لا شيء يتغيّر (مرحَّلة
-- بأمان)، والجديد الحقيقي (موضع ٣-٥) فقط يُستقبل.
select (public.import_installation_entitlements('2026-12','oc-legacy.xlsx','oc-sha-legacy',
  jsonb_build_array(
    jsonb_build_object('subscriber_id','OC-LEGACY-CHANGED-1','reseller','OC-LEGACY','remaining',13000),
    jsonb_build_object('subscriber_id','OC-LEGACY-CHANGED-2','reseller','OC-LEGACY','remaining',13000),
    jsonb_build_object('subscriber_id','OC-LEGACY-CHANGED-3','reseller','OC-LEGACY','remaining',13000),
    jsonb_build_object('subscriber_id','OC-LEGACY-4','reseller','OC-LEGACY','remaining',13000),
    jsonb_build_object('subscriber_id','OC-LEGACY-5','reseller','OC-LEGACY','remaining',13000)
  ), gen_random_uuid(), 'fc000000-1111-0000-0000-0000000000b1'::uuid, 5, true, 0) -> 'batch') as oc_legacy_c1 \gset

select pg_temp.ok(
  (:'oc_legacy_c1'::jsonb ->> 'source_rows')::int = 2
    and (:'oc_legacy_c1'::jsonb ->> 'status') = 'completed'
    and not exists (select 1 from public.installation_entitlements
                     where subscriber_id like 'OC-LEGACY-CHANGED-%')
    and (select count(*) = 2 from public.installation_entitlements where reseller = 'OC-LEGACY'),
  'دفعةٌ قديمةٌ مُرحَّلة: المواضع ٠-٢ محميةٌ فعلياً بعد الترحيل — الجديد الحقيقي (موضع ٣-٤) فقط يُستقبل وتُنهى الدفعة');

rollback;
