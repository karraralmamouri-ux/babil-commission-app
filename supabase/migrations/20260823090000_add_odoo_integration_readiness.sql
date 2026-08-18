-- تهيئة الربط مع أودو — قراءة فقط، واختيارية بالكامل.
--
-- القرار المنتجي الحاكم: مصدر التشغيل يبقى ملفات SaaS. أودو هنا للتحقق من
-- الفاتورة والشريك فقط، ولا يحلّ محلّ الاستيراد ولا يصير شرطاً لأي عملية.
--
-- ما اكتُشف حيّاً قبل كتابة هذا الملف (بلا اعتماد، وبلا أي كتابة):
--   الإصدار     17.0+e-20250421  ⇒ أودو 17 نسخة Enterprise
--   JSON-2 API  غير موجود (404) — وهو واجهة أودو 19، فلا يُبنى عليها
--   المتاح      /jsonrpc  و /xmlrpc/2/*
--   قاعدة       odoo
--
-- ولذلك المخطط أدناه لا يفترض أسماء حقول مخصّصة في أودو: مفتاح الربط يبقى
-- نصّاً حرّاً مع اسم الحقل الذي جاء منه، حتى يُحسم بالاكتشاف المُعتمَد لاحقاً.
--
-- forward-only. لا صف مالي يُمَس، ولا سرّ يُخزَّن هنا إطلاقاً.

begin;

-- ---------------------------------------------------------------------------
-- 1. قدرة قراءة أودو.
--
-- منفصلة عن invoice.verify عمداً: قد يُسمح لشخص بقراءة أودو للتشخيص دون أن
-- يملك اعتماد فاتورة، وقد يُعتمَد يدوياً بلا أودو أصلاً. ربطهما كان سيمنع
-- الحالتين.
-- ---------------------------------------------------------------------------

insert into public.permission_capabilities
  (key, domain, label_ar, is_sensitive, is_self_protecting, scopeable) values
  ('odoo.read', 'odoo', 'قراءة أودو', true, false, false)
on conflict (key) do nothing;

insert into public.role_template_capabilities (role_key, capability_key)
select 'admin', 'odoo.read'
on conflict do nothing;

-- المحاسب يدقّق الفواتير اليوم، فيقرأ أودو للتحقق. ولا يملك تهيئة الربط.
insert into public.role_template_capabilities (role_key, capability_key)
select 'accountant', 'odoo.read'
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- 2. حقول الربط على الفاتورة.
--
-- يُخزَّن ما تحتاجه العملية فقط. الكائن الكامل من أودو لا يُنسَخ: نسخُه يُنشئ
-- حقيقة ثانية تتقادم بصمت، والغرض هنا الإحالة لا الاستنساخ.
-- ---------------------------------------------------------------------------

alter table public.installation_invoices
  add column if not exists odoo_partner_id integer,
  add column if not exists odoo_invoice_id integer,
  add column if not exists odoo_state text,
  add column if not exists odoo_payment_state text,
  add column if not exists odoo_amount_total numeric,
  add column if not exists odoo_amount_residual numeric,
  add column if not exists odoo_move_type text,
  add column if not exists odoo_checked_at timestamptz,
  -- لقطة الحقول لحظة الاعتماد. تحفظ التفسير لو تغيّرت الفاتورة في أودو لاحقاً،
  -- وليست بديلاً عن إعادة التحقق قبل الدفع.
  add column if not exists odoo_snapshot jsonb;

comment on column public.installation_invoices.odoo_snapshot is
  'Small snapshot of the Odoo fields as they were at verification time. Explains a past decision; never a substitute for a live re-check before payment.';

-- لا تُقبل حالة أودو إلا مصحوبة بوقت قراءتها: حالة بلا زمن لا تُفسَّر.
alter table public.installation_invoices
  drop constraint if exists installation_invoices_odoo_state_is_timed;
alter table public.installation_invoices
  add constraint installation_invoices_odoo_state_is_timed
  check (odoo_state is null or odoo_checked_at is not null);

-- فاتورة أودو واحدة لا تُربَط بسجلَي فاتورة مختلفين.
create unique index if not exists installation_invoices_odoo_invoice_key
  on public.installation_invoices (odoo_invoice_id)
  where odoo_invoice_id is not null;

create index if not exists installation_invoices_odoo_partner_idx
  on public.installation_invoices (odoo_partner_id);

-- ---------------------------------------------------------------------------
-- 3. تهيئة الربط — معطَّلة افتراضاً.
--
-- الوضع الافتراضي MANUAL: أودو أداة تحقق يدوية، ولا يُشترط لأي دفع. تحويلها
-- إلى REQUIRED قرار تشغيلي يُتخذ صراحةً، لا أثر جانبي للنشر.
-- ---------------------------------------------------------------------------

create table if not exists public.integration_settings (
  key text primary key,
  enabled boolean not null default false,
  mode text,
  config jsonb not null default '{}'::jsonb,
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now(),
  constraint integration_settings_mode_check
    check (mode is null or mode in ('OFF', 'MANUAL', 'OPTIONAL_LIVE_CHECK', 'REQUIRED'))
);

insert into public.integration_settings (key, enabled, mode, config) values
  ('odoo', false, 'MANUAL', jsonb_build_object(
    'base_url', 'https://znr.ejaferp.com',
    'database', 'odoo',
    'api_style', 'jsonrpc',
    'server_version', '17.0+e-20250421',
    'edition', 'enterprise',
    'discovered_at', '2026-08-23',
    'note', 'credentials live in Edge Function secrets only; never in this table'))
on conflict (key) do nothing;

-- الحارس الذي يجعل تسريب السرّ إلى قاعدة البيانات مستحيلاً بالبناء لا بالانضباط.
create or replace function public.guard_no_secrets_in_integration_settings()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare k text;
begin
  foreach k in array array['api_key','apikey','password','secret','token','login','credential']
  loop
    if new.config ? k then
      raise exception 'Integration settings must not carry credentials (%)', k
        using errcode = '42501';
    end if;
  end loop;
  return new;
end;
$$;

drop trigger if exists trg_guard_integration_secrets on public.integration_settings;
create trigger trg_guard_integration_secrets
  before insert or update on public.integration_settings
  for each row execute function public.guard_no_secrets_in_integration_settings();

-- ---------------------------------------------------------------------------
-- 4. وضع التحقق الفعّال.
--
-- تُستشار قبل الدفع. ما دام الوضع ليس REQUIRED فغياب أودو لا يمنع شيئاً —
-- وهذا هو الشرط الذي يبقي مسار الإكسل يعمل بلا تعلّق بخدمة خارجية.
-- ---------------------------------------------------------------------------

create or replace function public.odoo_verification_mode()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when not coalesce((select enabled from public.integration_settings where key = 'odoo'), false)
      then 'OFF'
    else coalesce((select mode from public.integration_settings where key = 'odoo'), 'MANUAL')
  end;
$$;

create or replace function public.odoo_verification_required()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.odoo_verification_mode() = 'REQUIRED';
$$;

-- ---------------------------------------------------------------------------
-- 5. تسجيل نتيجة تحقق من أودو.
--
-- لا تكتبها دالة الاتصال مباشرة: الدالة الطرفية تقرأ من أودو، وهذه تُثبّت
-- النتيجة بعد فحص القدرة. وانقطاع أودو لا يُنتج «مُعتمَدة» أبداً — الحالات
-- المسموح تثبيتها لا تشمل أي حالة نجاح ضمنية.
-- ---------------------------------------------------------------------------

create or replace function public.record_odoo_invoice_check(
  p_invoice_id uuid,
  p_odoo_partner_id integer,
  p_odoo_invoice_id integer,
  p_invoice_number text,
  p_invoice_reference text,
  p_invoice_date date,
  p_odoo_state text,
  p_odoo_payment_state text,
  p_odoo_move_type text,
  p_amount_total numeric,
  p_amount_residual numeric,
  p_snapshot jsonb,
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_row public.installation_invoices%rowtype;
begin
  perform public.require_capability('odoo.read');

  if p_request_id is null then
    raise exception 'request_id is required' using errcode = '22023';
  end if;
  if exists (select 1 from public.audit_logs
             where actor_id = v_actor and request_id = p_request_id) then
    return jsonb_build_object('replayed', true, 'request_id', p_request_id);
  end if;

  -- اللقطة تُخزَّن كما وردت من الطرف الخادمي، بعد تجريدها هناك. وهنا حارس
  -- أخير: لو تسرّب مفتاح يشبه سرّاً، يُرفض الحفظ كله.
  if p_snapshot ?| array['api_key','password','secret','token','login'] then
    raise exception 'The snapshot must not carry credentials' using errcode = '42501';
  end if;

  update public.installation_invoices
  set odoo_partner_id = p_odoo_partner_id,
      odoo_invoice_id = p_odoo_invoice_id,
      invoice_number = coalesce(p_invoice_number, invoice_number),
      invoice_reference = coalesce(p_invoice_reference, invoice_reference),
      invoice_date = coalesce(p_invoice_date, invoice_date),
      odoo_state = p_odoo_state,
      odoo_payment_state = p_odoo_payment_state,
      odoo_move_type = p_odoo_move_type,
      odoo_amount_total = p_amount_total,
      odoo_amount_residual = p_amount_residual,
      odoo_checked_at = now(),
      odoo_snapshot = p_snapshot,
      -- الحقائق تُحفَظ؛ والاعتماد قرار بشري منفصل عبر verify_installation_invoice.
      invoice_source = case when invoice_source = 'MANUAL' then 'ODOO' else invoice_source end
  where id = p_invoice_id
  returning * into v_row;

  if not found then
    raise exception 'Invoice was not found' using errcode = 'P0002';
  end if;

  insert into public.audit_logs (
    actor_id, action, field, new_value, entity_type, entity_id, request_id, extra)
  values (v_actor, 'integration.odoo.invoice.checked', 'odoo_state',
    coalesce(p_odoo_state, 'null'), 'installation_invoice', p_invoice_id, p_request_id,
    'odoo_invoice_id=' || coalesce(p_odoo_invoice_id::text, '-')
    || ' payment_state=' || coalesce(p_odoo_payment_state, '-'));

  return jsonb_build_object('replayed', false, 'invoice_id', p_invoice_id,
    'odoo_state', p_odoo_state, 'odoo_payment_state', p_odoo_payment_state,
    -- التحقق يُسجّل الحقائق ولا يعتمد. الاعتماد يبقى فعلاً بشرياً مُصرَّحاً.
    'status', v_row.status);
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. الحماية والصلاحيات.
-- ---------------------------------------------------------------------------

alter table public.integration_settings enable row level security;
revoke all on table public.integration_settings from authenticated;
revoke all on table public.integration_settings from anon;
revoke all on table public.integration_settings from public;
grant select on table public.integration_settings to authenticated;

drop policy if exists integration_settings_select on public.integration_settings;
create policy integration_settings_select on public.integration_settings
  for select to authenticated using (public.has_capability('invoice.view'));

revoke execute on function public.guard_no_secrets_in_integration_settings()
  from public, anon, authenticated;

do $$
declare f text;
begin
  foreach f in array array[
    'public.odoo_verification_mode()',
    'public.odoo_verification_required()',
    'public.record_odoo_invoice_check(uuid, integer, integer, text, text, date, text, text, text, numeric, numeric, jsonb, uuid)'
  ] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;

commit;
