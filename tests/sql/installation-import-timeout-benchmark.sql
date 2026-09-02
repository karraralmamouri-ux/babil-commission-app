-- Codex Blocker 1: reproduced a single 20,000-row
-- import_installation_entitlements call exceeding Production's
-- authenticated statement_timeout=8s (~8006ms) under the old per-row
-- EXISTS-in-a-loop implementation (20261027090000). The set-based rewrite
-- (20261031090000) replaces that loop with a handful of set operations.
--
-- This is a real timeout reproduction, not a wall-clock formula: the
-- session's statement_timeout is set to the exact production value (8s),
-- and Postgres itself — not this test's arithmetic — cancels the
-- statement (sqlstate 57014) if the budget is exceeded. That keeps the
-- pass/fail condition meaningful on any machine: a call that genuinely
-- can't fit in 8s fails here exactly as it would in Production, instead of
-- passing or flaking on an assertion tuned to local hardware speed.
--
-- Actual elapsed time is also reported via \timing for headroom evidence,
-- but is not itself the pass/fail gate.
--
-- معزول بنطاق تسمية TB-.

\set ON_ERROR_STOP on
\pset tuples_only on
\timing on

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns text language sql as $$
  select case when p_cond then '    ok ' || p_label else 'FAILED: ' || p_label end;
$$;

create or replace function pg_temp.rows_at(p_reseller text, p_remaining bigint, p_count integer, p_tag text)
returns jsonb language sql as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'subscriber_id', p_reseller || '-' || p_tag || '-' || g,
    'subscriber_name', 'subscriber ' || g,
    'reseller', p_reseller,
    'remaining', p_remaining
  )), '[]'::jsonb)
  from generate_series(1, p_count) g;
$$;

begin;

select '    == installation import timeout benchmark (8s) ==';

insert into auth.users (id, email) values
  ('db000000-0000-0000-0000-0000000000a1', 'tb-admin@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active) values
  ('db000000-0000-0000-0000-0000000000a1','TBA','tb-admin@fixture.invalid','admin',true)
on conflict (id) do update set role = 'admin', is_active = true;

create or replace function pg_temp.act_as(p_user uuid)
returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', p_user::text, true); end;
$$;
select pg_temp.act_as('db000000-0000-0000-0000-0000000000a1');

-- نفس مهلة الدور authenticated في الإنتاج حرفياً — لا رقمٌ تقريبيّ.
set local statement_timeout = '8s';

-- أقصى صفٍّ ممكنٍ في نداءٍ واحد (20000، لم يتغيّر — صار حجم دفعةٍ داخلية لا
-- سقف ملفٍّ، 20261027090000) — وهو ما أعاد Codex إثباته يتجاوز 8 ثوانٍ.
select pg_temp.ok(
  (with result as (
     select public.import_installation_entitlements('2026-12','tb-20k.xlsx','tb-sha-20k',
       pg_temp.rows_at('TB-20K', 13000, 20000, 'a'), gen_random_uuid()) as payload)
   select (payload -> 'batch' ->> 'accepted')::int = 20000
      and (payload -> 'batch' ->> 'status') = 'completed'
   from result),
  '20,000 صفّ في نداءٍ واحد يكتمل ضمن 8 ثوانٍ — لا 57014 (query_canceled)');

select pg_temp.ok(
  (select count(*) = 20000 from public.installation_entitlements
   where period = '2026-12' and reseller = 'TB-20K'),
  '20,000 صفّ محفوظة فعلاً — الاكتمال ليس صمتاً جزئياً');

-- هامش أمانٍ إضافي: دفعةٌ ثانية 20000 أخرى فوق ما سبق (يحاكي الملف الحقيقي
-- 29,427 صفاً موزَّعاً على جزأين)، غير نهائية ثم نهائية، كلٌّ منهما ضمن
-- المهلة نفسها — لا تراكم زمنٍ عبر الأجزاء يقترب من الحدّ.
select pg_temp.ok(
  (with result as (
     select public.import_installation_entitlements('2026-12','tb-real-file.xlsx','tb-sha-real',
       pg_temp.rows_at('TB-REAL', 13000, 20000, 'a'), gen_random_uuid(),
       null, 29427, false) as payload)
   select (payload -> 'batch' ->> 'accepted')::int = 20000
      and (payload -> 'batch' ->> 'status') = 'in_progress'
   from result),
  'محاكاة الملف الحقيقي (29,427 صفاً): الجزء الأول (20000) ضمن 8 ثوانٍ');

select (select id from public.installation_batches where file_name = 'tb-real-file.xlsx') as tb_real_batch \gset

select pg_temp.ok(
  (with result as (
     select public.import_installation_entitlements('2026-12','tb-real-file.xlsx','tb-sha-real',
       pg_temp.rows_at('TB-REAL', 13000, 9427, 'b'), gen_random_uuid(),
       (:'tb_real_batch')::uuid, 29427, true) as payload)
   select (payload -> 'batch' ->> 'accepted')::int = 9427
      and (payload -> 'batch' ->> 'status') = 'completed'
   from result),
  'محاكاة الملف الحقيقي (29,427 صفاً): الجزء الثاني والأخير (9,427) ضمن 8 ثوانٍ ويُنهي الدفعة');

select pg_temp.ok(
  (select accepted_rows = 29427 and status = 'completed'
   from public.installation_batches where id = (:'tb_real_batch')::uuid),
  'محاكاة الملف الحقيقي كاملاً (29,427 صفاً على جزأين): مكتملة، ضمن 8 ثوانٍ لكلّ جزءٍ على حدة');

rollback;
