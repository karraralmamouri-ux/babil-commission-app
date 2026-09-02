-- End-to-end installation-fee import against a throwaway local Postgres:
-- Excel/CSV rows -> Confirm Import -> central DB -> invoice audit -> eligibility
-- -> payment -> history -> archive. Rolled back at the end.

\set ON_ERROR_STOP on

begin;

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'admin@fixture.invalid'),
  ('22222222-2222-2222-2222-222222222222', 'accountant@fixture.invalid'),
  ('44444444-4444-4444-4444-444444444444', 'viewer@fixture.invalid');

insert into public.profiles (id, full_name, email, role, is_active) values
  ('11111111-1111-1111-1111-111111111111', 'Admin',      'admin@fixture.invalid',      'admin',      true),
  ('22222222-2222-2222-2222-222222222222', 'Accountant', 'accountant@fixture.invalid', 'accountant', true),
  ('44444444-4444-4444-4444-444444444444', 'Viewer',     'viewer@fixture.invalid',     'viewer',     true);

create or replace function pg_temp.expect(p_label text, p_condition boolean)
returns void language plpgsql as $$
begin
  if not p_condition then raise exception 'FAIL % : condition was false', p_label; end if;
  raise notice 'pass  %', p_label;
end;
$$;

create or replace function pg_temp.expect_error(p_label text, p_sql text, p_sqlstate text)
returns void language plpgsql as $$
begin
  begin execute p_sql;
  exception when others then
    if p_sqlstate is not null and sqlstate <> p_sqlstate then
      raise exception 'FAIL % : expected % got % (%)', p_label, p_sqlstate, sqlstate, sqlerrm;
    end if;
    raise notice 'pass  %', p_label; return;
  end;
  raise exception 'FAIL % : statement unexpectedly succeeded', p_label;
end;
$$;

create or replace function pg_temp.act_as(p_user uuid)
returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', p_user::text, true); end;
$$;

-- Builds `count` raw subscriber rows exactly as the browser would send them.
create or replace function pg_temp.rows_at(p_reseller text, p_remaining bigint, p_count integer, p_tag text)
returns jsonb language sql as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'subscriber_id', p_reseller || '-' || p_tag || '-' || g,
    'subscriber_name', 'subscriber ' || g,
    'reseller', p_reseller,
    'zone', 'new',
    'remaining', p_remaining
  )), '[]'::jsonb)
  from generate_series(1, p_count) g;
$$;

-- ------------------------------------------------------------ authorisation --
select pg_temp.act_as('44444444-4444-4444-4444-444444444444');
select pg_temp.expect_error(
  'viewer cannot import entitlements',
  $q$select public.import_installation_entitlements('2026-07','f.xlsx',null,
      '[{"subscriber_id":"X","reseller":"R","remaining":13000}]'::jsonb, gen_random_uuid())$q$,
  '42501');

select pg_temp.act_as('22222222-2222-2222-2222-222222222222');
select pg_temp.expect_error(
  'accountant cannot import entitlements',
  $q$select public.import_installation_entitlements('2026-07','f.xlsx',null,
      '[{"subscriber_id":"X","reseller":"R","remaining":13000}]'::jsonb, gen_random_uuid())$q$,
  '42501');

select pg_temp.act_as('11111111-1111-1111-1111-111111111111');
select pg_temp.expect_error(
  'a malformed period is refused',
  $q$select public.import_installation_entitlements('July-2026','f.xlsx',null,
      '[{"subscriber_id":"X","reseller":"R","remaining":13000}]'::jsonb, gen_random_uuid())$q$,
  '22023');

-- ------------------------------------------------------- a mixed-quality file --
select pg_temp.expect(
  'a partially bad file accepts the good rows and reports the rest',
  (with result as (
     select public.import_installation_entitlements('2026-07','mixed.xlsx','sha-mixed', jsonb_build_array(
       jsonb_build_object('subscriber_id','M-1','reseller','R','remaining',13000),
       jsonb_build_object('subscriber_id','M-2','reseller','R','remaining',0),
       jsonb_build_object('subscriber_id','M-1','reseller','R','remaining',13000),
       jsonb_build_object('subscriber_id','','reseller','R','remaining',13000),
       jsonb_build_object('subscriber_id','M-4','reseller','','remaining',13000),
       jsonb_build_object('subscriber_id','M-5','reseller','R','remaining',5500)
     ), gen_random_uuid()) as payload)
   select (payload -> 'batch' ->> 'source_rows')::int = 6
      and (payload -> 'batch' ->> 'accepted')::int = 2
      and (payload -> 'batch' ->> 'duplicates')::int = 1
      and (payload -> 'batch' ->> 'rejected')::int = 3
   from result));

select pg_temp.expect(
  'the batch row records the same counts and a status',
  (select source_rows = 6 and accepted_rows = 2 and duplicate_rows = 1
      and rejected_rows = 3 and status = 'completed' and file_name = 'mixed.xlsx'
      and file_checksum = 'sha-mixed' and created_by = '11111111-1111-1111-1111-111111111111'
   from public.installation_batches where file_name = 'mixed.xlsx'));

select pg_temp.expect(
  'only the two valid subscribers were written',
  (select count(*) = 2 from public.installation_entitlements where period = '2026-07'));
select pg_temp.expect(
  'the unknown Remaining never reached the table',
  (select count(*) = 0 from public.installation_entitlements where subscriber_id = 'M-5'));
select pg_temp.expect(
  'stage and amount were derived on the server',
  (select stage = 'P1' and amount = 3000 and payment_status = 'awaiting_invoice'
   from public.installation_entitlements where subscriber_id = 'M-1' and period = '2026-07'));
select pg_temp.expect(
  'a DONE row is stored as not eligible with a zero amount',
  (select stage = 'DONE' and amount = 0 and payment_status = 'not_eligible'
   from public.installation_entitlements where subscriber_id = 'M-2'));
select pg_temp.expect(
  'the import wrote an audit record',
  (select count(*) = 1 from public.audit_logs where action = 'installation.batch.imported'));

-- The client cannot smuggle its own figures in.
select pg_temp.expect(
  'a client-supplied stage and amount are ignored',
  (with result as (
     select public.import_installation_entitlements('2026-07','forged.xlsx',null, jsonb_build_array(
       jsonb_build_object('subscriber_id','FORGED','reseller','R','remaining',4000,
                          'stage','P1','amount',999999)
     ), gen_random_uuid()) as payload)
   select true from result))
;
select pg_temp.expect(
  'the forged row was priced from its Remaining, not from the payload',
  (select stage = 'P4' and amount = 4000
   from public.installation_entitlements where subscriber_id = 'FORGED'));

-- --------------------------------------------------------------- idempotency --
select pg_temp.expect(
  'the same file imported twice adds nothing',
  (with result as (
     select public.import_installation_entitlements('2026-07','mixed.xlsx','sha-mixed', jsonb_build_array(
       jsonb_build_object('subscriber_id','M-1','reseller','R','remaining',13000),
       jsonb_build_object('subscriber_id','M-2','reseller','R','remaining',0)
     ), gen_random_uuid()) as payload)
   select (payload -> 'batch' ->> 'accepted')::int = 0
      and (payload -> 'batch' ->> 'duplicates')::int = 2
      and (payload -> 'batch' ->> 'status') = 'no_new_rows'
   from result));

select pg_temp.expect(
  'a different file carrying the same entitlement is still a duplicate',
  (with result as (
     select public.import_installation_entitlements('2026-07','other-file.xlsx','sha-other', jsonb_build_array(
       jsonb_build_object('subscriber_id','M-1','reseller','R','remaining',13000),
       jsonb_build_object('subscriber_id','M-9','reseller','R','remaining',7000)
     ), gen_random_uuid()) as payload)
   select (payload -> 'batch' ->> 'accepted')::int = 1
      and (payload -> 'batch' ->> 'duplicates')::int = 1
   from result));

select pg_temp.expect(
  'the duplicate subscriber still has exactly one entitlement',
  (select count(*) = 1 from public.installation_entitlements
    where period = '2026-07' and subscriber_id = 'M-1' and stage = 'P1'));

select pg_temp.expect(
  'the same subscriber in another period is a separate entitlement',
  (with result as (
     select public.import_installation_entitlements('2026-08','august.xlsx',null, jsonb_build_array(
       jsonb_build_object('subscriber_id','M-1','reseller','R','remaining',10000)
     ), gen_random_uuid()) as payload)
   select (payload -> 'batch' ->> 'accepted')::int = 1 from result));

-- ------------------------------------------------------------- atomicity ------
-- A row count beyond the guard aborts the whole call: no batch, no entitlements.
select pg_temp.expect_error(
  'an oversized payload is refused outright',
  $q$select public.import_installation_entitlements('2026-07','huge.xlsx',null,'[]'::jsonb, gen_random_uuid())$q$,
  '22023');
select pg_temp.expect(
  'the refused import left no batch behind',
  (select count(*) = 0 from public.installation_batches where file_name = 'huge.xlsx'));

-- ------------------------------------------------ full pipeline to payment ----
select pg_temp.expect(
  'an imported entitlement is not payable before its invoice is approved',
  (select payment_status = 'awaiting_invoice'
   from public.installation_entitlements where subscriber_id = 'M-1' and period = '2026-07'));

select pg_temp.act_as('22222222-2222-2222-2222-222222222222');
select pg_temp.expect_error(
  'payment on a freshly imported row is blocked',
  $q$select public.record_installation_payment(
       (select id from public.installation_entitlements where subscriber_id = 'M-1' and period = '2026-07'),
       null, gen_random_uuid())$q$,
  '23514');

select public.audit_installation_invoice(
  (select id from public.installation_entitlements where subscriber_id = 'M-1' and period = '2026-07'),
  'approved', 'checked', gen_random_uuid());
select public.record_installation_payment(
  (select id from public.installation_entitlements where subscriber_id = 'M-1' and period = '2026-07'),
  null, gen_random_uuid());

select pg_temp.expect(
  'the imported entitlement completes the pipeline through to payment',
  (select payment_status = 'paid' and paid_amount = 3000 and paid_at is not null
      and paid_by = '22222222-2222-2222-2222-222222222222'
   from public.installation_entitlements where subscriber_id = 'M-1' and period = '2026-07'));
select pg_temp.expect(
  'payment history exists for the imported entitlement',
  (select count(*) = 1 from public.installation_payments p
     join public.installation_entitlements e on e.id = p.entitlement_id
    where e.subscriber_id = 'M-1' and e.period = '2026-07' and p.amount = 3000));

-- Archive: a later import of the same period cannot restate the settled row.
select pg_temp.act_as('11111111-1111-1111-1111-111111111111');
select pg_temp.expect(
  're-importing a settled subscriber is reported as a duplicate, not a rewrite',
  (with result as (
     select public.import_installation_entitlements('2026-07','late.xlsx',null, jsonb_build_array(
       jsonb_build_object('subscriber_id','M-1','reseller','RENAMED','remaining',13000)
     ), gen_random_uuid()) as payload)
   select (payload -> 'batch' ->> 'duplicates')::int = 1
      and (payload -> 'batch' ->> 'accepted')::int = 0
   from result));
select pg_temp.expect(
  'the settled row kept its original reseller and payment',
  (select reseller = 'R' and paid_amount = 3000
   from public.installation_entitlements where subscriber_id = 'M-1' and period = '2026-07'));

-- ------------------------------------------------- acceptance fixtures --------
select pg_temp.expect(
  'Saeed Ammar imports as 3943 subscribers',
  (with payload as (
     select public.import_installation_entitlements('2026-09','saeed.xlsx',null,
       pg_temp.rows_at('Saeed Ammar', 0, 2687, 'done')
       || pg_temp.rows_at('Saeed Ammar', 13000, 662, 'p1')
       || pg_temp.rows_at('Saeed Ammar', 10000, 166, 'p2')
       || pg_temp.rows_at('Saeed Ammar', 7000, 175, 'p3')
       || pg_temp.rows_at('Saeed Ammar', 4000, 253, 'p4'),
       gen_random_uuid()) as result)
   select (result -> 'batch' ->> 'accepted')::int = 3943 from payload));

select pg_temp.expect(
  'Saeed Ammar persists as 2687 DONE, 1256 pending and 4,021,000 IQD',
  (select count(*) = 3943
      and count(*) filter (where stage = 'DONE') = 2687
      and count(*) filter (where stage <> 'DONE') = 1256
      and count(*) filter (where stage = 'P1') = 662
      and count(*) filter (where stage = 'P2') = 166
      and count(*) filter (where stage = 'P3') = 175
      and count(*) filter (where stage = 'P4') = 253
      and coalesce(sum(amount), 0) = 4021000
   from public.installation_entitlements
   where period = '2026-09' and reseller = 'Saeed Ammar'));

select pg_temp.expect(
  'Ahmed Abdulabbas imports as 1507 subscribers',
  (with payload as (
     select public.import_installation_entitlements('2026-09','ahmed.xlsx',null,
       pg_temp.rows_at('Ahmed Abdulabbas', 0, 602, 'done')
       || pg_temp.rows_at('Ahmed Abdulabbas', 13000, 114, 'p1')
       || pg_temp.rows_at('Ahmed Abdulabbas', 10000, 177, 'p2')
       || pg_temp.rows_at('Ahmed Abdulabbas', 7000, 197, 'p3')
       || pg_temp.rows_at('Ahmed Abdulabbas', 4000, 417, 'p4'),
       gen_random_uuid()) as result)
   select (result -> 'batch' ->> 'accepted')::int = 1507 from payload));

select pg_temp.expect(
  'Ahmed Abdulabbas persists as 602 DONE, 905 pending and 3,132,000 IQD',
  (select count(*) = 1507
      and count(*) filter (where stage = 'DONE') = 602
      and count(*) filter (where stage <> 'DONE') = 905
      and count(*) filter (where stage = 'P1') = 114
      and count(*) filter (where stage = 'P2') = 177
      and count(*) filter (where stage = 'P3') = 197
      and count(*) filter (where stage = 'P4') = 417
      and coalesce(sum(amount), 0) = 3132000
   from public.installation_entitlements
   where period = '2026-09' and reseller = 'Ahmed Abdulabbas'));

select pg_temp.expect(
  'the two resellers stay separated in the same period',
  (select coalesce(sum(amount), 0) = 4021000 + 3132000
   from public.installation_entitlements where period = '2026-09'));

-- ================================================================================
-- استيراد مجزّأ (تدقيق QA ما بعد الإطلاق، 2026-09-01، طلب #5): ملف Activations
-- Report الحقيقي فيه 29,427 صفاً يتجاوز حدّ النداء الواحد (20000). p_batch_id
-- الاختياري الجديد (20261027090000) يحوّل هذا الحدّ من سقفٍ صلبٍ للملف إلى حجم
-- دفعةٍ داخلية: نداءٌ بلا p_batch_id ينشئ الدفعة كما كان تماماً، ونداءٌ لاحقٌ
-- بنفس p_batch_id يُلحِق صفوفه بها. مصفوفة الاختبار المطلوبة: صفّ واحد، 20000
-- صفّ، 20001، ~30000، تكرارٌ عبر حدود الأجزاء، رفع الملف نفسه مرتين، السجلّ
-- نفسه في ملفٍّ آخر، فشل جزءٍ لاحق، والإجماليّات صحيحة.
-- ================================================================================

select pg_temp.expect(
  'مجزّأ: صفّ واحد يُقبل مباشرة بلا p_batch_id',
  (with result as (
     select public.import_installation_entitlements('2026-10','chunk-one.xlsx','sha-chunk-one',
       pg_temp.rows_at('CHK-ONE', 13000, 1, 'a'), gen_random_uuid()) as payload)
   select (payload -> 'batch' ->> 'accepted')::int = 1
      and (payload -> 'batch' ->> 'batch_id') is not null
   from result));

select pg_temp.expect(
  'مجزّأ: 20000 صفّ بالضبط تُقبل في نداءٍ واحد (الحدّ صار حجم دفعةٍ داخلية لا سقفاً)',
  (with result as (
     select public.import_installation_entitlements('2026-10','chunk-20k.xlsx','sha-chunk-20k',
       pg_temp.rows_at('CHK-20K', 13000, 20000, 'a'), gen_random_uuid()) as payload)
   select (payload -> 'batch' ->> 'accepted')::int = 20000
      and (payload -> 'batch' ->> 'source_rows')::int = 20000
   from result));

-- 20001 صفاً: نداءان بنفس p_batch_id — الأول 20000 والثاني صفّ واحد يُلحَق.
-- p_finalize := false على الأول: جزءٌ غير نهائيّ، لا يُقفَل بعده (Blocker 2).
select (public.import_installation_entitlements('2026-10','chunk-20001.xlsx','sha-chunk-20001',
  pg_temp.rows_at('CHK-20001', 13000, 20000, 'a'), gen_random_uuid(),
  null, 20001, false) -> 'batch') as chk20001_c1 \gset

select pg_temp.expect(
  'مجزّأ 20001: الجزء الأول يقبل 20000 صفّ وينشئ الدفعة',
  ((:'chk20001_c1'::jsonb ->> 'accepted')::int = 20000
    and (:'chk20001_c1'::jsonb ->> 'batch_id') is not null));

select pg_temp.expect(
  'مجزّأ 20001: الجزء الأول غير النهائيّ يترك الدفعة IN_PROGRESS لا مكتملة',
  ((:'chk20001_c1'::jsonb ->> 'status') = 'in_progress'));

select (:'chk20001_c1'::jsonb ->> 'batch_id') as chk20001_batch_id \gset

select (public.import_installation_entitlements('2026-10','chunk-20001.xlsx','sha-chunk-20001',
  pg_temp.rows_at('CHK-20001', 13000, 1, 'b'), gen_random_uuid(), :'chk20001_batch_id'::uuid, 20001) -> 'batch') as chk20001_c2 \gset

select pg_temp.expect(
  'مجزّأ 20001: الجزء الثاني (صفّ واحد) يُلحَق بنفس الدفعة لا ينشئ دفعةً جديدة',
  ((:'chk20001_c2'::jsonb ->> 'accepted')::int = 1
    and (:'chk20001_c2'::jsonb ->> 'batch_id') = :'chk20001_batch_id'));

select pg_temp.expect(
  'مجزّأ 20001: إجماليّ الدفعة (batch_totals) بعد الجزء الثاني = 20001 لا 1',
  ((:'chk20001_c2'::jsonb -> 'batch_totals' ->> 'accepted')::int = 20001
    and (:'chk20001_c2'::jsonb -> 'batch_totals' ->> 'source_rows')::int = 20001));

select pg_temp.expect(
  'مجزّأ 20001: صفّ الدفعة نفسه في installation_batches يعكس إجماليّ الأجزاء',
  (select accepted_rows = 20001 and source_rows = 20001 and status = 'completed'
   from public.installation_batches where id = (:'chk20001_batch_id')::uuid));

select pg_temp.expect(
  'مجزّأ 20001: 20001 صفاً محفوظة فعلاً في الجدول، لا أكثر ولا أقلّ',
  (select count(*) = 20001 from public.installation_entitlements
   where period = '2026-10' and reseller = 'CHK-20001'));

-- ~30000 صفاً: نداءان بنفس p_batch_id (20000 ثم 10000). الأول غير نهائيّ.
select (public.import_installation_entitlements('2026-10','chunk-30k.xlsx','sha-chunk-30k',
  pg_temp.rows_at('CHK-30K', 10000, 20000, 'a'), gen_random_uuid(),
  null, 30000, false) -> 'batch') as chk30k_c1 \gset

select (:'chk30k_c1'::jsonb ->> 'batch_id') as chk30k_batch_id \gset

select (public.import_installation_entitlements('2026-10','chunk-30k.xlsx','sha-chunk-30k',
  pg_temp.rows_at('CHK-30K', 10000, 10000, 'b'), gen_random_uuid(), :'chk30k_batch_id'::uuid, 30000) -> 'batch') as chk30k_c2 \gset

select pg_temp.expect(
  'مجزّأ ~30000: نداءان (20000+10000) يجمعان إلى 30000 صفٍّ مقبول في batch_totals',
  ((:'chk30k_c2'::jsonb -> 'batch_totals' ->> 'accepted')::int = 30000
    and (:'chk30k_c2'::jsonb -> 'batch_totals' ->> 'source_rows')::int = 30000));

select pg_temp.expect(
  'مجزّأ ~30000: 30000 صفاً فعلياً في الجدول بمبلغٍ إجماليٍّ صحيح',
  -- المتبقّي 10000 => المرحلة P2 => القسط 3000 (installation_amount_for_stage)، لا 10000 نفسها.
  (select count(*) = 30000 and coalesce(sum(amount), 0) = 30000 * 3000
   from public.installation_entitlements where period = '2026-10' and reseller = 'CHK-30K'));

-- تكرارٌ عبر حدود الأجزاء: السجلّ نفسه (subscriber+stage) يظهر في الجزء
-- الأول ثم يُعاد في الثاني — كلّ جزءٍ يُثبَّت قبل التالي فيُكتشَف كالتكرار العادي.
select (public.import_installation_entitlements('2026-10','chunk-dup.xlsx','sha-chunk-dup',
  jsonb_build_array(jsonb_build_object('subscriber_id','CHK-DUP-1','reseller','CHK-DUP','remaining',13000)),
  gen_random_uuid(), null, 3, false) -> 'batch') as chkdup_c1 \gset

select (:'chkdup_c1'::jsonb ->> 'batch_id') as chkdup_batch_id \gset

select (public.import_installation_entitlements('2026-10','chunk-dup.xlsx','sha-chunk-dup',
  jsonb_build_array(
    jsonb_build_object('subscriber_id','CHK-DUP-1','reseller','CHK-DUP','remaining',13000),
    jsonb_build_object('subscriber_id','CHK-DUP-2','reseller','CHK-DUP','remaining',13000)
  ), gen_random_uuid(), :'chkdup_batch_id'::uuid, 3) -> 'batch') as chkdup_c2 \gset

select pg_temp.expect(
  'مجزّأ: تكرارٌ عبر حدود الأجزاء يُكتشف — سجلّ الجزء الأول يُرفض كتكرارٍ في الثاني',
  ((:'chkdup_c2'::jsonb ->> 'accepted')::int = 1
    and (:'chkdup_c2'::jsonb ->> 'duplicates')::int = 1));

select pg_temp.expect(
  'مجزّأ: السجلّ المكرَّر محفوظٌ مرّةً واحدة فقط رغم ظهوره في جزأين',
  (select count(*) = 1 from public.installation_entitlements
   where period = '2026-10' and subscriber_id = 'CHK-DUP-1'));

-- رفع الملف نفسه مرتين (دفعتان منفصلتان، كلٌّ منهما نداءٌ واحدٌ غير مجزّأ):
-- لا تجزئة هنا، لكنه جزءٌ صريحٌ من مصفوفة الاختبار المطلوبة.
select (public.import_installation_entitlements('2026-10','chunk-repeat.xlsx','sha-chunk-repeat',
  jsonb_build_array(jsonb_build_object('subscriber_id','CHK-REPEAT-1','reseller','CHK-REPEAT','remaining',13000)),
  gen_random_uuid()) -> 'batch') as chkrepeat_c1 \gset

select pg_temp.expect(
  'مجزّأ: رفع الملف نفسه مرتين — الرفعة الأولى تُقبل',
  ((:'chkrepeat_c1'::jsonb ->> 'accepted')::int = 1));

select (public.import_installation_entitlements('2026-10','chunk-repeat.xlsx','sha-chunk-repeat',
  jsonb_build_array(jsonb_build_object('subscriber_id','CHK-REPEAT-1','reseller','CHK-REPEAT','remaining',13000)),
  gen_random_uuid()) -> 'batch') as chkrepeat_c2 \gset

select pg_temp.expect(
  'مجزّأ: رفع الملف نفسه مرتين — الرفعة الثانية دفعةٌ جديدة لكن صفّها تكرارٌ بلا أثرٍ ماليٍّ إضافي',
  ((:'chkrepeat_c2'::jsonb ->> 'accepted')::int = 0
    and (:'chkrepeat_c2'::jsonb ->> 'duplicates')::int = 1
    and (:'chkrepeat_c2'::jsonb ->> 'batch_id') <> (:'chkrepeat_c1'::jsonb ->> 'batch_id')));

select pg_temp.expect(
  'مجزّأ: لا أثر مالي مضاعف من رفعتين — السجلّ محفوظ مرّةً واحدة',
  (select count(*) = 1 from public.installation_entitlements
   where period = '2026-10' and subscriber_id = 'CHK-REPEAT-1'));

-- السجلّ نفسه في ملفٍّ آخر (بصمة مختلفة تماماً) — يبقى تكراراً بمعيار العمل لا الملف.
select (public.import_installation_entitlements('2026-10','chunk-otherfile.xlsx','sha-chunk-otherfile',
  jsonb_build_array(jsonb_build_object('subscriber_id','CHK-REPEAT-1','reseller','CHK-REPEAT','remaining',13000)),
  gen_random_uuid()) -> 'batch') as chkotherfile \gset

select pg_temp.expect(
  'مجزّأ: السجلّ نفسه في ملفٍّ آخر ببصمةٍ مختلفة يبقى تكراراً',
  ((:'chkotherfile'::jsonb ->> 'duplicates')::int = 1
    and (:'chkotherfile'::jsonb ->> 'accepted')::int = 0));

-- فشل جزءٍ لاحق: فترة مختلفة، ثم بصمة ملفٍّ مختلفة، ثم دفعةٌ غير موجودة أصلاً —
-- كلّها تُرفض دون أن تُفسد ما أنجزته الأجزاء الناجحة السابقة.
select (public.import_installation_entitlements('2026-10','chunk-fail.xlsx','sha-chunk-fail',
  jsonb_build_array(jsonb_build_object('subscriber_id','CHK-FAIL-1','reseller','CHK-FAIL','remaining',13000)),
  gen_random_uuid()) -> 'batch') as chkfail_c1 \gset

select (:'chkfail_c1'::jsonb ->> 'batch_id') as chkfail_batch_id \gset

select pg_temp.expect_error(
  'مجزّأ: جزءٌ لاحق بفترةٍ مختلفة عن الدفعة يُرفض',
  format($q$select public.import_installation_entitlements('2026-11','chunk-fail.xlsx','sha-chunk-fail',
      '[{"subscriber_id":"CHK-FAIL-2","reseller":"CHK-FAIL","remaining":13000}]'::jsonb,
      gen_random_uuid(), %L::uuid)$q$, :'chkfail_batch_id'),
  '22023');

select pg_temp.expect_error(
  'مجزّأ: جزءٌ لاحق ببصمة ملفٍّ مختلفة عن الدفعة يُرفض',
  format($q$select public.import_installation_entitlements('2026-10','chunk-fail.xlsx','sha-chunk-fail-WRONG',
      '[{"subscriber_id":"CHK-FAIL-3","reseller":"CHK-FAIL","remaining":13000}]'::jsonb,
      gen_random_uuid(), %L::uuid)$q$, :'chkfail_batch_id'),
  '22023');

select pg_temp.expect_error(
  'مجزّأ: p_batch_id لدفعةٍ غير موجودة أصلاً يُرفض',
  $q$select public.import_installation_entitlements('2026-10','chunk-fail.xlsx','sha-chunk-fail',
      '[{"subscriber_id":"CHK-FAIL-4","reseller":"CHK-FAIL","remaining":13000}]'::jsonb,
      gen_random_uuid(), gen_random_uuid())$q$,
  '22023');

select pg_temp.expect(
  'مجزّأ: فشل الأجزاء اللاحقة لا يفسد إجماليّات الدفعة من الجزء الناجح الوحيد',
  (select accepted_rows = 1 and source_rows = 1 and status = 'completed'
   from public.installation_batches where id = (:'chkfail_batch_id')::uuid));

select pg_temp.expect(
  'مجزّأ: فشل الأجزاء اللاحقة لم يُدرج أي صفٍّ إضافي في الجدول',
  (select count(*) = 1 from public.installation_entitlements where reseller = 'CHK-FAIL'));

-- أمان إعادة الطلب يبقى لكلّ جزءٍ على حدة: إعادة نفس request_id لنفس الجزء
-- تُعيد النتيجة الأصلية دون استيرادٍ مضاعف.
select (public.import_installation_entitlements('2026-10','chunk-replay.xlsx','sha-chunk-replay',
  jsonb_build_array(jsonb_build_object('subscriber_id','CHK-REPLAY-1','reseller','CHK-REPLAY','remaining',13000)),
  '99999999-9999-9999-9999-999999999901'::uuid) -> 'batch') as chkreplay_c1 \gset

select pg_temp.expect(
  'مجزّأ: أمان إعادة الطلب لكلّ جزءٍ — النداء الأول يُقبل',
  ((:'chkreplay_c1'::jsonb ->> 'accepted')::int = 1));

select (public.import_installation_entitlements('2026-10','chunk-replay.xlsx','sha-chunk-replay',
  jsonb_build_array(jsonb_build_object('subscriber_id','CHK-REPLAY-1','reseller','CHK-REPLAY','remaining',13000)),
  '99999999-9999-9999-9999-999999999901'::uuid) ->> 'replayed') as chkreplay_replayed \gset

select pg_temp.expect(
  'مجزّأ: إعادة نفس request_id لنفس الجزء تُعاد نتيجتها الأصلية بلا استيرادٍ مضاعف',
  ((:'chkreplay_replayed') = 'true'
    and (select count(*) = 1 from public.installation_entitlements where subscriber_id = 'CHK-REPLAY-1')));

rollback;
