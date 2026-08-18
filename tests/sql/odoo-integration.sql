-- ضمانات تهيئة الربط مع أودو على قاعدة حقيقية.
-- القيم كلها مُختلَقة. لا اتصال بأودو من هنا إطلاقاً.

\set ON_ERROR_STOP on
\pset tuples_only on

create or replace function pg_temp.must_fail(p_sql text, p_label text)
returns text language plpgsql as $$
begin
  execute p_sql;
  return 'FAILED: ' || p_label || ' — مرّ وكان يجب أن يُرفض';
exception when others then
  return '     ok ' || p_label;
end;
$$;

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns text language sql as $$
  select case when p_cond then '     ok ' || p_label else 'FAILED: ' || p_label end;
$$;

begin;

insert into auth.users (id, email) values
  ('01111111-1111-1111-1111-111111111111','adm@fixture.invalid'),
  ('02222222-2222-2222-2222-222222222222','acc@fixture.invalid'),
  ('03333333-3333-3333-3333-333333333333','vie@fixture.invalid')
on conflict do nothing;
insert into public.profiles (id, full_name, email, role, is_active) values
  ('01111111-1111-1111-1111-111111111111','AD','adm@fixture.invalid','admin',true),
  ('02222222-2222-2222-2222-222222222222','AC','acc@fixture.invalid','accountant',true),
  ('03333333-3333-3333-3333-333333333333','VI','vie@fixture.invalid','viewer',true)
on conflict (id) do update set role=excluded.role, is_active=true;

select '   == odoo readiness ==';

-- ---------------------------------------------------------------------------
-- الأسرار
-- ---------------------------------------------------------------------------

select pg_temp.ok(
  (select count(*) from public.integration_settings where key='odoo') = 1,
  'إعدادات الربط موجودة');

select pg_temp.ok(
  not (select config ?| array['api_key','password','secret','token','login']
       from public.integration_settings where key='odoo'),
  'الإعدادات لا تحمل أي سرّ');

select pg_temp.must_fail($$
  update public.integration_settings
  set config = config || '{"api_key":"leaked"}'::jsonb where key='odoo'
$$, 'إدخال سرّ في الإعدادات مرفوض بالبناء');

select pg_temp.must_fail($$
  insert into public.integration_settings (key, config)
  values ('other', '{"password":"x"}'::jsonb)
$$, 'سرّ في تكامل آخر مرفوض أيضاً');

select pg_temp.ok(
  (select count(*) from information_schema.columns
   where table_schema='public'
     and (column_name ilike '%api_key%' or column_name ilike '%odoo_password%'
          or column_name ilike '%odoo_secret%')) = 0,
  'لا عمود لمفتاح أودو في أي جدول');

-- ---------------------------------------------------------------------------
-- الوضع الافتراضي
-- ---------------------------------------------------------------------------

select pg_temp.ok(
  not (select enabled from public.integration_settings where key='odoo'),
  'الربط معطَّل افتراضاً');

select pg_temp.ok(
  public.odoo_verification_mode() = 'OFF',
  'الوضع OFF ما دام الربط معطَّلاً');

select pg_temp.ok(
  not public.odoo_verification_required(),
  'أودو ليس شرطاً للدفع');

-- تفعيله بوضع يدوي لا يجعله شرطاً.
update public.integration_settings set enabled = true, mode = 'MANUAL' where key='odoo';
select pg_temp.ok(
  public.odoo_verification_mode() = 'MANUAL' and not public.odoo_verification_required(),
  'التفعيل اليدوي لا يجعل أودو شرطاً');

update public.integration_settings set mode = 'REQUIRED' where key='odoo';
select pg_temp.ok(
  public.odoo_verification_required(),
  'الاشتراط يحدث بقرار صريح لا بالنشر');

-- وإطفاؤه يُعيد كل شيء إلى OFF مهما كان الوضع.
update public.integration_settings set enabled = false where key='odoo';
select pg_temp.ok(
  public.odoo_verification_mode() = 'OFF' and not public.odoo_verification_required(),
  'الإطفاء يغلب الوضع المحفوظ');

update public.integration_settings set enabled = true, mode = 'MANUAL' where key='odoo';

-- ---------------------------------------------------------------------------
-- الصلاحيات
-- ---------------------------------------------------------------------------

select pg_temp.ok(
  public.effective_permission('01111111-1111-1111-1111-111111111111','odoo.read'),
  'المدير يقرأ أودو');

select pg_temp.ok(
  public.effective_permission('02222222-2222-2222-2222-222222222222','odoo.read'),
  'المحاسب يقرأ أودو لتدقيق الفاتورة');

select pg_temp.ok(
  not public.effective_permission('03333333-3333-3333-3333-333333333333','odoo.read'),
  'المشاهد لا يقرأ أودو');

-- ---------------------------------------------------------------------------
-- تسجيل نتيجة الفحص
-- ---------------------------------------------------------------------------

insert into public.installation_invoices (id, subscriber_id, stage_code, status, created_by)
values ('0a111111-1111-1111-1111-111111111111','030270029','P1','PENDING',
        '01111111-1111-1111-1111-111111111111')
on conflict do nothing;

set local role authenticated;
set local request.jwt.claim.sub = '03333333-3333-3333-3333-333333333333';
select pg_temp.must_fail($$
  select public.record_odoo_invoice_check('0a111111-1111-1111-1111-111111111111',
    1, 2, 'INV/1', 'REF', current_date, 'posted', 'not_paid', 'out_invoice',
    13000, 13000, '{}'::jsonb, gen_random_uuid())
$$, 'من لا يملك القدرة لا يسجّل فحصاً');
reset role;

set local role authenticated;
set local request.jwt.claim.sub = '02222222-2222-2222-2222-222222222222';
select pg_temp.must_fail($$
  select public.record_odoo_invoice_check('0a111111-1111-1111-1111-111111111111',
    1, 2, 'INV/1', 'REF', current_date, 'posted', 'not_paid', 'out_invoice',
    13000, 13000, '{"api_key":"leaked"}'::jsonb, gen_random_uuid())
$$, 'لقطة تحمل سرّاً تُرفض');

select public.record_odoo_invoice_check('0a111111-1111-1111-1111-111111111111',
  77, 4242, 'INV/2026/0042', 'REF-42', date '2026-08-01', 'posted', 'not_paid',
  'out_invoice', 13000, 13000,
  '{"id":4242,"name":"INV/2026/0042","state":"posted"}'::jsonb, gen_random_uuid()) as chk \gset
reset role;

select pg_temp.ok(
  (select odoo_invoice_id from public.installation_invoices
   where id='0a111111-1111-1111-1111-111111111111') = 4242,
  'حقائق أودو تُحفظ على الفاتورة');

select pg_temp.ok(
  (select status from public.installation_invoices
   where id='0a111111-1111-1111-1111-111111111111') = 'PENDING',
  'الفحص يُسجّل الحقائق ولا يعتمد الفاتورة');

select pg_temp.ok(
  (select odoo_checked_at from public.installation_invoices
   where id='0a111111-1111-1111-1111-111111111111') is not null,
  'حالة أودو مصحوبة بوقت قراءتها');

select pg_temp.ok(
  exists (select 1 from public.audit_logs where action='integration.odoo.invoice.checked'),
  'الفحص مُدقَّق');

-- حالة بلا وقت مرفوضة بالقيد.
select pg_temp.must_fail($$
  update public.installation_invoices set odoo_state='posted', odoo_checked_at=null
  where id='0a111111-1111-1111-1111-111111111111'
$$, 'حالة أودو بلا وقت مرفوضة');

-- فاتورة أودو واحدة لا تُربَط بسجلَّين.
insert into public.installation_invoices (id, subscriber_id, stage_code, status, created_by)
values ('0a222222-2222-2222-2222-222222222222','030270030','P1','PENDING',
        '01111111-1111-1111-1111-111111111111')
on conflict do nothing;

select pg_temp.must_fail($$
  update public.installation_invoices
  set odoo_invoice_id = 4242, odoo_state='posted', odoo_checked_at=now()
  where id='0a222222-2222-2222-2222-222222222222'
$$, 'فاتورة أودو لا تُربَط بسجلَّي فاتورة');

-- ---------------------------------------------------------------------------
-- مسار الإكسل يبقى عاملاً
-- ---------------------------------------------------------------------------

select pg_temp.ok(
  (select count(*) from public.saas_import_batches) >= 0
  and (select count(*) from public.installation_subscribers) >= 0,
  'استيراد SaaS لا يعتمد على أودو إطلاقاً');

-- الاعتماد اليدوي يعمل مع تعطيل أودو تماماً.
update public.integration_settings set enabled = false where key='odoo';

set local role authenticated;
set local request.jwt.claim.sub = '02222222-2222-2222-2222-222222222222';
select public.verify_installation_invoice('0a111111-1111-1111-1111-111111111111',
  true, null, gen_random_uuid()) as v \gset
reset role;

select pg_temp.ok(
  (select status from public.installation_invoices
   where id='0a111111-1111-1111-1111-111111111111') = 'VERIFIED',
  'الاعتماد اليدوي يعمل وأودو مطفأ — انقطاعه لا يوقف العمل');

-- ---------------------------------------------------------------------------
-- الحماية
-- ---------------------------------------------------------------------------

select pg_temp.ok(
  (select count(*) from pg_class c cross join lateral aclexplode(c.relacl) a
   where c.relnamespace='public'::regnamespace and c.relname='integration_settings'
     and a.privilege_type <> 'SELECT'
     and a.grantee::regrole::text in ('authenticated','anon','public')) = 0,
  'لا كتابة مباشرة على إعدادات التكامل');

select pg_temp.ok(
  (select relrowsecurity from pg_class
   where relname='integration_settings' and relnamespace='public'::regnamespace),
  'إعدادات التكامل محميّة بـRLS');

rollback;
