-- ---------------------------------------------------------------------------
-- مراجعة الفواتير — الحاجب الأكبر، وله شاشته
--
-- كل مرحلة في المخطّط المنشور تشترط فاتورة مدقَّقة، ولا فاتورة واحدة مدقَّقة
-- في الإنتاج. فالمرشّحون الـ2,196 كلّهم محجوبون بهذا السبب وحده، وحتى الآن
-- لم تكن ثمّة شاشة تحسمه.
--
-- المفردات القائمة PENDING/VERIFIED/REJECTED تبقى كما هي، ويُضاف إليها
-- MISSING: «رُوجعت ولا فاتورة لها في المصدر» حكمٌ لا غيابُ حكم. أمّا
-- «لم تُفحص بعد» فهو غيابُ الصفّ نفسه — لا يُخزَّن، ويُعرض NOT_CHECKED.
--
-- والتدقيق قرارٌ ماليّ: يفتح الطريق أمام مبلغ. فله صلاحيته وسببه ومعرّف
-- طلبه وأثره في التدقيق.
--
-- وأودو مؤجَّل: أعمدته موجودة في الجدول ولا تُكتب هنا ولا تُقرأ.
-- ---------------------------------------------------------------------------

begin;

alter table public.installation_invoices
  drop constraint if exists installation_invoices_status_check;

alter table public.installation_invoices
  add constraint installation_invoices_status_check
  check (status in ('PENDING', 'VERIFIED', 'MISSING', 'REJECTED'));

-- ---------------------------------------------------------------------------
-- 1. طابور المراجعة
--
-- كل مشتركٍ له قسطٌ قادم يظهر، ولو لم يكن له صفّ فاتورة. الغياب حالةٌ
-- تُعرض لا صفٌّ ناقص يُخفي المشترك من الطابور.
-- ---------------------------------------------------------------------------

create or replace function public.page_invoice_review(
  p_status text default null,
  p_reseller text default null,
  p_stage text default null,
  p_search text default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare v_rows jsonb; v_total bigint; v_lim integer; v_off integer;
begin
  perform public.require_capability('invoice.view');
  v_lim := public.page_limit(p_limit);
  v_off := public.page_offset(p_offset);

  with base as (
    select
      s.subscriber_id, s.reseller, s.fdt,
      st.current_stage as stage,
      public.installation_amount_for_stage(st.current_stage) as amount,
      i.id as invoice_id,
      coalesce(i.status, 'NOT_CHECKED') as invoice_status,
      i.invoice_number, i.invoice_reference, i.invoice_source, i.invoice_date,
      i.verified_at, vb.email as verified_by_email,
      i.rejected_at, rb.email as rejected_by_email, i.rejection_reason,
      exists (
        select 1 from public.installation_holds h
        where h.subscriber_id = s.subscriber_id
          and public.hold_is_effective(h.status, h.permanence, h.expires_at)) as held,
      public.subscriber_ownership_type(s.subscriber_id) as ownership,
      (st.resolution = 'resolved' and st.payment_eligible) as eligible
    from public.installation_subscribers s
    join public.installation_subscriber_state st on st.subscriber_uuid = s.id
    left join public.installation_invoices i
      on i.subscriber_id = s.subscriber_id
     and i.stage_code is not distinct from st.current_stage
    left join public.profiles vb on vb.id = i.verified_by
    left join public.profiles rb on rb.id = i.rejected_by
    where coalesce(st.remaining, 0) > 0
      and st.current_stage in ('P1', 'P2', 'P3', 'P4')
  ),
  kept as (
    select * from base b
    where (p_status is null or b.invoice_status = p_status)
      and (p_reseller is null or b.reseller = p_reseller)
      and (p_stage is null or b.stage = p_stage)
      and (p_search is null or btrim(p_search) = ''
           or b.subscriber_id ilike '%' || p_search || '%'
           or b.reseller ilike '%' || p_search || '%'
           or b.invoice_number ilike '%' || p_search || '%')
  )
  -- ما لم يُفحص أوّلاً: هو العمل الذي ينتظر.
  select count(*), coalesce((
    select jsonb_agg(to_jsonb(x)) from (
      select k.* from kept k
      order by case k.invoice_status
                 when 'NOT_CHECKED' then 0 when 'PENDING' then 1
                 when 'MISSING' then 2 when 'REJECTED' then 3 else 4 end,
               k.subscriber_id
      limit v_lim offset v_off) x), '[]'::jsonb)
  into v_total, v_rows
  from kept;

  return public.page_envelope(v_rows, v_total, v_lim, v_off);
end;
$fn$;

revoke execute on function public.page_invoice_review(text,text,text,text,integer,integer)
  from public, anon;
grant execute on function public.page_invoice_review(text,text,text,text,integer,integer)
  to authenticated;

create or replace function public.invoice_review_summary()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $fn$
  with base as (
    select
      coalesce(i.status, 'NOT_CHECKED') as invoice_status,
      public.installation_amount_for_stage(st.current_stage) as amount
    from public.installation_subscribers s
    join public.installation_subscriber_state st on st.subscriber_uuid = s.id
    left join public.installation_invoices i
      on i.subscriber_id = s.subscriber_id
     and i.stage_code is not distinct from st.current_stage
    where coalesce(st.remaining, 0) > 0
      and st.current_stage in ('P1', 'P2', 'P3', 'P4')
  )
  select jsonb_build_object(
    'total', count(*),
    'total_amount', coalesce(sum(amount), 0),
    'verified', count(*) filter (where invoice_status = 'VERIFIED'),
    'verified_amount', coalesce(sum(amount) filter (where invoice_status = 'VERIFIED'), 0),
    'by_status', coalesce((
      select jsonb_object_agg(x.s, jsonb_build_object('n', x.n, 'amount', x.amt))
      from (select invoice_status as s, count(*) as n, sum(amount) as amt
            from base group by invoice_status) x), '{}'::jsonb))
  from base
  where public.has_capability('invoice.view');
$fn$;

revoke execute on function public.invoice_review_summary() from public, anon;
grant execute on function public.invoice_review_summary() to authenticated;

-- ---------------------------------------------------------------------------
-- 2. قرار المراجعة
-- ---------------------------------------------------------------------------

create or replace function public.review_invoice(
  p_subscriber_id text,
  p_stage_code text,
  p_status text,
  p_note text,
  p_invoice_number text default null,
  p_request_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor  uuid := auth.uid();
  v_id     uuid;
  v_before text;
  v_amount bigint;
  v_sid    text;
begin
  -- التدقيق يفتح مالاً، والرفض يُغلقه. صلاحيتان مختلفتان لقرارين مختلفين.
  if p_status = 'VERIFIED' then
    perform public.require_capability('invoice.verify');
  else
    perform public.require_capability('invoice.reject');
  end if;

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if p_status not in ('PENDING', 'VERIFIED', 'MISSING', 'REJECTED') then
    raise exception 'Unknown invoice status %', p_status using errcode = '22023';
  end if;
  if btrim(coalesce(p_note, '')) = '' then
    raise exception 'An invoice decision must state its reason' using errcode = '22023';
  end if;
  if p_stage_code not in ('P1', 'P2', 'P3', 'P4') then
    raise exception 'Invoices are reviewed per payable stage' using errcode = '22023';
  end if;

  if exists (select 1 from public.audit_logs
             where request_id = p_request_id and action = 'installation.invoice.reviewed') then
    return jsonb_build_object('subscriber_id', p_subscriber_id, 'idempotent', true);
  end if;

  -- المرحلة المدقَّقة يجب أن تكون القسط القادم فعلاً: تدقيق مرحلةٍ ماضية
  -- يفتح مالاً عن قسطٍ دُفع.
  select s.subscriber_id into v_sid
  from public.installation_subscribers s
  join public.installation_subscriber_state st on st.subscriber_uuid = s.id
  where lower(btrim(s.subscriber_id)) = lower(btrim(p_subscriber_id))
    and st.current_stage = p_stage_code
    and coalesce(st.remaining, 0) > 0;
  if v_sid is null then
    raise exception 'Stage % is not the next unpaid instalment for %',
      p_stage_code, p_subscriber_id using errcode = '22023';
  end if;

  select id, status into v_id, v_before
  from public.installation_invoices
  where subscriber_id = v_sid and stage_code is not distinct from p_stage_code
  limit 1;

  v_amount := public.installation_amount_for_stage(p_stage_code);

  if v_id is null then
    insert into public.installation_invoices (
      subscriber_id, stage_code, invoice_number, invoice_source, amount, status,
      verified_by, verified_at, rejected_by, rejected_at, rejection_reason, created_by)
    values (
      v_sid, p_stage_code, nullif(btrim(coalesce(p_invoice_number, '')), ''),
      'MANUAL', v_amount, p_status,
      case when p_status = 'VERIFIED' then v_actor end,
      case when p_status = 'VERIFIED' then now() end,
      case when p_status = 'REJECTED' then v_actor end,
      case when p_status = 'REJECTED' then now() end,
      case when p_status = 'REJECTED' then btrim(p_note) end,
      v_actor)
    returning id into v_id;
    v_before := 'NOT_CHECKED';
  else
    update public.installation_invoices
    set status = p_status,
        invoice_number = coalesce(
          nullif(btrim(coalesce(p_invoice_number, '')), ''), invoice_number),
        verified_by = case when p_status = 'VERIFIED' then v_actor end,
        verified_at = case when p_status = 'VERIFIED' then now() end,
        rejected_by = case when p_status = 'REJECTED' then v_actor end,
        rejected_at = case when p_status = 'REJECTED' then now() end,
        rejection_reason = case when p_status = 'REJECTED' then btrim(p_note) end
    where id = v_id;
  end if;

  insert into public.audit_logs (
    actor_id, action, field, old_value, new_value, entity_type, entity_id, request_id, extra)
  values (v_actor, 'installation.invoice.reviewed', 'status', v_before, p_status,
    'installation_invoice', v_id, p_request_id,
    'subscriber=' || v_sid || ' stage=' || p_stage_code
      || ' amount=' || v_amount::text
      || coalesce(' number=' || nullif(btrim(coalesce(p_invoice_number, '')), ''), '')
      || ' reason=' || btrim(p_note));

  return jsonb_build_object(
    'subscriber_id', v_sid, 'stage', p_stage_code,
    'status_before', v_before, 'status_after', p_status,
    'amount', v_amount, 'idempotent', false);
end;
$fn$;

revoke execute on function public.review_invoice(text,text,text,text,text,uuid) from public, anon;
grant execute on function public.review_invoice(text,text,text,text,text,uuid) to authenticated;

create index if not exists installation_invoices_subscriber_stage_idx
  on public.installation_invoices (subscriber_id, stage_code, status);

commit;
