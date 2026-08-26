-- PR-B3: LIVE-04 — إجمالي صدفة الاستثناءات اليدوية يقول الحقيقة خارج المدى.
--
-- معزول بنطاق تسمية b3pg-.

\set ON_ERROR_STOP on
\pset tuples_only on

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns text language sql as $$
  select case when p_cond then '            ok ' || p_label else 'FAILED: ' || p_label end;
$$;

begin;

select '           == pr-b3: live-04 manual exception page total ==';

insert into auth.users (id, email) values ('65000000-0000-0000-0000-0000000000e1','b3pg@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active)
values ('65000000-0000-0000-0000-0000000000e1','B3PG','b3pg@fixture.invalid','admin',true)
on conflict (id) do update set role='admin', is_active=true;

insert into public.manual_exception_intakes
  (exception_type, username_key, reason, status, request_id, created_by)
select 'OTHER', 'b3pg-sub-' || g, 'اختبار الصدفة', 'NEEDS_REVIEW', gen_random_uuid(),
       '65000000-0000-0000-0000-0000000000e1'
from generate_series(1, 4) g;

set local role authenticated;
set local request.jwt.claim.sub = '65000000-0000-0000-0000-0000000000e1';

select pg_temp.ok(
  (public.page_manual_exceptions(p_status => 'NEEDS_REVIEW', p_limit => 1) ->> 'total')::bigint
  = (public.page_manual_exceptions(p_status => 'NEEDS_REVIEW', p_limit => 1, p_offset => 999999) ->> 'total')::bigint,
  'الإجمالي لا يتغيّر بإزاحة خارج المدى — لا يُحسَب من صفحة');

select pg_temp.ok(
  (public.page_manual_exceptions(p_status => 'NEEDS_REVIEW', p_limit => 1) ->> 'total')::bigint >= 4,
  'الإجمالي يعكس المجموعة الكاملة لا حجم الصفحة الواحدة');

select pg_temp.ok(
  jsonb_array_length(public.page_manual_exceptions(
    p_status => 'NEEDS_REVIEW', p_limit => 1, p_offset => 999999) -> 'rows') = 0,
  'الصفحة خارج المدى فارغة الصفوف مع بقاء الإجمالي صحيحاً');

reset role;
rollback;
