begin;

-- ---------------------------------------------------------------------------
-- الجاهزية: «كم دُفع سابقاً» بجانب «كم المستحق الآن» — لا حسابٌ من العميل.
--
-- installation_entitlements هو دفتر الصرف الفعلي: سطرٌ لكل (فترة + مشترك +
-- مرحلة) دُفع بالفعل. المرشّح في page_payout_candidate_lines يقرأ حالته
-- الحالية من installation_subscriber_state لا من الدفتر، فـ«سابقاً» يعني
-- مجموع كل ما دُفع لهذا المشترك عبر كل الفترات والمراحل الماضية — رقمٌ
-- منفصل تماماً عن «المستحق الآن»، لا يُعاد بناؤه، ولا يمسّ شرط الجاهزية.
--
-- الحساب على صفحة الفرز المُرجَعة فقط (v_lim صفّاً كحدّ أقصى)، لا على كامل
-- المرشّحين قبل التصفح — نفس درس 20260920090000: نداءٌ لكل مرشّح قبل
-- التصفح هو ما سبّب تجاوز المهلة.
-- ---------------------------------------------------------------------------

create index if not exists installation_entitlements_subscriber_paid_idx
  on public.installation_entitlements (subscriber_id)
  where payment_status = 'paid';

create or replace function public.page_payout_candidate_lines(
  p_reseller text default null,
  p_stage text default null,
  p_only_ready boolean default null,
  p_limit integer default 50,
  p_offset integer default 0,
  p_blocker text default null,
  p_search text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare v_rows jsonb; v_total bigint; v_lim integer; v_off integer;
begin
  perform public.require_capability('installation.view');
  v_lim := public.page_limit(p_limit);
  v_off := public.page_offset(p_offset);

  with base as (
    select
      s.subscriber_id, s.reseller, s.fdt,
      st.remaining, st.current_stage as stage,
      public.installation_amount_for_stage(st.current_stage) as amount,
      st.resolution, st.payment_eligible,
      (select h.id from public.installation_holds h
       where h.subscriber_id = s.subscriber_id
         and public.hold_is_effective(h.status, h.permanence, h.expires_at)
       limit 1) as hold_id,
      (select coalesce(h.reason_note, h.note) from public.installation_holds h
       where h.subscriber_id = s.subscriber_id
         and public.hold_is_effective(h.status, h.permanence, h.expires_at)
       limit 1) as hold_reason,
      exists (
        select 1 from public.installation_invoices i
        where i.subscriber_id = s.subscriber_id
          and i.stage_code is not distinct from st.current_stage
          and i.status = 'VERIFIED') as invoice_ok,
      exists (
        select 1 from public.subscriber_identities i
        where i.username_key = lower(btrim(s.subscriber_id))
          and i.identity_status = 'CONFLICT') as identity_conflict,
      public.subscriber_ownership_type(s.subscriber_id) as ownership
    from public.installation_subscribers s
    join public.installation_subscriber_state st on st.subscriber_uuid = s.id
    where coalesce(st.remaining, 0) > 0
      and st.current_stage in ('P1', 'P2', 'P3', 'P4')
  ),
  judged as (
    select b.*,
      -- الأصناف التي تحجب هذا السطر، بترتيب ما يُحسم أوّلاً.
      array_remove(array[
        case when b.hold_id is not null then 'HOLD' end,
        case when not b.invoice_ok then 'INVOICE' end,
        case when b.resolution <> 'resolved' or b.payment_eligible is not true
             then 'SOURCE' end,
        case when b.identity_conflict then 'IDENTITY' end,
        case when b.ownership <> 'RESELLER' then 'PARENT' end
      ], null) as blockers
    from base b
  ),
  kept as (
    select j.*, cardinality(j.blockers) = 0 as is_ready
    from judged j
    where (p_reseller is null or j.reseller = p_reseller)
      and (p_stage is null or j.stage = p_stage)
      and (p_search is null or btrim(p_search) = ''
           or j.subscriber_id ilike '%' || p_search || '%'
           or j.reseller ilike '%' || p_search || '%')
      and (p_blocker is null or p_blocker = any (j.blockers))
  ),
  filtered as (
    select * from kept k
    where p_only_ready is null or k.is_ready = p_only_ready
  ),
  page as (
    select * from filtered f
    order by f.is_ready desc, f.subscriber_id
    limit v_lim offset v_off
  )
  select count(*), coalesce((
    select jsonb_agg(to_jsonb(x)) from (
      select p.subscriber_id, p.reseller, p.fdt, p.stage, p.amount, p.remaining,
             p.hold_id is not null as held, p.hold_reason, p.invoice_ok,
             p.identity_conflict, p.ownership,
             p.resolution, p.payment_eligible,
             to_jsonb(p.blockers) as blockers, p.is_ready,
             (select coalesce(sum(e.paid_amount), 0) from public.installation_entitlements e
              where e.subscriber_id = p.subscriber_id
                and e.payment_status = 'paid') as previous_paid
      from page p) x), '[]'::jsonb)
  into v_total, v_rows
  from filtered;

  return public.page_envelope(v_rows, v_total, v_lim, v_off);
end;
$fn$;

revoke execute on function public.page_payout_candidate_lines(text,text,boolean,integer,integer,text,text)
  from public, anon;
grant execute on function public.page_payout_candidate_lines(text,text,boolean,integer,integer,text,text)
  to authenticated;

commit;
