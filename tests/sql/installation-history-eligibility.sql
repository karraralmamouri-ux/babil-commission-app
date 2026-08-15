-- لا اختلال يعبر إلى الأهلية للصرف.
--
-- هذا الملف يفصل قاعدة واحدة ويثبتها من جهتين: أن الاستيراد يشتق الأهلية
-- بشكل صحيح، وأن القيود ترفض تخزين خلاف ذلك حتى بكتابة مباشرة تتجاوز
-- الاستيراد كلياً.

\set ON_ERROR_STOP on
begin;

create temporary table eligibility_results (name text, ok boolean, detail text);

create or replace function pg_temp.assert_that(p_name text, p_ok boolean, p_detail text default '')
returns void language plpgsql as $fn$
begin
  insert into eligibility_results values (p_name, p_ok, p_detail);
  if not p_ok then
    raise exception 'FAILED: % %', p_name, p_detail;
  end if;
end;
$fn$;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000c1', 'eligibility@fixture.invalid')
on conflict (id) do nothing;
insert into public.profiles (id, full_name, email, role, is_active)
values ('00000000-0000-0000-0000-0000000000c1', 'Eligibility', 'eligibility@fixture.invalid', 'admin', true)
on conflict (id) do update set role = 'admin', is_active = true;

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c1', true);

-- أربع حالات: اختلال على DONE، اختلال على مرحلة معلّقة، DONE ناقص التفصيل
-- لكنه متوازن، وصف نظيف مؤهَّل فعلاً. وخامسة بمتبقٍّ فارغ.
select public.import_installation_history(
  '2026-07-01'::date, 'eligibility.xlsx', null,
  $json$[
    {"subscriber_id":"E-MISMATCH-DONE","reseller":"R9","total_amount":13000,"received_total":9000,
     "remaining":0,
     "payments":[{"stage":"P1","amount":3000,"payment_date":"2025-12-20"},
                 {"stage":"P2","amount":3000,"payment_date":"2026-01-20"},
                 {"stage":"P3","amount":3000,"payment_date":"2026-02-20"}]},
    {"subscriber_id":"E-MISMATCH-PENDING","reseller":"R9","total_amount":13000,"received_total":3000,
     "remaining":4000,
     "payments":[{"stage":"P1","amount":3000,"payment_date":"2025-12-20"}]},
    {"subscriber_id":"E-DONE-NO-P4","reseller":"R9","total_amount":13000,"received_total":13000,
     "remaining":0,
     "payments":[{"stage":"P1","amount":3000,"payment_date":"2025-12-20"},
                 {"stage":"P2","amount":3000,"payment_date":"2026-01-20"},
                 {"stage":"P3","amount":7000,"payment_date":"2026-02-20"}]},
    {"subscriber_id":"E-CLEAN-P4","reseller":"R9","total_amount":13000,"received_total":9000,
     "remaining":4000,
     "payments":[{"stage":"P1","amount":3000,"payment_date":"2025-12-20"},
                 {"stage":"P2","amount":3000,"payment_date":"2026-01-20"},
                 {"stage":"P3","amount":3000,"payment_date":"2026-02-20"}]},
    {"subscriber_id":"E-BLANK-REMAINING","reseller":"R9","total_amount":13000,"received_total":3000,
     "remaining":null,
     "payments":[{"stage":"P1","amount":3000,"payment_date":"2025-12-20"}]}
  ]$json$::jsonb,
  '00000000-0000-0000-0000-00000000c001'::uuid
);

create or replace function pg_temp.state_of(p_id text)
returns public.installation_subscriber_state language sql stable as $fn$
  select s.* from public.installation_subscriber_state s
  join public.installation_subscribers b on b.id = s.subscriber_uuid
  where b.subscriber_id = p_id;
$fn$;

-- القاعدة 1 — الاختلال المحاسبي.
select pg_temp.assert_that('a financial mismatch keeps its raw values untouched',
  (select remaining = 0 and received_total = 9000 and total_amount = 13000
   from pg_temp.state_of('E-MISMATCH-DONE')));

select pg_temp.assert_that('a financial mismatch is marked unresolved',
  (select resolution = 'unresolved' from pg_temp.state_of('E-MISMATCH-DONE')));

select pg_temp.assert_that('a financial mismatch is never payment eligible',
  (select payment_eligible is false from pg_temp.state_of('E-MISMATCH-DONE')));

select pg_temp.assert_that('a mismatch sitting on a payable stage is blocked as well',
  (select current_stage = 'P4' and resolution = 'unresolved' and payment_eligible is false
   from pg_temp.state_of('E-MISMATCH-PENDING')),
  'a P4 row whose numbers do not reconcile must not be payable');

select pg_temp.assert_that('a mismatch is reported for review',
  (select 'remaining_mismatch' = any(warnings) from pg_temp.state_of('E-MISMATCH-DONE')));

-- القاعدة 2 — متبقٍّ فارغ.
select pg_temp.assert_that('a blank remaining stays unresolved with no guessed stage',
  (select resolution = 'unresolved' and current_stage is null
      and 'remaining_missing' = any(warnings)
   from pg_temp.state_of('E-BLANK-REMAINING')));

select pg_temp.assert_that('a blank remaining is never payment eligible',
  (select payment_eligible is false from pg_temp.state_of('E-BLANK-REMAINING')));

select pg_temp.assert_that('a blank remaining still keeps the payment history it does have',
  (select count(*) = 1 from public.installation_payment_history h
   join public.installation_subscribers b on b.id = h.subscriber_uuid
   where b.subscriber_id = 'E-BLANK-REMAINING'));

-- القاعدة 3 — DONE بلا P4.
select pg_temp.assert_that('a balanced DONE without P4 stays resolved',
  (select resolution = 'resolved' and current_stage = 'DONE'
   from pg_temp.state_of('E-DONE-NO-P4')));

select pg_temp.assert_that('a balanced DONE without P4 is flagged as incomplete detail',
  (select 'historical_payment_detail_incomplete' = any(warnings)
   from pg_temp.state_of('E-DONE-NO-P4')));

select pg_temp.assert_that('no phantom P4 is created for an incomplete DONE',
  (select count(*) = 0 from public.installation_payment_history h
   join public.installation_subscribers b on b.id = h.subscriber_uuid
   where b.subscriber_id = 'E-DONE-NO-P4' and h.stage = 'P4'));

select pg_temp.assert_that('DONE is never payment eligible, nothing is left to pay',
  (select payment_eligible is false from pg_temp.state_of('E-DONE-NO-P4')));

-- الحالة السليمة تظل مؤهَّلة، وإلا كانت القاعدة تمنع كل شيء بلا تمييز.
select pg_temp.assert_that('a clean pending row IS payment eligible',
  (select payment_eligible is true and resolution = 'resolved' and current_stage = 'P4'
   from pg_temp.state_of('E-CLEAN-P4')));

select pg_temp.assert_that('exactly one of the five rows is eligible',
  (select count(*) = 1 from public.installation_subscriber_state s
   join public.installation_subscribers b on b.id = s.subscriber_uuid
   where b.reseller = 'R9' and s.payment_eligible),
  (select count(*)::text from public.installation_subscriber_state s
   join public.installation_subscribers b on b.id = s.subscriber_uuid
   where b.reseller = 'R9' and s.payment_eligible));

-- الحارس البنيوي: القيود ترفض الحالات المستحيلة حتى بكتابة مباشرة.
do $$
declare v_failed boolean := false;
begin
  begin
    update public.installation_subscriber_state set payment_eligible = true
    where subscriber_uuid = (select id from public.installation_subscribers
                             where subscriber_id = 'E-MISMATCH-DONE');
  exception when others then v_failed := true;
  end;
  perform pg_temp.assert_that('a direct write cannot mark an unresolved row eligible', v_failed);
end;
$$;

do $$
declare v_failed boolean := false;
begin
  begin
    update public.installation_subscriber_state set payment_eligible = true
    where subscriber_uuid = (select id from public.installation_subscribers
                             where subscriber_id = 'E-DONE-NO-P4');
  exception when others then v_failed := true;
  end;
  perform pg_temp.assert_that('a direct write cannot mark a DONE row eligible', v_failed);
end;
$$;

do $$
declare v_failed boolean := false;
begin
  begin
    update public.installation_subscriber_state set resolution = 'resolved'
    where subscriber_uuid = (select id from public.installation_subscribers
                             where subscriber_id = 'E-MISMATCH-DONE');
  exception when others then v_failed := true;
  end;
  perform pg_temp.assert_that('a direct write cannot call a mismatched row resolved', v_failed);
end;
$$;

do $$
declare v_failed boolean := false;
begin
  begin
    insert into public.installation_subscriber_state
      (subscriber_uuid, as_of_date, remaining, received_total, total_amount,
       current_stage, resolution, payment_eligible)
    select id, '2026-07-01', 4000, 3000, 13000, 'P4', 'resolved', true
    from public.installation_subscribers where subscriber_id = 'E-CLEAN-P4'
    on conflict (subscriber_uuid) do update
      set remaining = excluded.remaining, received_total = excluded.received_total,
          total_amount = excluded.total_amount, payment_eligible = excluded.payment_eligible;
  exception when others then v_failed := true;
  end;
  perform pg_temp.assert_that('a direct write cannot store a mismatch as resolved and eligible', v_failed);
end;
$$;

-- إعادة الاستيراد لا تُحوّل صفاً محجوباً إلى مؤهَّل.
select public.import_installation_history(
  '2026-07-01'::date, 'eligibility.xlsx', null,
  $json$[
    {"subscriber_id":"E-MISMATCH-DONE","reseller":"R9","total_amount":13000,"received_total":9000,
     "remaining":0,
     "payments":[{"stage":"P1","amount":3000,"payment_date":"2025-12-20"}]}
  ]$json$::jsonb,
  '00000000-0000-0000-0000-00000000c002'::uuid
);

select pg_temp.assert_that('re-importing a mismatched row leaves it blocked',
  (select payment_eligible is false and resolution = 'unresolved'
   from pg_temp.state_of('E-MISMATCH-DONE')));

select name, case when ok then 'pass' else 'FAIL' end as result from eligibility_results order by name;

rollback;
